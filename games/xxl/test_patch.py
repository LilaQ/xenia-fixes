"""Execute the generated PowerPC routine against byte-copy reference results."""
import random
import struct
import tomllib

from unicorn import Uc, UC_ARCH_PPC, UC_MODE_PPC64, UC_MODE_BIG_ENDIAN, UC_TLB_VIRTUAL
from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE, UC_MEM_READ
from unicorn.ppc_const import UC_PPC_REG_0, UC_PPC_REG_LR, UC_PPC_REG_CR
from unicorn.ppc_const import UC_PPC_REG_PC

from build_patch import BASE, copy_code, render

SOURCE, DEST, RETURN = 0x100000, 0x200000, 0x400000
PAGE = 4096


def run_copy(code, length, source_offset, dest_offset, seed):
    rng = random.Random(seed)
    source = rng.randbytes(PAGE)
    initial_dest = rng.randbytes(PAGE)
    expected = bytearray(initial_dest)
    expected[dest_offset:dest_offset + length] = source[source_offset:source_offset + length]
    cpu = Uc(UC_ARCH_PPC, UC_MODE_PPC64 | UC_MODE_BIG_ENDIAN)
    # Test virtual byte accesses directly; the console's MMU is not part of
    # this routine. Unicorn's physical PPC64 MMU does not implement stores.
    cpu.ctl_set_tlb_mode(UC_TLB_VIRTUAL)
    cpu.mem_map(BASE & -PAGE, PAGE * 2)
    cpu.mem_write(BASE, code)
    for addr in [SOURCE, DEST, RETURN]:
        cpu.mem_map(addr, PAGE)
    cpu.mem_write(SOURCE, source)
    cpu.mem_write(DEST, initial_dest)
    preserved = {}
    for reg in [1, 2, *range(14, 32)]:
        value = rng.getrandbits(64)
        cpu.reg_write(UC_PPC_REG_0 + reg, value)
        preserved[reg] = value
    old_cr = rng.getrandbits(32)
    cpu.reg_write(UC_PPC_REG_CR, old_cr)
    cpu.reg_write(UC_PPC_REG_0 + 3, DEST + dest_offset)
    cpu.reg_write(UC_PPC_REG_0 + 4, SOURCE + source_offset)
    cpu.reg_write(UC_PPC_REG_0 + 5, length)
    cpu.reg_write(UC_PPC_REG_LR, RETURN)

    def check_access(cpu, access, addr, size, value, data):
        # No reads before/after the requested source range, and no writes
        # outside the requested destination range, even inside mapped pages.
        lo = SOURCE + source_offset if access == UC_MEM_READ else DEST + dest_offset
        assert lo <= addr and addr + size <= lo + length, (length, hex(addr), size)

    cpu.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, check_access)
    cpu.emu_start(BASE, RETURN, count=100000)
    assert cpu.reg_read(UC_PPC_REG_PC) == RETURN
    assert bytes(cpu.mem_read(DEST, PAGE)) == bytes(expected)
    assert bytes(cpu.mem_read(SOURCE, PAGE)) == source
    assert cpu.reg_read(UC_PPC_REG_0 + 3) == DEST + dest_offset
    assert cpu.reg_read(UC_PPC_REG_LR) == RETURN
    for reg, value in preserved.items():
        assert cpu.reg_read(UC_PPC_REG_0 + reg) == value
    assert cpu.reg_read(UC_PPC_REG_CR) & 0x00FFF000 == old_cr & 0x00FFF000


def main():
    code = copy_code()
    patch = tomllib.loads(render())
    assert patch["title_id"] == "58411249"
    assert patch["hash"] == "0F8C087D6FEA1BD4"
    all_entries = patch["patch"][0]["be32"]
    assert len({entry["address"] for entry in all_entries}) == len(all_entries)
    entries = [entry for entry in all_entries
               if BASE <= entry["address"] < BASE + len(code)]
    assert b"".join(struct.pack(">I", entry["value"]) for entry in entries) == code
    assert [entry["address"] for entry in entries] == list(range(BASE, BASE + len(code), 4))
    cases = 0
    for length in [0, 1, 2, 3, 4, 7, 8, 9, 15, 16, 23, 24, 31, 32, 63, 64, 65, 127, 128, 129, 257, 1024]:
        for source_offset in range(8):
            for dest_offset in range(8):
                run_copy(code, length, source_offset, dest_offset, cases)
                cases += 1
    for length in [0, 1, 3, 7, 8, 15, 24, 63, 64, 65, 128, 1023, 4096]:
        run_copy(code, length, PAGE - length, PAGE - length, cases)
        cases += 1
    print(f"PASS: {cases} PowerPC execution cases; exact byte ranges, return value, preserved registers, page boundaries and TOML encoding")


if __name__ == "__main__":
    main()
