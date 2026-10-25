from pathlib import Path
import tomllib

ROOT = Path(__file__).parent

def header(title, module_hash):
    return f'title_name = "{title}"\ntitle_id = "4B4E0845"\nhash = "{module_hash}"\n# Media 625FCB0C, base version 00000005.\n'

def fps(address):
    return f'''
[[patch]]
    name = "60 FPS presentation interval"
    desc = "Changes D3D presentation from two refresh intervals to one. Keep display at 60 Hz and time_scalar at 1. Gameplay and cutscene timing need an interactive check."
    author = "Local cabinet patch"
    is_enabled = true
    [[patch.be32]]
        address = 0x{address:08X} # li r11,2; D3DPRESENT_PARAMETERS + 0x34
        value = 0x39600001 # li r11,1; original 0x39600002
'''

def voice(flag):
    label = 'Original Voices' if flag == 0 else 'New Voices'
    values = [0x3D408288, 0x39600000 | flag, 0x996AE330, 0x4800001C]
    text = f'''
[[patch]]
    name = "Direct-start {label}"
    desc = "Sets the launcher's voice flag explicitly, independent of pending launch data. Zero uses original XMA files; one selects the .new files. Use an isolated patch root for each voice variant."
    author = "Local cabinet patch"
    is_enabled = true
'''
    for i, value in enumerate(values):
        text += f'    [[patch.be32]]\n        address = 0x{0x820CA140 + 4*i:08X}\n        value = 0x{value:08X}\n'
    return text

outputs = {}
for flag, label in [(0, 'Original Voices'), (1, 'New Voices')]:
    outputs[f'4B4E0845 - Silent Hill 2 HD {label}.patch.toml'] = header('Silent Hill 2 HD', 'F3CA6A39460AF335') + fps(0x822366C0) + voice(flag)
outputs['4B4E0845 - Silent Hill 3 HD 60FPS.patch.toml'] = header('Silent Hill 3 HD', '4DC9FF869FF55A1F') + fps(0x822F9D48)
outputs['4B4E07E5 - Silent Hill Homecoming 60FPS.patch.toml'] = '''title_name = "Silent Hill: Homecoming"
title_id = "4B4E07E5"
hash = "3DB72D7712F6ECD9"
# PAL media 7F02C49C, base version 00000003.

[[patch]]
    name = "60 FPS engine limits and render pacing"
    desc = "Raises fpsLimit and maxFPSLimit to 60 and halves the independent render wait from 33.323 ms to 16.657 ms. Keep time_scalar at 1. Gameplay, cutscenes and QTE timing require an interactive check."
    author = "Local cabinet patch"
    is_enabled = true
    [[patch.be32]]
        address = 0x8256B858 # li r10,30; stores to engine fields +0xE4 and +0xE8
        value = 0x3940003C # li r10,60; original 0x3940001E
    [[patch.be32]]
        address = 0x82050710 # Only read by SysUpdate_Render's counter-based frame wait
        value = 0x418540DA # 1000/60 - 0.01 ms; original 0x42054B18 (1000/30 - 0.01)
'''
for name, text in outputs.items():
    value = tomllib.loads(text)
    assert all(p['is_enabled'] for p in value['patch'])
    (ROOT / 'patches' / name).write_text(text)
print('Generated four hash-bound patch files; SH2 variants must use separate patch roots.')
