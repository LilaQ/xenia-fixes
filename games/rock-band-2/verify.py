import argparse
from pathlib import Path
import struct
import tomllib
from generate import ADDRESS, DESTINATION, FILENAME, MODULE_HASH, ORIGINAL, PATCHED, TITLE_ID, patch_text

parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', type=Path, help='Optional local image; never commit game data.')
args = parser.parse_args()
text = Path(__file__).with_name(FILENAME).read_text()
assert text == patch_text()
patch_file = tomllib.loads(text)
assert patch_file['title_id'] == TITLE_ID and patch_file['hash'] == MODULE_HASH
patch, = patch_file['patch']
assert patch['is_enabled'] and patch['be32'] == [{'address': ADDRESS, 'value': PATCHED}]
assert ORIGINAL == 0x91400000
assert PATCHED >> 26 == 18 and PATCHED & 3 == 0  # relative branch, no link
displacement = PATCHED & 0x03FFFFFC
if displacement & 0x02000000:
    displacement -= 0x04000000
assert ADDRESS + displacement == DESTINATION


def branch_target(word, address):
    assert word >> 26 == 18 and not word & 2
    offset = word & 0x03FFFFFC
    if offset & 0x02000000:
        offset -= 0x04000000
    return address + offset


if args.decrypted_image:
    image = args.decrypted_image.read_bytes()
    def word(address):
        return struct.unpack_from('>I', image, address - 0x82000000)[0]
    assert word(ADDRESS) == ORIGINAL
    assert word(ADDRESS - 4) == 0x39400001  # value 1 for intentional null write
    # Register the filter immediately before the null write.
    assert branch_target(word(ADDRESS - 12), ADDRESS - 12) == 0x826844B0
    # Wrapper invokes the CRT exception-filter dispatcher.
    assert branch_target(word(DESTINATION + 12), DESTINATION + 12) == 0x82684580
    assert word(DESTINATION + 16) == 0x7D084378  # marker after filter invocation
    # Registered filter restores the old filter, then enters the main loop.
    assert branch_target(word(0x821D05F4), 0x821D05F4) == 0x826844B0
    assert branch_target(word(0x821D0600), 0x821D0600) == 0x821D0368
    assert branch_target(word(0x821D0400), 0x821D0400) == 0x821D03A0

print('Verified exact-version SEH workaround, branch destination and filter-to-main-loop path. Windows boot needs an interactive test.')
