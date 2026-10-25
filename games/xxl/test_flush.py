"""Execute the cache-flush replacement with simulated kernel exports."""
import random
import struct
import tomllib

from unicorn import Uc, UC_ARCH_PPC, UC_MODE_PPC64, UC_MODE_BIG_ENDIAN
from unicorn import UC_HOOK_CODE, UC_TLB_VIRTUAL
from unicorn.ppc_const import UC_PPC_REG_0, UC_PPC_REG_LR, UC_PPC_REG_CR
from unicorn.ppc_const import UC_PPC_REG_PC

from build_patch import (FLUSH_ENTRY, FLUSH_CODE, FLUSH_CACHE, KERNEL_NAME,
                         GET_MODULE, GET_PROC, flush_code, render)

PAGE, STACK, RETURN, SWEEP = 4096, 0x800000, 0x400000, 0x500000
HANDLE = 0x12340000


def run_case(length, cached=False, module_status=0, proc_status=0,
             null_proc=False, repeat=1):
    cpu = Uc(UC_ARCH_PPC, UC_MODE_PPC64 | UC_MODE_BIG_ENDIAN)
    cpu.ctl_set_tlb_mode(UC_TLB_VIRTUAL)
    patch = tomllib.loads(render())["patch"][0]["be32"]
    for page in {entry["address"] & -PAGE for entry in patch} | {
            GET_MODULE & -PAGE, RETURN, SWEEP, STACK - PAGE}:
        cpu.mem_map(page, PAGE)
    for entry in patch:
        cpu.mem_write(entry["address"], struct.pack(">I", entry["value"]))
    assert bytes(cpu.mem_read(FLUSH_CODE, len(flush_code()))) == flush_code()
    if cached:
        cpu.mem_write(FLUSH_CACHE, struct.pack(">I", SWEEP))
    calls, barriers = [], []
    rng = random.Random(130)
    preserved = {reg: rng.getrandbits(64) for reg in [2, *range(13, 32)]}
    preserved[1] = STACK - 0x100
    old_cr = rng.getrandbits(32)
    start = 0xBE3500C4

    def reg(index):
        return cpu.reg_read(UC_PPC_REG_0 + index)

    def output(address, value):
        cpu.mem_write(address, struct.pack(">I", value))

    def hook(cpu, address, size, data):
        if address in [GET_MODULE, GET_PROC, SWEEP]:
            # Each export may destroy volatile registers; cached addresses
            # and the requested range must survive those calls on the stack.
            args = [reg(i) for i in range(3, 6)]
            calls.append(address)
            result = 0
            if address == GET_MODULE:
                assert bytes(cpu.mem_read(args[0], 13)) == b"xboxkrnl.exe\0"
                assert reg(1) % 16 == 0
                if not module_status:
                    output(args[1], HANDLE)
                result = module_status
            elif address == GET_PROC:
                assert args[:2] == [HANDLE, 0xAB]
                assert bytes(cpu.mem_read(args[2], 4)) == bytes(4)
                if not proc_status:
                    output(args[2], 0 if null_proc else SWEEP)
                result = proc_status
            else:
                assert args[:2] == [start, length]
            for i in range(0, 13):
                if i not in [1, 2]:
                    cpu.reg_write(UC_PPC_REG_0 + i, rng.getrandbits(64))
            cpu.reg_write(UC_PPC_REG_0 + 3, result)
            # The exports return through the link register set by bl/bctrl.
            cpu.reg_write(UC_PPC_REG_PC, cpu.reg_read(UC_PPC_REG_LR))
        elif FLUSH_CODE <= address < FLUSH_CODE + len(flush_code()):
            word = struct.unpack(">I", bytes(cpu.mem_read(address, 4)))[0]
            if word in [0x7C0004AC, 0x4C00012C]:
                barriers.append(word)

    cpu.hook_add(UC_HOOK_CODE, hook)
    for _ in range(repeat):
        for index, value in preserved.items():
            cpu.reg_write(UC_PPC_REG_0 + index, value)
        cpu.reg_write(UC_PPC_REG_CR, old_cr)
        cpu.reg_write(UC_PPC_REG_0 + 3, start)
        cpu.reg_write(UC_PPC_REG_0 + 4, length)
        cpu.reg_write(UC_PPC_REG_LR, RETURN)
        cpu.emu_start(FLUSH_ENTRY, RETURN, count=1000)
        assert cpu.reg_read(UC_PPC_REG_PC) == RETURN
        assert cpu.reg_read(UC_PPC_REG_LR) == RETURN
        for index, value in preserved.items():
            assert reg(index) == value, index
        assert cpu.reg_read(UC_PPC_REG_CR) & 0x00FFF000 == old_cr & 0x00FFF000
    expected = []
    if length:
        if cached:
            expected = [SWEEP] * repeat
        elif module_status:
            expected = [GET_MODULE] * repeat
        elif proc_status or null_proc:
            expected = [GET_MODULE, GET_PROC] * repeat
        else:
            expected = [GET_MODULE, GET_PROC] + [SWEEP] * repeat
    assert calls == expected, (calls, expected)
    assert barriers == [0x7C0004AC, 0x4C00012C] * (repeat if length else 0)
    assert struct.unpack(">I", bytes(cpu.mem_read(FLUSH_CACHE, 4)))[0] == (
        SWEEP if cached or (length and not module_status and not proc_status
                           and not null_proc) else 0)


if __name__ == "__main__":
    cases = 0
    for length in [0, 1, 4, 128, 4096, 0xFFFFFFFF]:
        for options in [{}, {"cached": True}, {"module_status": 0xC0000001},
                        {"proc_status": 0xC0000002}, {"null_proc": True}]:
            run_case(length, repeat=2, **options)
            cases += 1
    print(f"PASS: {cases} cache-flush cases; export lookup, cached reuse, exact range, zero length, failure fallback, barriers and caller ABI")
