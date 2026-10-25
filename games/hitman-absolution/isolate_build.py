"""Keep the verified Hitman build separate from ordinary Edge updates."""
import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import uuid
import xml.etree.ElementTree as ET

from build_fix import EDGE_SHA256
from install_fix import PATCHED_SHA256, digest

CUSTOM_EXE = 'xenia_edge_hitman.exe'
CUSTOM_EMULATOR_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, 'xenia-hitman-depth-fix'))


def unique_block(data, tag, field, value):
    matches = [m for m in re.finditer(rb'<' + tag.encode() + rb'>.*?</' + tag.encode() + rb'>', data, re.S)
               if ET.fromstring(m.group()).findtext(field) == value]
    if len(matches) != 1:
        raise ValueError('Expected exactly one ' + tag + ': ' + value)
    return matches[0]


def prepare(launchbox):
    emulators = launchbox / 'Data/Emulators.xml'
    platform = launchbox / 'Data/Platforms/Microsoft Xbox 360.xml'
    emulator_bytes, platform_bytes = emulators.read_bytes(), platform.read_bytes()
    game_match = unique_block(platform_bytes, 'Game', 'Title', 'Hitman: Absolution')
    game = ET.fromstring(game_match.group())
    old_id = game.findtext('Emulator')
    emulator_match = unique_block(emulator_bytes, 'Emulator', 'ID', old_id)
    emulator = ET.fromstring(emulator_match.group())
    if emulator.findtext('ApplicationPath') != r'Emulators\Xenia Edge\xenia_edge.exe':
        raise ValueError('Unexpected existing Hitman emulator; inspect it first')
    if b'<ID>' + CUSTOM_EMULATOR_ID.encode() + b'</ID>' in emulator_bytes:
        raise ValueError('Separate emulator already exists')
    emulator.find('ID').text = CUSTOM_EMULATOR_ID
    emulator.find('Title').text = 'Xenia Edge - Hitman Fix'
    emulator.find('ApplicationPath').text = 'Emulators\\Xenia Edge\\' + CUSTOM_EXE
    script = emulator.find('AutoHotkeyScript')
    if script is None or script.text.count('xenia_edge.exe') != 2:
        raise ValueError('Unexpected Keys2Pad watcher; inspect it first')
    script.text = script.text.replace('xenia_edge.exe', CUSTOM_EXE)
    # All other input, exit, pause and startup behaviour is cloned verbatim.
    additional = ET.tostring(emulator, encoding='utf-8')
    platform_links = [child for child in ET.fromstring(emulator_bytes)
                      if child.tag == 'EmulatorPlatform'
                      and child.findtext('Emulator') == old_id
                      and child.findtext('Platform') == game.findtext('Platform')]
    if len(platform_links) > 1:
        raise ValueError('Duplicate existing 360 platform associations')
    if platform_links:
        association = platform_links[0]
    else:
        association = ET.Element('EmulatorPlatform')
        for key, value in (('Emulator', old_id), ('Platform', game.findtext('Platform')),
                           ('CommandLine', ''), ('Default', 'false'),
                           ('M3uDiscLoadEnabled', 'false'), ('AutoExtract', 'false')):
            ET.SubElement(association, key).text = value
    association.find('Emulator').text = CUSTOM_EMULATOR_ID
    association.find('Default').text = 'false'
    additional += b'\n' + ET.tostring(association, encoding='utf-8')
    if emulator_bytes.count(b'</LaunchBox>') != 1:
        raise ValueError('Unexpected emulator XML root')
    new_emulators = emulator_bytes.replace(b'</LaunchBox>', additional + b'\n</LaunchBox>')
    old_reference = ('<Emulator>' + old_id + '</Emulator>').encode()
    new_reference = ('<Emulator>' + CUSTOM_EMULATOR_ID + '</Emulator>').encode()
    if game_match.group().count(old_reference) != 1:
        raise ValueError('Unexpected game emulator reference')
    new_game = game_match.group().replace(old_reference, new_reference)
    new_platform = platform_bytes[:game_match.start()] + new_game + platform_bytes[game_match.end():]
    assert len(ET.fromstring(new_platform).findall('Game')) == len(ET.fromstring(platform_bytes).findall('Game'))
    ET.fromstring(new_emulators)
    return {emulators: (emulator_bytes, new_emulators), platform: (platform_bytes, new_platform)}


def atomic_copy(source, target):
    temporary = target.with_name(target.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        shutil.copyfile(source, temporary)
        if digest(source) != digest(temporary):
            raise ValueError('Copy verification failed')
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()


def isolate(launchbox, original, apply=False):
    changes = prepare(launchbox)
    edge = launchbox / 'Emulators/Xenia Edge'
    normal, custom = edge / 'xenia_edge.exe', edge / CUSTOM_EXE
    if digest(normal) != PATCHED_SHA256 or digest(original) != EDGE_SHA256:
        raise ValueError('Expected verified modified live EXE and exact original backup')
    if custom.exists():
        raise ValueError('Separate executable already exists; inspect it first')
    protected = list((edge / 'config/games').glob('Hitman*Absolution*.toml'))
    protected += list((edge / 'patches').glob('53510804*.toml'))
    for folder in ('Xenia Edge', 'Xenia Canary'):
        for title in (launchbox / 'Emulators' / folder / 'content').glob('*/53510804'):
            protected += [p for p in title.rglob('*') if p.is_file()]
    unchanged = {p: digest(p) for p in protected}
    print('Prepared separate executable:', custom)
    print('Hitman emulator:', CUSTOM_EMULATOR_ID)
    print('Keys2Pad startup and shutdown watchers both use', CUSTOM_EXE)
    if not apply:
        return
    backup = launchbox / 'Backups' / ('hitman-isolate-build-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir()
    shutil.copy2(normal, backup / normal.name)
    assert digest(backup / normal.name) == PATCHED_SHA256
    for p, (old, _) in changes.items():
        (backup / p.name).write_bytes(old)
        assert (backup / p.name).read_bytes() == old
        assert p.read_bytes() == old, 'XML changed during preparation'
    try:
        atomic_copy(normal, custom)
        assert digest(custom) == PATCHED_SHA256
        atomic_copy(original, normal)
        assert digest(normal) == EDGE_SHA256
        for p, (old, new) in changes.items():
            assert p.read_bytes() == old, 'XML changed during preparation'
            p.write_bytes(new)
            assert p.read_bytes() == new
        for p, expected in unchanged.items():
            assert digest(p) == expected, 'Protected config or save changed: ' + str(p)
    except BaseException:
        for p, (old, new) in changes.items():
            if p.read_bytes() == new:
                p.write_bytes(old)
        if digest(normal) == EDGE_SHA256:
            atomic_copy(backup / normal.name, normal)
        # Keep any created custom EXE as recovery input instead of deleting it.
        raise
    print('Installed and byte-verified; original Edge restored. Backup:', backup)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launchbox', type=Path, required=True)
    parser.add_argument('--original', type=Path, required=True)
    parser.add_argument('--apply', action='store_true', help='Only with LaunchBox, Big Box and Xenia closed')
    args = parser.parse_args()
    isolate(args.launchbox, args.original, args.apply)
