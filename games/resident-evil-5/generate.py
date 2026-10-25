from pathlib import Path

TITLE_ID = '434307D4'
MODULE_HASH = 'EBE8DC47EB9402EC'
ADDRESS = 0x82C82E50
ORIGINAL = 0xC19F0044  # lfs f12,0x44(r31): mMaxFps
PATCHED = 0xED80002A   # fadds f12,f0,f0: twice the simulation base FPS
FILENAME = '434307D4 - Resident Evil 5 60FPS.patch.toml'


def patch_text():
    return f'''title_name = "Resident Evil 5"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"

[[patch]]
    name = "60 FPS - doubled rendering cadence"
    desc = "Set the variable frame limiter to twice the simulation base FPS (30 to 60 in gameplay). Preserve the simulation base rate and elapsed-time calculation. Use vsync=false and framerate_limit=0 in Canary; the game retains its own limiter. Fixed-timestep modes are unchanged."
    author = "LilaQ"
    is_enabled = true

    [[patch.be32]]
        address = 0x{ADDRESS:08X}
        value = 0x{PATCHED:08X}
'''


if __name__ == '__main__':
    Path(__file__).with_name(FILENAME).write_text(patch_text(), encoding='utf-8')
