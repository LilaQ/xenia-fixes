"""Validate the patch against the owner's decoded base-version image.

Usage: python3.11+ ShatteredDimensionsPresentInterval.Tests.py /private/default.pe
No game image is stored in this repository.
"""
from pathlib import Path
import struct
import sys
import tomllib

image = Path(sys.argv[1]).read_bytes()
patch = tomllib.loads((Path(__file__).resolve().parents[1] /
    "game-patches/41560881 - Shattered Dimensions 60FPS.patch.toml").read_text())
assert patch["title_id"] == "41560881"
assert patch["hash"] == "B6F12EF2A529FDE4"
assert len(patch["patch"]) == 1
entry = patch["patch"][0]
assert entry["is_enabled"] and len(entry["be32"]) == 1
write = entry["be32"][0]
assert write == {"address": 0x820F5850, "value": 0x38600001}

def word(address):
    return struct.unpack_from(">I", image, address - 0x82000000)[0]

# Establish the parameter-block address through the initializer and its caller,
# not merely a constant that happens to equal 2. The caller ignores r3 after
# initialization and supplies the same object's +4 to CreateDevice.
for address, instruction in {
    0x820F4E7C: 0x7C7F1B78, 0x820F4EE4: 0x7FE3FB78,
    0x820F4EEC: 0x4800083D, 0x820F5728: 0x7D8802A6,
    0x820F5740: 0x7C7F1B78, 0x820F5830: 0x88CB79EC,
    0x820F5838: 0x7CC50034, 0x820F5844: 0x54A4DFFE,
    0x820F584C: 0x688B0001, 0x820F5850: 0x386B0001,
    0x820F5854: 0x907F0038, 0x820F586C: 0x917F0004,
    0x820F5870: 0x915F0008, 0x820F4F08: 0x3C6000C0,
    0x820F4F30: 0x389F0004, 0x820F4F34: 0x48113B35,
}.items():
    assert word(address) == instruction, f"Wrong base image at {address:08X}"
assert 0x38 - 4 == 0x34

# Execute the actual branchless suffix with both flag states and non-boolean
# flag values. The patch must only alter the presentation field; all other
# output registers must agree, apart from the unused return value r3.
def execute(flag, patched):
    registers = {6: flag, 7: 0x1A220197, 29: 1, 31: 0x100000}
    memory = {0x100130: 1280, 0x100134: 720, 0x100138: 0}
    for address in range(0x820F5838, 0x820F5878, 4):
        instruction = write["value"] if patched and address == write["address"] else word(address)
        opcode = instruction >> 26
        target, base = (instruction >> 21) & 31, (instruction >> 16) & 31
        immediate = instruction & 0xFFFF
        signed = immediate - 0x10000 if immediate & 0x8000 else immediate
        if instruction == 0x7CC50034:  # cntlzw r5,r6
            registers[5] = 32 - registers[6].bit_length()
        elif instruction == 0x54A4DFFE:  # rlwinm r4,r5,27,31,31
            registers[4] = (registers[5] >> 5) & 1
        elif opcode == 26:  # xori rA,rS,UI
            registers[base] = registers[target] ^ immediate
        elif opcode == 14:  # addi / li
            registers[target] = (registers[base] if base else 0) + signed
        elif opcode == 32:  # lwz
            registers[target] = memory[registers[base] + signed]
        elif opcode == 36:  # stw
            memory[registers[base] + signed] = registers[target]
        else:
            raise AssertionError(f"Unexpected instruction {instruction:08X}")
    return registers, memory

for flag in (0, 1, 2, 255):
    old_registers, old_memory = execute(flag, False)
    new_registers, new_memory = execute(flag, True)
    assert old_memory[0x100038] == (2 if flag else 1)
    assert new_memory[0x100038] == 1
    changed = {a for a in old_memory if old_memory[a] != new_memory[a]}
    assert changed == ({0x100038} if flag else set())
    assert {r: v for r, v in old_registers.items() if r != 3} == {
        r: v for r, v in new_registers.items() if r != 3}
print("PASS: exact base-image initializer and CreateDevice call; only presentation interval changes for all flag states.")
