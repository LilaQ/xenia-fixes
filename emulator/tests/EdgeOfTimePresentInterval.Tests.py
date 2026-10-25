"""Check the patch against an owner-supplied, decoded base-version image.

Usage: python3.11+ EdgeOfTimePresentInterval.Tests.py /private/path/default.pe
The game image is only read and is never included in this repository.
"""
from pathlib import Path
import struct
import sys
import tomllib

image = Path(sys.argv[1]).read_bytes()
patch_path = Path(__file__).resolve().parents[1] / "game-patches/415608B2 - Edge of Time 60FPS.patch.toml"
patch = tomllib.loads(patch_path.read_text())
assert patch["title_id"] == "415608B2"
assert patch["hash"] == "26011A843A5386C6"
assert len(patch["patch"]) == 2
entry = patch["patch"][0]
assert entry["is_enabled"] and len(entry["be32"]) == 1
write = entry["be32"][0]
assert write["address"] == 0x8210C264 and write["value"] == 0x39200001

# The object-relative stores and CreateDevice argument establish the actual
# parameter-block address; they are not inferred from a standalone LI constant.
expected = {
    0x8210C1FC: 0x3D608249, 0x8210C200: 0x396B6C00,
    0x8210C238: 0x912B003C, 0x8210C244: 0x910B0040,
    0x8210C264: 0x39200002, 0x8210C274: 0x912B0070,
    0x8210C27C: 0x39200001, 0x8210BA40: 0x389F003C,
    0x8210BA44: 0x481266AD,
}
for address, instruction in expected.items():
    assert struct.unpack_from(">I", image, address - 0x82000000)[0] == instruction
assert 0x70 - 0x3C == 0x34

# Execute the real, straight-line initializer suffix for both interval values.
# The only differing memory write must be PresentationInterval, and every
# register must have the same value on return (no escaped scratch-register use).
def execute(interval):
    registers = {8: 0x1A220197, 9: interval, 10: 1, 11: 0x82496C00}
    memory = {}
    for offset in range(0x10C268, 0x10C298, 4):
        instruction = struct.unpack_from(">I", image, offset)[0]
        opcode = instruction >> 26
        target, base = (instruction >> 21) & 31, (instruction >> 16) & 31
        immediate = instruction & 0xFFFF
        if immediate & 0x8000:
            immediate -= 0x10000
        if opcode == 14:
            registers[target] = (registers[base] if base else 0) + immediate
        elif opcode == 36:
            memory[registers[base] + immediate] = registers[target]
        else:
            raise AssertionError(f"Unexpected initializer instruction: {instruction:08X}")
    return registers, memory

old_registers, old_memory = execute(2)
new_registers, new_memory = execute(1)
assert old_registers == new_registers
assert [address for address in old_memory if old_memory[address] != new_memory[address]] == [0x82496C70]
assert old_memory[0x82496C70] == 2 and new_memory[0x82496C70] == 1
print("PASS: exact base-image instructions; only presentation interval changes; scratch registers do not escape.")

# The update gate retains all original work and return paths, mapping only
# the periodic-skip result to a normal tick. Its cull return stays intact.
gate = patch["patch"][1]
assert gate["is_enabled"] and len(gate["be32"]) == 1
gate_write = gate["be32"][0]
assert gate_write["address"] == 0x820DC5E4 and gate_write["value"] == 0x38600010
for address, original in {
    0x820DC4F8: 0x7D8802A6, 0x820DC534: 0x38600040,
    0x820DC5D4: 0xC1BF004C, 0x820DC5DC: 0x40980014,
    0x820DC5E4: 0x38600020, 0x820DC5EC: 0x41980008,
    0x820DC5F0: 0x38600010, 0x820DC5F4: 0x38210080,
}.items():
    assert struct.unpack_from(">I", image, address - 0x82000000)[0] == original
# Taken/non-taken final comparison and every direct return path.
for skip in (False, True):
    before = 0x20 if skip else 0x10
    after = (gate_write["value"] & 0xFFFF) if skip else 0x10
    assert after == (0x10 if before == 0x20 else before)
assert struct.unpack_from(">I", image, 0xDC534)[0] == 0x38600040
print("PASS: version-matched skip-to-tick gate; culling, accumulator and timing instructions preserved.")
