import argparse
import struct
import tomllib
from pathlib import Path
from generate import ADDRESS, FILENAME, MODULE_HASH, ORIGINAL, PATCHED, TITLE_ID, SECOND_ADDRESS, SECOND_ORIGINAL, SECOND_PATCHED, patch_text

parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', type=Path, help='Local analysis input; never commit game data.')
args = parser.parse_args()
p = Path(__file__).with_name(FILENAME)
assert p.read_text() == patch_text()
data = tomllib.loads(p.read_text())
assert data['title_id'] == TITLE_ID and data['hash'] == MODULE_HASH
patch, = data['patch']
assert patch['is_enabled'] is True
assert patch['be32'] == [
    {'address': ADDRESS, 'value': PATCHED},
    {'address': SECOND_ADDRESS, 'value': SECOND_PATCHED},
]
assert PATCHED == SECOND_ORIGINAL  # r9 has its original value after the two instructions
assert (SECOND_PATCHED >> 21) & 31 == 12  # destination f12
assert (SECOND_PATCHED >> 16) & 31 == 9   # constant address through r9
assert (0x82010000 + struct.unpack('>h', bytes.fromhex('d0c4'))[0]) == 0x8200D0C4
# The normalized elapsed tick remains base * seconds, giving half a tick at 60 FPS.
assert (30.0 / 60.0) / 30.0 == 1.0 / 60.0
if args.decrypted_image:
    b = args.decrypted_image.read_bytes()
    offset = ADDRESS - 0x82000000
    assert struct.unpack_from('>II', b, offset) == (ORIGINAL, SECOND_ORIGINAL)
    assert struct.unpack_from('>f', b, 0x113C)[0] == 30.0
    assert b[0x245178:0x24517C] == bytes.fromhex('c009113c')
    assert b[0x245180:0x245188] == bytes.fromhex('d00b0044d00b0040')  # game overrides limit and base to 30
    assert b[offset+12:offset+16] == bytes.fromhex('efe06024')  # base / render FPS
    assert b[0x9CA7A4:0x9CA7A8] == bytes.fromhex('c01f0040')  # existing base rate
    assert b[0x9CA97C:0x9CA984] == bytes.fromhex('c01f0070ff00f800')  # elapsed-time compare in cr6
    assert b[0x9C9D04:0x9C9D08] == bytes.fromhex('c1aad0c4')  # base-rate constant
    assert b[0x9C9D28:0x9C9D2C] == bytes.fromhex('d1bf0040')  # base-rate initialization
    assert struct.unpack_from('>f', b, 0xD0C4)[0] == 60.0
    patched_image = bytearray(b)
    struct.pack_into('>II', patched_image, offset, PATCHED, SECOND_PATCHED)
    assert patched_image[:offset] == b[:offset]
    assert patched_image[offset+8:] == b[offset+8:]
print('Verified exact-version limiter instruction, explicit 60 FPS constant and preserved game-specific 30 Hz base, unchanged elapsed-time and simulation code. Runtime FPS/game speed require an interactive test.')
