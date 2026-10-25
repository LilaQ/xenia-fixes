import struct, tomllib
from pathlib import Path
from generate import *
p=Path(__file__).with_name(FILENAME)
assert p.read_text()==patch_text()
d=tomllib.loads(p.read_text());assert d['hash']==MODULE_HASH
assert d['patch'][0]['be32']==[{'address':ADDRESS,'value':PATCHED},{'address':SECOND_ADDRESS,'value':SECOND_PATCHED}]
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--decrypted-image',type=Path);args=parser.parse_args()
if args.decrypted_image:
 b=args.decrypted_image.read_bytes();o=ADDRESS-0x82000000
 assert struct.unpack_from('>II',b,o)==(ORIGINAL,SECOND_ORIGINAL)
 assert b[o+12:o+16]==bytes.fromhex('efe06024') # base/render ratio
 assert b[o+0x5c:o+0x64]==bytes.fromhex('c01f0070ff00f800') # elapsed compare
 assert struct.unpack_from('>f',b,0x266c4)[0]==60.0
 assert PATCHED==SECOND_ORIGINAL # preserve r9 for following constant loads
 assert (SECOND_PATCHED>>21)&31==12 and (SECOND_PATCHED>>16)&31==9
 assert 0x82020000+(SECOND_PATCHED&65535)==0x820266c4
 c=bytearray(b);struct.pack_into('>II',c,o,PATCHED,SECOND_PATCHED)
 assert c[:o]==b[:o] and c[o+8:]==b[o+8:]
print('Verified exact TU6 instructions, explicit 60 constant, unchanged elapsed-time calculation; runtime test pending.')
