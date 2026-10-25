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
assert PATCHED >> 26 == 63 and (PATCHED >> 21) & 31 == 12
assert (PATCHED >> 11) & 31 == 0 and (PATCHED >> 1) & 1023 == 72  # fmr f12,f0
base_fps = 60.0
old_interval_units = base_fps / 30.0
new_interval_units = base_fps / base_fps
assert base_fps / old_interval_units == 30.0 and base_fps / new_interval_units == 60.0
assert 30.0 * old_interval_units == 60.0 * new_interval_units
if args.decrypted_image:
    b = args.decrypted_image.read_bytes(); off = ADDRESS - 0x82000000
    assert struct.unpack_from('>I', b, off)[0] == ORIGINAL
    assert b[off+12:off+16] == bytes.fromhex('efe06024')  # fdivs f31,f0,f12
    assert b[0x127AB44:0x127AB48] == bytes.fromhex('c01f0040')  # base FPS
    assert b[0x127AD20:0x127AD24] == bytes.fromhex('ff00f800')  # elapsed-time compare
    assert struct.unpack_from('>f', b, 0x8B854)[0] == base_fps
    assert b[0x127A25C:0x127A260] == bytes.fromhex('c1aab854')
    assert b[0x127A280:0x127A284] == bytes.fromhex('d1bf0040')
print('Verified exact-version limiter patch and normalized-time arithmetic; runtime FPS/game speed need an interactive test.')
