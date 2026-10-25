from pathlib import Path

TITLE_ID = '43430819'
MODULE_HASH = '44A96367B5C19FB1'
ADDRESS = 0x8327ACC0
ORIGINAL = 0xC19F0044  # lfs f12,0x44(r31): mMaxFps
PATCHED = 0xFD800090   # fmr f12,f0: limit to the existing 60 Hz simulation base rate
FILENAME = '43430819 - Resident Evil 6 60FPS.patch.toml'


def patch_text():
    return f'''title_name = "Resident Evil 6"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"

[[patch]]
    name = "60 FPS - one render per base-rate tick"
    desc = "Use the existing 60 Hz simulation base rate as the variable render limiter. Preserve base timing and elapsed-time calculation. Use vsync=false and framerate_limit=0 in Canary; fixed-timestep modes are unchanged."
    author = "LilaQ"
    is_enabled = true

    [[patch.be32]]
        address = 0x{ADDRESS:08X}
        value = 0x{PATCHED:08X}
'''


if __name__ == '__main__':
    Path(__file__).with_name(FILENAME).write_text(patch_text(), encoding='utf-8')
