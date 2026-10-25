from pathlib import Path

PATCH_NAME = '415607DE - Wolfenstein Singleplayer 60FPS.patch.toml'
PATCH = '''title_name = "Wolfenstein"
title_id = "415607DE"
hash = "D4A77E183B2D6868" # Singleplayer default.xex, base version 0.0.7978.32
# media_id = "3C343D7F"

[[patch]]
name = "60 FPS - one simulation tick per rendered frame"
desc = "Overrides com_minTics at the frame wait: 1 instead of the default 2. The 60 Hz simulation clock and elapsed-time calculation are unchanged. Use normal time_scalar and 60 Hz guest display timing. Multiplayer and title updates need separate verification."
author = "LilaQ"
is_enabled = true

[[patch.be32]]
address = 0x82269D68
value = 0x39600001 # li r11, 1; original lwz r11, 0x24(r11) = 0x816B0024
'''

if __name__ == '__main__':
    target = Path(__file__).parent / PATCH_NAME
    target.write_text(PATCH)
    print(target)
