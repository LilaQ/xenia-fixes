"""Validate patch preimages against locally decoded virtual PE images."""
import argparse
from pathlib import Path
import struct
import tomllib

parser = argparse.ArgumentParser()
parser.add_argument('image_directory', type=Path)
parser.add_argument('--homecoming-image', type=Path, required=True,
                    help='Decoded Homecoming virtual PE image (no game data is included).')
args = parser.parse_args()
expected = {
    0x820CA140: 0x38610050,
    0x820CA144: 0x485E3A39,
    0x820CA148: 0x28030000,
    0x820CA14C: 0x4082001C,
    0x822366C0: 0x39600002,
    0x822F9D48: 0x39600002,
    0x8256B858: 0x3940001E,
    0x82050710: 0x42054B18,
}
for path in sorted((Path(__file__).parent / 'patches').glob('*.toml')):
    data = tomllib.loads(path.read_text())
    if data['title_id'] == '4B4E07E5':
        image = args.homecoming_image.read_bytes()
        assert struct.unpack_from('>I', image, 0x8256B874 - 0x82000000)[0] == 0x915F00E4
        assert struct.unpack_from('>I', image, 0x8256B87C - 0x82000000)[0] == 0x915F00E8
        # SysUpdate_Render multiplies this millisecond interval by the counter
        # frequency and waits until that many ticks have passed.
        assert struct.unpack_from('>I', image, 0x8255B834 - 0x82000000)[0] == 0xC1AA0710
    else:
        module = 'sh2_360' if 'Hill 2' in data['title_name'] else 'sh3_360'
        image = (args.image_directory / (module + '.xex.pe')).read_bytes()
    for block in data['patch']:
        for word in block['be32']:
            addr = word['address']
            actual = struct.unpack_from('>I', image, addr - 0x82000000)[0]
            assert actual == expected[addr], (path.name, hex(addr), hex(actual))
    print(path.name, 'preimages verified')
