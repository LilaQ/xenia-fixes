"""Check the startup sync selection against the owner's decoded base image.

Usage: python3.11+ SpiderMan3PresentInterval.Tests.py /private/default.pe
Only patch metadata and validation code are distributed, never game images.
"""
from pathlib import Path
import struct
import sys
import tomllib

image = Path(sys.argv[1]).read_bytes()
patch = tomllib.loads((Path(__file__).resolve().parents[1] /
    "game-patches/415607E2 - Spider-Man 3 60FPS.patch.toml").read_text())
assert patch["title_id"] == "415607E2"
assert patch["hash"] == "74EB693009B1AF55"
assert len(patch["patch"]) == 1
entry = patch["patch"][0]
assert entry["is_enabled"] and len(entry["be32"]) == 1
write = entry["be32"][0]
assert write == {"address": 0x82833D60, "value": 0x38600001}

def word(address):
    return struct.unpack_from(">I", image, address - 0x82000000)[0]

for address, instruction in {
    0x82833D5C: 0x3D6082CB, 0x82833D60: 0x806B3C40,
    0x82833D64: 0x4801A41D, 0x82CB3C40: 2,
    0x8284E1A4: 0x7FC3F378, 0x8284E1A8: 0x4BFFFF51,
    0x8284E0FC: 0x2B030004, 0x8284E108: 0x398CE11C,
    0x8284E10C: 0x5460103A, 0x8284E110: 0x7C0C002E,
    0x8284E114: 0x7C0903A6, 0x8284E118: 0x4E800420,
    0x8284E168: 0x3D4082CB, 0x8284E16C: 0x906A50A8,
    0x8284E170: 0x3D4082FE, 0x8284E174: 0x394A40D0,
    0x8284E178: 0x916A0034, 0x8284E17C: 0x4E800020,
    0x8284DFD4: 0x39600001, 0x8284DFD8: 0x917F0034,
}.items():
    assert word(address) == instruction, f"Wrong base image at {address:08X}"

# Execute the real mode-1/mode-2 selector blocks and shared suffix. Verify that
# the ancillary flag write is identical and the only policy change is one
# versus two vblanks (plus recording the chosen mode).
def execute(mode):
    registers = {3: mode}
    memory = {}
    pc = word(0x8284E11C + mode * 4)
    for _ in range(20):
        instruction = word(pc)
        if instruction == 0x4E800020:
            return registers, memory
        opcode = instruction >> 26
        target, base = (instruction >> 21) & 31, (instruction >> 16) & 31
        immediate = instruction & 0xFFFF
        signed = immediate - 0x10000 if immediate & 0x8000 else immediate
        if opcode in (14, 15):
            registers[target] = ((registers[base] if base else 0) +
                (signed if opcode == 14 else signed << 16)) & 0xFFFFFFFF
        elif opcode == 36:
            memory[(registers[base] + signed) & 0xFFFFFFFF] = registers[target]
        elif opcode == 18:
            displacement = instruction & 0x3FFFFFC
            if displacement & 0x2000000:
                displacement -= 0x4000000
            assert not instruction & 3
            pc += displacement
            continue
        else:
            raise AssertionError(f"Unexpected instruction {instruction:08X}")
        pc += 4
    raise AssertionError("Selector did not return")

original_mode = word(0x82CB3C40)
patched_mode = write["value"] & 0xFFFF
old_registers, old_memory = execute(original_mode)
new_registers, new_memory = execute(patched_mode)
assert old_memory == {0x82FE4888: 0, 0x82CB50A8: 2, 0x82FE4104: 2}
assert new_memory == {0x82FE4888: 0, 0x82CB50A8: 1, 0x82FE4104: 1}
assert old_registers[10] == new_registers[10] == 0x82FE40D0
print("PASS: exact startup call and selector; late two-vblank mode becomes one; ancillary flag and call flow preserved.")
