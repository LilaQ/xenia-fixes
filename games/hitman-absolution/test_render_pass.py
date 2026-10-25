"""Execute the shader-independent D3D12 depth-bias continuation under x64."""
import argparse
from pathlib import Path
import struct

import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
from unicorn import x86_const as registers

from build_fix import HOOK_RVA, RESUME_RVA
from test_fix import check_image

# Actual D3D12 layout independently checked by abi-offsets.cpp.
FIELDS = {0x1f0: 1, 0x1f4: 1, 0x1f8: 7, 0x240: 1, 0x244: 10,
          0x264: 20, 0x23c: 3, 0x268: 1, 0x1d0: 0, 0x1d4: 0, 0x1d8: 0}


def execute(pe, base, override, shader_pointer, shader_length, hresult):
    machine = Uc(UC_ARCH_X86, UC_MODE_64)
    image = pe.get_memory_mapped_image()
    machine.mem_map(base, (len(image) + 4095) & -4096)
    machine.mem_write(base, image)
    stack, desc, api = 0x10008000, 0x20000000, 0x60000000
    machine.mem_map(stack - 0x8000, 0x10000)
    machine.mem_map(desc, 0x10000)
    machine.mem_map(api, 0x1000)
    machine.mem_write(api, b'\xc3')
    description = bytearray((i * 17 + 39) & 255 for i in range(656))
    for offset, value in FIELDS.items():
        struct.pack_into('<I', description, offset, value)
    if override:
        struct.pack_into('<I', description, override[0], override[1])
    struct.pack_into('<QQ', description, 0x18, shader_pointer, shader_length)
    machine.mem_write(desc, bytes(description))
    vtable, device, iid, out = (desc + n for n in (0x1000, 0x2000, 0x3000, 0x4000))
    machine.mem_write(vtable + 0x50, struct.pack('<Q', api))
    initial = {}
    for index, name in enumerate(('RBX', 'RSI', 'RDI', 'R12', 'R13', 'R14', 'R15', 'RBP')):
        initial[name] = 0xaabbcc0000000000 + index
    for name in ('XMM6', 'XMM7', 'XMM8', 'XMM9', 'XMM10', 'XMM11', 'XMM12', 'XMM13', 'XMM14', 'XMM15'):
        initial[name] = 0x10203040000000000000000000000000 + int(name[3:])
    for name, value in initial.items():
        machine.reg_write(getattr(registers, 'UC_X86_REG_' + name), value)
    for name, value in [('RAX', vtable), ('RCX', device), ('RDX', desc), ('R8', iid), ('R9', out), ('RSP', stack)]:
        machine.reg_write(getattr(registers, 'UC_X86_REG_' + name), value)
    expected = description[:]
    if override is None and shader_pointer and shader_length:
        struct.pack_into('<I', expected, 0x1d0, 512)
        struct.pack_into('<I', expected, 0x1d4, 0x37800000)  # 2**-16 clamp
    calls = []

    def api_call(uc, address, size, user):
        if address != api:
            return
        assert [uc.reg_read(getattr(registers, 'UC_X86_REG_' + n)) for n in ('RCX', 'RDX', 'R8', 'R9')] == [device, desc, iid, out]
        assert uc.reg_read(registers.UC_X86_REG_RSP) == stack - 8
        assert bytes(uc.mem_read(desc, 656)) == expected, 'Unexpected PSO field modification'
        calls.append(True)
        uc.mem_write(stack, b'\xdd' * 32)
        for name in ('RCX', 'RDX', 'R8', 'R9', 'R10', 'R11'):
            uc.reg_write(getattr(registers, 'UC_X86_REG_' + name), 0xdeadbeef)
        uc.reg_write(registers.UC_X86_REG_RAX, hresult)

    machine.hook_add(UC_HOOK_CODE, api_call)
    machine.emu_start(base + HOOK_RVA, base + RESUME_RVA, count=100)
    assert calls == [True]
    assert machine.reg_read(registers.UC_X86_REG_RSP) == stack
    assert machine.reg_read(registers.UC_X86_REG_RAX) == hresult
    assert struct.unpack('<I', machine.mem_read(stack + 0x3d0, 4))[0] == hresult
    for name, value in initial.items():
        assert machine.reg_read(getattr(registers, 'UC_X86_REG_' + name)) == value, name


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    args = parser.parse_args()
    pe = pefile.PE(str(args.executable))
    check_image(pe, render_pass_bias=True)
    # Every selection field gets an independently failing case. Include
    # G-buffer/depth-only, opposite comparison and already biased pipelines.
    scenarios = [(None, 0xdead12345678, 12345), (None, 0xbeef87654321, 98765),
                 (None, 0, 12345), (None, 0xdead12345678, 0)]
    scenarios += [((offset, value ^ 1), 0xdead12345678, 12345) for offset, value in FIELDS.items()]
    scenarios += [((0x240, 3), 0xdead12345678, 12345), ((0x240, 0), 0xdead12345678, 12345),
                  ((0x1f8, 4), 0xdead12345678, 12345), ((0x1d0, 0xffffffff), 0xdead12345678, 12345)]
    count = 0
    for base in (pe.OPTIONAL_HEADER.ImageBase, 0x7ff620000000):
        for override, pointer, length in scenarios:
            for hresult in (0, 0x80070057):
                execute(pe, base, override, pointer, length, hresult)
                count += 1
    print('PASS:', count, 'x64 cases: independent shader pointers, selection gates, ASLR, ABI, HRESULT, PE unwind.')
