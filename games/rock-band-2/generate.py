from pathlib import Path

TITLE_ID = '45410869'
MODULE_HASH = 'B94DA74D17CDF26F'
ADDRESS = 0x821D0634
ORIGINAL = 0x91400000  # stw r10,0(0): deliberate exception to enter the main loop
DESTINATION = 0x82684C6C  # CRT wrapper that invokes the registered exception filter
PATCHED = 0x48000000 | ((DESTINATION - ADDRESS) & 0x03FFFFFC)
FILENAME = '45410869 - Rock Band 2 SEH Boot Fix.patch.toml'


def patch_text():
    return f'''title_name = "Rock Band 2"
title_id = "{TITLE_ID}"
hash = "{MODULE_HASH}"
# PAL disc, Media ID 6FC0755E. Exact module hash only.
# Adapted from Gliniak's Rock Band 3 SEH workaround:
# https://github.com/xenia-canary/game-patches/blob/main/patches/45410914%20-%20Rock%20Band%203.patch.toml
# RB2 diagnosis: https://github.com/xenia-canary/game-compatibility/issues/1032#issuecomment-4152611207

[[patch]]
    name = "Skip SEH null write at EA logo"
    desc = "Invoke the registered exception filter through the existing CRT wrapper instead of deliberately writing to address zero. The filter restores the previous handler and enters the game's main loop. Exact PAL executable only."
    author = "LilaQ; based on Gliniak's SEH workaround"
    is_enabled = true

    [[patch.be32]]
        address = 0x{ADDRESS:08X}
        value = 0x{PATCHED:08X}
'''


if __name__ == '__main__':
    Path(__file__).with_name(FILENAME).write_text(patch_text(), encoding='utf-8')
