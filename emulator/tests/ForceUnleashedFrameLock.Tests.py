"""Validate against the owner's decoded base image; no game data is shipped.

Usage: python3.11+ ForceUnleashedFrameLock.Tests.py /private/default.pe
"""
from pathlib import Path
import struct
import sys
import tomllib

image = Path(sys.argv[1]).read_bytes()
patch = tomllib.loads((Path(__file__).resolve().parents[1] /
    "game-patches/4C4107D2 - The Force Unleashed 60FPS.patch.toml").read_text())
assert patch["title_id"] == "4C4107D2"
assert patch["hash"] == "4C99AB5DF93A70F3"
assert len(patch["patch"]) == 1 and patch["patch"][0]["is_enabled"]
write, = patch["patch"][0]["be32"]
assert write == {"address": 0x821FF2EC, "value": 0x3960003C}

def word(address):
    return struct.unpack_from(">I", image, address - 0x82000000)[0]

# Connect the startup integer conversion to the named menu field and its
# actual timing-gate consumer, rather than replacing a shared float constant.
for address, instruction in {
    0x822079A8: 0x3960001E, 0x822079C4: 0x917F0068,
    0x821FF2DC: 0x7C9F2378, 0x821FF2E0: 0x7C7D1B78,
    0x821FF2EC: 0x817F0068, 0x821FF2F0: 0x7D6B07B4,
    0x821FF2F4: 0xF9610060, 0x821FF2F8: 0xC8010060,
    0x821FF2FC: 0xFC00069C, 0x821FF300: 0xFC000018,
    0x821FF304: 0xD01D0144, 0x821FF308: 0x897F0110,
    0x827EA6B4: 0x388A30C4, 0x827EA6BC: 0xC04A4BC0,
    0x827EA6C8: 0x816B6044, 0x827EA6CC: 0x38AB0144,
    0x82207294: 0xC03F0144, 0x822072A0: 0x4BFF5731,
    0x821FC9E8: 0xFFE00890, 0x821FCA84: 0xC14B1F48,
    0x821FCA8C: 0xC12A248C, 0x821FCA90: 0xFF1F5000,
    0x821FCAA4: 0xEC09F824, 0x821FCB20: 0xFF006800,
    0x821FCB24: 0x4099004C,
}.items():
    assert word(address) == instruction, f"Wrong base image at {address:08X}"
assert image[0x930C4:0x930C4 + 15] == b"Framerate Lock\0"
assert struct.unpack_from(">f", image, 0x4BC0)[0] == 60
assert struct.unpack_from(">f", image, 0x1F48)[0] == 0
assert struct.unpack_from(">f", image, 0x248C)[0] == 1

# Execute the original integer-to-single sequence, including its FPR bit
# reinterpretation. Both paths only store the selected cap to object+0x144;
# the incoming configuration and adjacent engine state remain unchanged.
def initialize(configured, patched):
    registers = {1: 0x1000, 29: 0x2000, 31: 0x3000}
    memory = {0x3068: configured, 0x2140: 0x11223344, 0x2148: 0x55667788}
    fpr = {}
    for address in range(0x821FF2EC, 0x821FF308, 4):
        instruction = write["value"] if patched and address == write["address"] else word(address)
        if instruction == 0x817F0068:
            registers[11] = memory[registers[31] + 0x68]
        elif instruction == 0x3960003C:
            registers[11] = 60
        elif instruction == 0x7D6B07B4:
            n = registers[11] & 0xFFFFFFFF
            registers[11] = n - 0x100000000 if n & 0x80000000 else n
        elif instruction == 0xF9610060:
            memory[registers[1] + 0x60] = registers[11]
        elif instruction == 0xC8010060:
            fpr[0] = memory[registers[1] + 0x60]
        elif instruction == 0xFC00069C:
            fpr[0] = float(fpr[0])
        elif instruction == 0xFC000018:
            fpr[0] = struct.unpack(">f", struct.pack(">f", fpr[0]))[0]
        elif instruction == 0xD01D0144:
            memory[registers[29] + 0x144] = fpr[0]
        else:
            raise AssertionError(f"Unexpected instruction {instruction:08X}")
    return memory

for configured in (0, 30, 60, 120):
    original = initialize(configured, False)
    patched = initialize(configured, True)
    assert original[0x2144] == float(configured)
    assert patched[0x2144] == 60.0
    assert patched[0x3068] == configured
    assert patched[0x2140] == original[0x2140] == 0x11223344
    assert patched[0x2148] == original[0x2148] == 0x55667788
assert abs(1 / initialize(30, True)[0x2144] - 1 / 60) < 1e-12
print("PASS: exact startup conversion, named frame-lock field and timing gate; 60 FPS target without changing shared constants or adjacent state.")
