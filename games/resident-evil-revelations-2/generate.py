from pathlib import Path

TITLE_ID = '5841144C'
MODULE_HASH = '9FBE98182B30938E'
ADDRESS = 0x82F38E38
ORIGINAL = 0xC19F0044  # lfs f12,0x44(r31): variable render limit
PATCHED = 0x3D208202   # lis r9,0x8202: move the existing address setup earlier
SECOND_ADDRESS = ADDRESS + 4
SECOND_ORIGINAL = 0x3D208202
SECOND_PATCHED = 0xC18966C4  # lfs f12,0x66c4(r9): original 60.0 constant
FILENAME = '5841144C - Resident Evil Revelations 2 60FPS.patch.toml'


def patch_text():
    return f'''title_name = "Resident Evil Revelations 2"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"

[[patch]]
    name = "60 FPS - explicit render limit"
    desc = "Load the original 60.0 constant as the variable render limiter. Preserve the existing simulation base and elapsed-time calculation. Use vsync=false and framerate_limit=0 in Canary. Fixed-timestep modes are unchanged."
    author = "LilaQ"
    is_enabled = true

    [[patch.be32]]
        address = 0x{ADDRESS:08X}
        value = 0x{PATCHED:08X}

    [[patch.be32]]
        address = 0x{SECOND_ADDRESS:08X}
        value = 0x{SECOND_PATCHED:08X}
'''


if __name__ == '__main__':
    Path(__file__).with_name(FILENAME).write_text(patch_text(), encoding='utf-8')
