"""Execute the emitted Windows x64 continuation against a mocked D3D12 device."""
import argparse
import hashlib
from pathlib import Path
import struct

import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
from unicorn import x86_const as registers

from build_fix import (HOOK_RVA, RESUME_RVA, SHADER_OFFSET,
                       ORIGINAL_SHADER_LENGTH, ORIGINAL_SHADER_DIGEST, FIX_SHADER_SHA256,
                       FIX_SHADER_LENGTH, SEA_SHADER_OFFSET, SEA_FIX_SHADER_LENGTH,
                       SEA_ORIGINAL_SHADER_LENGTH, SEA_ORIGINAL_SHADER_DIGEST,
                       SEA_FIX_SHADER_SHA256)


def check_image(pe, render_pass_bias=False):
    section = pe.sections[-1]
    assert section.Name.rstrip(b'\0') == (b'.hdepth' if render_pass_bias else b'.hwater')
    assert section.Characteristics == 0x60000020
    if not render_pass_bias:
        shader_rva = section.VirtualAddress + SHADER_OFFSET
        assert pe.get_data(shader_rva, 4) == b'DXBC'
        shader_length = struct.unpack('<I', pe.get_data(shader_rva + 24, 4))[0]
        assert hashlib.sha256(pe.get_data(shader_rva, shader_length)).hexdigest() == FIX_SHADER_SHA256
        sea_rva = section.VirtualAddress + SEA_SHADER_OFFSET
        assert pe.get_data(sea_rva, 4) == b'DXBC'
        sea_length = struct.unpack('<I', pe.get_data(sea_rva + 24, 4))[0]
        assert sea_length == SEA_FIX_SHADER_LENGTH
        assert hashlib.sha256(pe.get_data(sea_rva, sea_length)).hexdigest() == SEA_FIX_SHADER_SHA256
    assert pe.OPTIONAL_HEADER.CheckSum == pe.generate_checksum()
    table = pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
    assert table.Size % 12 == 0
    assert table.VirtualAddress >= section.VirtualAddress
    entries = list(struct.iter_unpack('<III', pe.get_data(table.VirtualAddress, table.Size)))
    assert entries == sorted(entries)
    assert all(a[1] <= b[0] for a, b in zip(entries, entries[1:]))
    final = entries[-1]
    assert final[:2] == (section.VirtualAddress, section.VirtualAddress + SHADER_OFFSET)
    unwind = pe.get_data(final[2], 16)
    assert unwind[:4] == b'\x21\x00\x00\x00'
    assert struct.unpack('<III', unwind[4:]) == (0x74D220, 0x74E08C, 0x214E68C)
    parent = (0x74D220, 0x74E08C, 0x214E68C)
    assert parent in entries
    assert pe.get_data(parent[2], 4) == bytes.fromhex('11150900')


