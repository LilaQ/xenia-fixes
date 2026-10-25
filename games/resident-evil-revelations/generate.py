from pathlib import Path

TITLE_ID = '43430833'
MODULE_HASH = 'ADE9590DE9F292C9'
ADDRESS = 0x829CA920
ORIGINAL = 0xC19F0044  # lfs f12,0x44(r31): variable render limit
PATCHED = 0x3D208201   # lis r9,0x8201: move the existing address setup earlier
SECOND_ADDRESS = ADDRESS + 4
SECOND_ORIGINAL = 0x3D208201
SECOND_PATCHED = 0xC189D0C4  # lfs f12,-0x2f3c(r9): original 60.0 constant
FILENAME = '43430833 - Resident Evil Revelations 60FPS.patch.toml'


def patch_text():
    return f'''title_name = "Resident Evil Revelations"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"

[[patch]]
    name = "60 FPS - explicit render limit"
    desc = "Load the original 60.0 constant as the variable render limiter. Preserve the game-specific 30 Hz simulation base and elapsed-time calculation. Use vsync=false and framerate_limit=0 in Canary. Fixed-timestep modes are unchanged."
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
