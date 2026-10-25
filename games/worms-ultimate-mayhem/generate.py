from pathlib import Path

TITLE_ID = '58410AFD'
MODULE_HASH = 'D6BB8FBE542043A8'
ADDRESS = 0x822890B0
ORIGINAL = 0x39400021  # li r10,33: default fixed update duration in milliseconds
PATCHED = 0x39400010   # li r10,16: simulation timing for 60 rendered frames/s; not an FPS unlock
FILENAME = '58410AFD - Worms Ultimate Mayhem 60FPS Timing.patch.toml'


def patch_text():
    return f'''title_name = "Worms Ultimate Mayhem"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"

[[patch]]
    name = "60 FPS simulation timing (requires 60 FPS rendering)"
    desc = "Changes simulation duration from 33 to 16 ms per rendered frame. Use only with actual 60 FPS rendering: vsync=false, framerate_limit=120 and readback_resolve=none in Canary. This does not unlock rendering; at 30 FPS it slows gameplay."
    author = "LilaQ"
    is_enabled = true

    [[patch.be32]]
        address = 0x{ADDRESS:08X}
        value = 0x{PATCHED:08X}
'''


if __name__ == '__main__':
    Path(__file__).with_name(FILENAME).write_text(patch_text(), encoding='utf-8')