def execute(pe, base, scenario, hresult, kind):
    machine = Uc(UC_ARCH_X86, UC_MODE_64)
    image = pe.get_memory_mapped_image()
    machine.mem_map(base, (len(image) + 4095) & -4096)
    machine.mem_write(base, image)
    stack_base, data_base, api = 0x10000000, 0x20000000, 0x60000000
    machine.mem_map(stack_base, 0x10000)
    machine.mem_map(data_base, 0x20000)
    machine.mem_map(api, 0x1000)
    machine.mem_write(api, b'\xc3')
    stack = stack_base + 0x8000
    desc, shader, vtable, device, iid, out = [data_base + n for n in (0, 0x1000, 0x10000, 0x11000, 0x12000, 0x13000)]
    original_length, original_digest, offset, fixed_length = (
        (ORIGINAL_SHADER_LENGTH, ORIGINAL_SHADER_DIGEST, SHADER_OFFSET, FIX_SHADER_LENGTH)
        if kind == 'puddle' else
        (SEA_ORIGINAL_SHADER_LENGTH, SEA_ORIGINAL_SHADER_DIGEST, SEA_SHADER_OFFSET, SEA_FIX_SHADER_LENGTH)
    )
    ps_length = original_length
    ps_pointer = shader
    expected_match = scenario == 'match'
    bytecode = bytearray(b'DXBC' + original_digest + b'\0' * (original_length - 20))
    if scenario == 'wrong-magic': bytecode[:4] = b'ABCD'
    if scenario.startswith('wrong-digest-'): bytecode[4 + int(scenario.rsplit('-', 1)[1])] ^= 1
    if scenario == 'wrong-length': ps_length += 1
    if scenario == 'cross-length': ps_length = SEA_ORIGINAL_SHADER_LENGTH if kind == 'puddle' else ORIGINAL_SHADER_LENGTH
    if scenario == 'null-shader': ps_pointer = 0
    description = bytearray((i * 17 + 39) & 255 for i in range(656))
    struct.pack_into('<QQ', description, 0x18, ps_pointer, ps_length)
    struct.pack_into('<I', description, 0x1F0, 0 if scenario == 'no-depth' else 1)
    struct.pack_into('<I', description, 0x1F8, 4 if scenario == 'opposite-depth' else 7)
    machine.mem_write(desc, bytes(description))
    machine.mem_write(shader, bytes(bytecode))
    machine.mem_write(vtable + 0x50, struct.pack('<Q', api))
    initial = {}
    for index, name in enumerate(('RBX','RSI','RDI','R12','R13','R14','R15','RBP')):
        initial[name] = 0xAABBCC0000000000 + index
        machine.reg_write(getattr(registers, 'UC_X86_REG_' + name), initial[name])
    for name in ('XMM6','XMM7','XMM8','XMM9','XMM10','XMM11','XMM12','XMM13','XMM14','XMM15'):
        initial[name] = 0x10203040000000000000000000000000 + int(name[3:])
        machine.reg_write(getattr(registers, 'UC_X86_REG_' + name), initial[name])
    for name, value in [('RAX',vtable),('RCX',device),('RDX',desc),('R8',iid),('R9',out),('RSP',stack)]:
        machine.reg_write(getattr(registers, 'UC_X86_REG_' + name), value)
    calls = []
    def api_call(uc, address, size, user):
        if address != api: return
        args = [uc.reg_read(getattr(registers, 'UC_X86_REG_' + name)) for name in ('RCX','RDX','R8','R9')]
        assert args == [device,desc,iid,out]
        assert uc.reg_read(registers.UC_X86_REG_RSP) == stack - 8
        observed = bytearray(uc.mem_read(desc, 656))
        pointer, length = struct.unpack_from('<QQ', observed, 0x18)
        if expected_match:
            assert pointer == base + pe.sections[-1].VirtualAddress + offset
            assert length == fixed_length
            assert bytes(uc.mem_read(pointer, 4)) == b'DXBC'
            struct.pack_into('<QQ', observed, 0x18, ps_pointer, ps_length)
        else: assert (pointer,length) == (ps_pointer,ps_length)
        assert observed == description, 'An unrelated pipeline field changed'
        calls.append((pointer,length))
        # Simulate a conforming API that uses its entire shadow space and
        # destroys every volatile argument register before returning.
        uc.mem_write(stack, b'\xDD' * 32)
        for name in ('RCX','RDX','R8','R9','R10','R11'):
            uc.reg_write(getattr(registers, 'UC_X86_REG_' + name), 0xDEADBEEF)
        uc.reg_write(registers.UC_X86_REG_RAX, hresult & 0xFFFFFFFF)
    machine.hook_add(UC_HOOK_CODE, api_call)
    machine.emu_start(base + HOOK_RVA, base + RESUME_RVA, count=150)
    assert len(calls) == 1
    assert machine.reg_read(registers.UC_X86_REG_RIP) == base + RESUME_RVA
    assert machine.reg_read(registers.UC_X86_REG_RSP) == stack
    assert struct.unpack('<I', machine.mem_read(stack + 0x3D0, 4))[0] == (hresult & 0xFFFFFFFF)
    assert machine.reg_read(registers.UC_X86_REG_RAX) == (hresult & 0xFFFFFFFF)
    for name,value in initial.items():
        assert machine.reg_read(getattr(registers, 'UC_X86_REG_' + name)) == value, name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('patched_exe', type=Path)
    args = parser.parse_args()
    pe = pefile.PE(str(args.patched_exe))
    check_image(pe)
    scenarios = ['match','wrong-magic','wrong-length','null-shader','no-depth','opposite-depth','cross-length']
    scenarios += ['wrong-digest-' + str(index) for index in range(16)]
    count = 0
    for kind in ('puddle', 'sea'):
        for base in (pe.OPTIONAL_HEADER.ImageBase, 0x7FF620000000):
            for scenario in scenarios:
                for hresult in (0, 0x80070057):
                    execute(pe, base, scenario, hresult, kind)
                    count += 1
    print('PASS:', count, 'x64 execution cases, including ASLR, mismatch gates, ABI and HRESULT handling.')
    print('PASS: sorted PE exception directory and chained parent unwind metadata.')


if __name__ == '__main__':
    main()
