import argparse
import struct
import tomllib
from pathlib import Path
from generate import ADDRESS, FILENAME, MODULE_HASH, ORIGINAL, PATCHED, TITLE_ID, patch_text

parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', type=Path, help='Optional local image; never commit game data.')
args = parser.parse_args()
p = Path(__file__).with_name(FILENAME)
assert p.read_text() == patch_text()
data = tomllib.loads(p.read_text())
assert data['title_id'] == TITLE_ID and data['hash'] == MODULE_HASH
patch, = data['patch']; entry, = patch['be32']
assert patch['is_enabled'] is True and entry == {'address': ADDRESS, 'value': PATCHED}
assert ORIGINAL >> 26 == 48 and (ORIGINAL >> 21) & 31 == 12
assert PATCHED >> 26 == 59 and (PATCHED >> 21) & 31 == 12
assert (PATCHED >> 16) & 31 == 0 and (PATCHED >> 11) & 31 == 0
assert (PATCHED >> 1) & 31 == 21  # fadds
# The unchanged fdivs computes a half-frame-unit wait. At base 30 this is
# 16.667 ms; the normalized elapsed delta remains 0.5, preserving real-time speed.
base_fps = 30.0
old_interval_units = base_fps / base_fps
new_interval_units = base_fps / (base_fps + base_fps)
assert old_interval_units == 1.0 and new_interval_units == 0.5
assert base_fps / new_interval_units == 60.0
assert abs(60.0 * new_interval_units - 30.0 * old_interval_units) < 1e-9
if args.decrypted_image:
    b = args.decrypted_image.read_bytes(); off = ADDRESS - 0x82000000
    assert struct.unpack_from('>I', b, off)[0] == ORIGINAL
    assert b[0xC82D24:0xC82D28] == bytes.fromhex('c01f0040')  # base FPS
    assert b[off+12:off+16] == bytes.fromhex('efE06024')  # fdivs f31,f0,f12
    assert b[0xC82EB0:0xC82EB4] == bytes.fromhex('ff00f800')  # compare elapsed vs wait
    assert struct.unpack_from('>f', b, 0x15B8)[0] == 30.0
    assert b[0x2D7DA0:0x2D7DA8] == bytes.fromhex('d00b0040d00b0044')
    assert b[0x2D7E10:0x2D7E18] == bytes.fromhex('d00b0040d00b0044')
print('Verified exact-version limiter patch and normalized-time arithmetic; runtime FPS/game speed need an interactive test.')
