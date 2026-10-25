import argparse
import struct
import tomllib
from pathlib import Path
from generate import ADDRESS, FILENAME, MODULE_HASH, ORIGINAL, PATCHED, TITLE_ID, patch_text

parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', type=Path, help='Optional locally supplied decrypted image; never commit game data.')
args = parser.parse_args()
p = Path(__file__).with_name(FILENAME)
assert p.read_text() == patch_text()
data = tomllib.loads(p.read_text())
assert data['title_id'] == TITLE_ID and data['hash'] == MODULE_HASH
patch, = data['patch']
assert patch['is_enabled'] is True
entry, = patch['be32']
assert entry == {'address': ADDRESS, 'value': PATCHED}
assert ORIGINAL >> 26 == PATCHED >> 26 == 14
assert (ORIGINAL >> 21) & 31 == (PATCHED >> 21) & 31 == 10
assert (ORIGINAL >> 16) & 31 == (PATCHED >> 16) & 31 == 0
assert ORIGINAL & 0xffff == 33 and PATCHED & 0xffff == 16
if args.decrypted_image:
    image = args.decrypted_image.read_bytes()
    offset = ADDRESS - 0x82000000
    assert struct.unpack_from('>I', image, offset)[0] == ORIGINAL
    # The enclosing function selects the default only when the game has no
    # explicit fixed-update-time override in the app object at offset 0x5C.
    assert image[offset - 4:offset] == bytes.fromhex('8163005c')
    assert image[offset + 0x14:offset + 0x18] == bytes.fromhex('7d6a5b78')
    assert image[offset + 0x3c:offset + 0x40] == bytes.fromhex('ed4002f2')
print('Verified version-scoped patch structure and instruction; runtime FPS/speed need an interactive test.')
