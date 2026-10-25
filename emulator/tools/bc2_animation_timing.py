"""Build the PAL BC2 variable-frame root-motion validity correction.

Only the local minimum-duration load in the animation buffer consumer changes.
The shared 20 ms constant, time scale, AI logic and mission data remain intact.
"""
from pathlib import Path
import argparse
import struct

SITES = {0x82E36A10: (0x3D6082A1, 0x3D6082A0),
         0x82E36A14: (0xC1AB7884, 0xC1AB0D58)}

def build(image: bytes) -> str:
    for address, (expected, _) in SITES.items():
        actual = struct.unpack_from('>I', image, address - 0x82A00000)[0]
        if actual != expected:
            raise ValueError(f'Unexpected instruction at {address:08X}: {actual:08X}')
    for address, expected in [(0x82A17884, 0x3CA3D70A), (0x82A00D58, 0x358637BD)]:
        if struct.unpack_from('>I', image, address - 0x82A00000)[0] != expected:
            raise ValueError(f'Unexpected time constant at {address:08X}')
    header = '''title_name = "Battlefield: Bad Company 2"
title_id = "454108A8"
hash = "C1F8A2BE5BCF6B96"

[[patch]]
name = "Variable-frame animation root motion"
is_enabled = true
# The animation buffer consumer discarded movement when accumulated duration
# was below 0.02 s. At 60 FPS its normal 1/60 s step fails that validity check.
# Use the engine's existing 1e-6 s epsilon at this call site only.
# No mission/trigger edits, shared-constant edits, or simulation-speed changes.
'''
    return header + ''.join(f'\n[[patch.be32]]\naddress = 0x{a:08X}\nvalue = 0x{v:08X}\n'
                            for a, (_, v) in SITES.items())

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('memory_image', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.write_text(build(args.memory_image.read_bytes()))
    print('Verified original instructions and constants; generated two-instruction patch.')
