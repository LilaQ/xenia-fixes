from pathlib import Path
import argparse
import struct
import tomllib
from generate import PATCH, PATCH_NAME

parser = argparse.ArgumentParser()
parser.add_argument('--image', type=Path, required=True, help='Decompressed XEX virtual PE image; not distributed with this repository')
args = parser.parse_args()
image = args.image.read_bytes()
base = 0x82000000
u32 = lambda address: struct.unpack_from('>I', image, address - base)[0]
string = lambda address: image[address-base:].split(b'\0', 1)[0]
assert u32(0x82269D68) == 0x816B0024
assert string(u32(0x82C86418)) == b'com_minTics'
assert string(u32(0x82C8641C)) == b'2'
assert string(u32(0x82C84A60)) == b'com_userCommandHz'
assert string(u32(0x82C84A64)) == b'60'
# Check the wait uses minTics only when above one, then waits for the tick counter.
expected = [0x396B6414, 0x3BA90001, 0x816B002C, 0x816B0024, 0x2F0B0001, 0x4099000C]
actual = [u32(0x82269D5C + i*4) for i in range(len(expected))]
assert actual == expected, [hex(x) for x in actual]
patch = tomllib.loads(PATCH)
assert patch['hash'] == 'D4A77E183B2D6868'
assert len(patch['patch']) == 1 and patch['patch'][0]['is_enabled']
assert patch['patch'][0]['be32'] == [{'address':0x82269D68, 'value':0x39600001}]
assert (Path(__file__).parent/PATCH_NAME).read_text() == PATCH
print('Verified original instruction, engine cvars, frame wait control flow and generated single-instruction patch.')
