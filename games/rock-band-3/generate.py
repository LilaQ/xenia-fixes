"""Generate a local RB3 patch; game/key material is deliberately not committed."""
from pathlib import Path
import argparse
import re
import struct
import tomllib

ROOT = Path(__file__).parent
BASE = 0x82000000
CODE = 0x82C25000
KEYSET = 0x82C2E000
HASH = '88E6DC86853C2522'
FILENAME = '45410914 - Rock Band 3 Software AES.patch.toml'
CALLS = {0x828187D4: (0x483FB761, 'rb3_set_key'), 0x8281887C: (0x483FB6C9, 'rb3_aes_cbc')}

parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', required=True, type=Path)
parser.add_argument('--original-xex', required=True, type=Path)
parser.add_argument('--reference-crypto', required=True, type=Path,
                    help='Local RB3Enhanced source/xbox360_crypto.c, used only for its documented keyset.')
args = parser.parse_args()
image = args.decrypted_image.read_bytes()
xex = args.original_xex.read_bytes()
symbols = {parts[2]: int(parts[0], 16) for line in (ROOT / 'build/symbols.txt').read_text().splitlines() if len(parts := line.split()) == 3}
payload = (ROOT / 'build/payload.bin').read_bytes()
assert symbols['payload_code_end'] == CODE + len(payload)
assert symbols['payload_code_end'] < KEYSET
assert symbols['payload_end'] <= 0x82E30000
for address, length in [(CODE, len(payload)), (KEYSET, 64),
                        (symbols['selected_keys'], symbols['payload_end'] - symbols['selected_keys'])]:
    assert image[address - BASE:address - BASE + length] == bytes(length)
for address, (original, _) in CALLS.items():
    assert struct.unpack_from('>I', image, address - BASE)[0] == original

# State is placed in an already writable XEX data page, not a code page.
security = struct.unpack_from('>I', xex, 16)[0]
assert struct.unpack_from('>I', xex, security + 0x110)[0] == BASE
state_page = (symbols['selected_keys'] - BASE) // 65536
assert struct.unpack_from('>I', xex, security + 0x184 + 24 * state_page)[0] & 15 == 2

reference = args.reference_crypto.read_text().split('NewKeyset[64] = {', 1)[1].split('}', 1)[0]
keys = bytes(int(v, 16) for v in re.findall(r'0x([0-9a-fA-F]{2})', reference))
assert len(keys) == 64
header = f'''title_name = "Rock Band 3"
title_id = "45410914"
hash = "{HASH}"

[[patch]]
    name = "Software AES for song key loading"
    desc = "Replace the two missing XeKeys calls with software AES-CBC. Exact base executable only; keep the existing SEH start patch enabled."
    author = "LilaQ; follows RB3Enhanced's software crypto workaround"
    is_enabled = true
'''
text = header
for address, data in [(CODE, payload), (KEYSET, keys)]:
    text += f'\n    [[patch.array]]\n        address = 0x{address:08X}\n        value = "{data.hex()}"\n'
for address, (_, name) in CALLS.items():
    target = symbols[name]
    assert abs(target - address) < 0x02000000
    branch = 0x48000001 | ((target - address) & 0x03FFFFFC)
    text += f'\n    [[patch.be32]]\n        address = 0x{address:08X}\n        value = 0x{branch:08X}\n'
parsed = tomllib.loads(text)
assert parsed['hash'] == HASH and parsed['patch'][0]['is_enabled']
assert len(parsed['patch'][0]['array']) == 2 and len(parsed['patch'][0]['be32']) == 2
(ROOT / FILENAME).write_text(text)
print('Generated exact-base RB3 software AES patch; code padding, writable state page and both call sites verified. Game/key bytes remain local.')
