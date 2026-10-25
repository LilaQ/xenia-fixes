"""Execute the compiled PowerPC hooks against published AES-CBC test vectors."""
from pathlib import Path
import sys
import struct
import os
import argparse

if os.environ.get('RB3_UNICORN_MODULES'):
    sys.path.insert(0, os.environ['RB3_UNICORN_MODULES'])
from unicorn import Uc, UC_ARCH_PPC, UC_MODE_32, UC_MODE_BIG_ENDIAN
from unicorn.ppc_const import UC_PPC_REG_0, UC_PPC_REG_1, UC_PPC_REG_LR

ROOT = Path(__file__).parent
parser = argparse.ArgumentParser()
parser.add_argument('--decrypted-image', type=Path, help='Optional local RB3 image for checking original Xbox call wrappers.')
args = parser.parse_args()
symbols = {parts[2]: int(parts[0], 16) for line in (ROOT / 'build/symbols.txt').read_text().splitlines() if len(parts := line.split()) == 3}
payload = (ROOT / 'build/payload.bin').read_bytes()
assert symbols['payload_code_end'] < 0x82C2E000
assert 0x82E2C000 <= symbols['selected_keys'] < symbols['payload_end'] <= 0x82E30000
assert symbols['rb3_set_key'] == 0x82C25000
u = Uc(UC_ARCH_PPC, UC_MODE_32 | UC_MODE_BIG_ENDIAN)
u.mem_map(0x82000000, 0x1000000)
u.mem_map(0x10000000, 0x10000)
u.mem_map(0x70000000, 0x10000)
u.mem_write(0x82C25000, payload)
key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
iv = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51')
cipher = bytes.fromhex('7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2')
u.mem_write(0x82C2E000, key * 4)


def call(name, *args):
    for r in range(32):
        u.reg_write(UC_PPC_REG_0 + r, 0x10100000 + r)
    u.reg_write(UC_PPC_REG_1, 0x7000F000)
    for r, value in enumerate(args, 3):
        u.reg_write(UC_PPC_REG_0 + r, value)
    u.reg_write(UC_PPC_REG_LR, 0x82FF0000)
    before = [u.reg_read(UC_PPC_REG_0 + r) for r in (2, 13, *range(14, 32))]
    u.emu_start(symbols[name], 0x82FF0000, count=1000000)
    assert u.reg_read(UC_PPC_REG_1) == 0x7000F000
    assert before == [u.reg_read(UC_PPC_REG_0 + r) for r in (2, 13, *range(14, 32))]
    return u.reg_read(UC_PPC_REG_0 + 3)


assert call('rb3_set_key', 0xE0, 0x82C45AF0, 16) == 0
u.mem_write(0x10000000, cipher)
u.mem_write(0x10002000, iv)
assert call('rb3_aes_cbc', 0xE0, 0x10000000, 32, 0x10001000, 0x10002000, 0) == 0
assert bytes(u.mem_read(0x10001000, 32)) == plain
assert bytes(u.mem_read(0x10002000, 16)) == cipher[-16:]

u.mem_write(0x10000000, plain)
u.mem_write(0x10002000, iv)
assert call('rb3_aes_cbc', 0xE0, 0x10000000, 32, 0x10000000, 0x10002000, 1) == 0
assert bytes(u.mem_read(0x10000000, 32)) == cipher

# Mirror RB3's null-IV, 16-byte decrypt flow, including feed continuation.
assert call('rb3_set_key', 0xE0, 0x82C45AF0, 16) == 0
u.mem_write(0x10000000, cipher)
assert call('rb3_aes_cbc', 0xE0, 0x10000000, 16, 0x10001000, 0, 0) == 0
assert bytes(u.mem_read(0x10001000, 16)) == bytes(a ^ b for a, b in zip(plain[:16], iv))
assert call('rb3_aes_cbc', 0xE0, 0x10000010, 16, 0x10001010, 0, 0) == 0
assert bytes(u.mem_read(0x10001010, 16)) == plain[16:]

# Key-slot isolation and resetting a key must reset that slot's feed.
assert call('rb3_set_key', 0xE1, 0x82C45B00, 16) == 0
assert call('rb3_aes_cbc', 0xE1, 0x10000000, 16, 0x10001000, 0, 0) == 0
assert bytes(u.mem_read(0x10001000, 16)) == bytes(a ^ b for a, b in zip(plain[:16], iv))
assert call('rb3_set_key', 0xE0, 0x82C45AF0, 16) == 0
assert call('rb3_aes_cbc', 0xE0, 0x10000000, 16, 0x10001000, 0, 0) == 0
assert bytes(u.mem_read(0x10001000, 16)) == bytes(a ^ b for a, b in zip(plain[:16], iv))
assert call('rb3_set_key', 0xDF, 0x82C45AF0, 16) == 0xC8000003
assert call('rb3_set_key', 0xE0, 0x82C45AF1, 16) == 0xC8000003
assert call('rb3_aes_cbc', 0xE0, 0x10000000, 15, 0x10001000, 0, 0) == 0xC8000003
print('PowerPC AES-CBC NIST vectors, in-place use, null-IV feed continuation/reset, slot isolation and preserved nonvolatile registers verified.')

if args.decrypted_image:
    image = args.decrypted_image.read_bytes()
    u.mem_write(0x82000000, image)
    u.mem_write(0x82C25000, payload)
    u.mem_write(0x82C2E000, key * 4)
    for address, name in [(0x828187D4, 'rb3_set_key'), (0x8281887C, 'rb3_aes_cbc')]:
        branch = 0x48000001 | ((symbols[name] - address) & 0x03FFFFFC)
        u.mem_write(address, struct.pack('>I', branch))
    symbols['game_set'] = 0x82818790
    symbols['game_cbc'] = 0x82818828
    assert call('game_set', 0, 0x82C45AF0, 16) == 0
    u.mem_write(0x10000000, cipher[:16])
    assert call('game_cbc', 0, 0x10000000, 16, 0x10001000) == 0
    assert bytes(u.mem_read(0x10001000, 16)) == bytes(a ^ b for a, b in zip(plain[:16], iv))
    print('Original Xbox wrappers execute the replacement PowerPC code successfully with correct CBC result and restored stack/registers.')
