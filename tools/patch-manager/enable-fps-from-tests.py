"""Enable existing FPS patches for games marked untested in a playtest export.

Keeps upstream Title-ID/module-hash guards and unrelated patches/settings intact.
Preview by default. --apply requires that Xenia is closed; no LaunchBox XML writes.
"""
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse
import collections
import copy
import importlib.util
import json
import os
import re
import struct
import tomllib
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('config_merge', Path(__file__).with_name('apply-optimized-settings.py'))
cfg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)


def normal(path):
    return path.replace('/', '\\').casefold()


def game_config(command, lb):
    found = re.search(r'--config=(?:"([^"]+)"|(\S+))', command)
    if not found:
        return None
    path = found[1] or found[2]
    assert path.lower().startswith('d:\\launchbox\\'), path
    return lb / path[len('D:\\LaunchBox\\'):].replace('\\', '/')


def iso_resource(path, wanted):
    """Read only the directory chain containing the requested executable."""
    size, budget = path.stat().st_size, 16 * 1024 * 1024
    with path.open('rb') as stream:
        def read(offset, count):
            nonlocal budget
            assert 0 <= offset <= offset + count <= size and 0 <= count <= budget
            budget -= count
            stream.seek(offset)
            data = stream.read(count)
            assert len(data) == count
            return data
        for base in (0, 0xFB20, 0x20600, 0x2080000, 0xFD90000):
            if base + 65564 > size:
                continue
            header = read(base + 65536, 28)
            if header[:20] == b'MICROSOFT*XBOX*MEDIA':
                sector, length = struct.unpack_from('<II', header, 20)
                break
        else:
            raise ValueError(f'Xbox partition not found: {path.name}')
        parts = wanted.replace('\\', '/').strip('/').split('/')
        for depth, part in enumerate(parts):
            table = read(base + sector * 2048, length)
            nodes, seen, entry = [0], set(), None
            while nodes:
                node = nodes.pop()
                if node in seen:
                    continue
                seen.add(node)
                offset = node * 4
                assert offset + 14 <= len(table)
                left, right, sec, count, attrs, nlen = struct.unpack_from('<HHIIBB', table, offset)
                assert nlen and offset + 14 + nlen <= len(table)
                name = table[offset + 14:offset + 14 + nlen].decode('cp1252')
                if name.casefold() == part.casefold():
                    entry = sec, count, attrs
                    break
                nodes.extend(n for n in (left, right) if n)
            assert entry, (path, wanted)
            sector, length, attrs = entry
            if depth < len(parts) - 1:
                assert attrs & 16
            else:
                assert not attrs & 16
                return base + sector * 2048, length


def execution_id(path, command, config):
    settings = tomllib.loads(config.read_text()) if config else {}
    match = re.search(r'--launch_module=(?:"([^"]+)"|(\S+))', command)
    module = (match[1] or match[2]) if match else settings.get('General', {}).get('launch_module', '')
    offset, length = iso_resource(path, module or 'default.xex') if path.suffix.casefold() == '.iso' else (0, path.stat().st_size)
    with path.open('rb') as stream:
        stream.seek(offset)
        header = stream.read(min(0x364, length))
        if header[:4] in (b'LIVE', b'PIRS', b'CON '):
            return f'{struct.unpack_from(">I", header, 0x360)[0]:08X}'
        assert header[:4] == b'XEX2', (path, header[:4])
        count = struct.unpack_from('>I', header, 20)[0]
        assert count < 512 and 24 + count * 8 <= length
        stream.seek(offset + 24)
        headers = dict(struct.iter_unpack('>II', stream.read(count * 8)))
        assert headers[0x40006] + 24 <= length
        stream.seek(offset + headers[0x40006])
        execution = stream.read(24)
    return f'{struct.unpack_from(">I", execution, 12)[0]:08X}'


def inventory(export, lb):
    data = json.loads(export.read_text())
    assert data['kind'] == 'xbox360-playtests' and data['version'] in (1, 2)
    untested = [g for g in data['games'] if g.get('result', {}).get('status', 'untested') == 'untested']
    platform = ET.parse(lb / 'Data/Platforms/Microsoft Xbox 360.xml').getroot()
    paths = {normal(g.findtext('ApplicationPath', '')): g for g in platform.findall('Game')}
    names = collections.defaultdict(list)
    for game in platform.findall('Game'):
        names[game.findtext('Title')].append(game)
    emulators = {e.findtext('ID'): e for e in ET.parse(lb / 'Data/Emulators.xml').getroot().findall('Emulator')}
    result = []
    for row in untested:
        found = []
        for disc in row['discs']:
            path = disc['path']
            if not path.startswith('Games\\'):
                path = 'Games\\Microsoft Xbox 360\\' + path
            if normal(path) in paths:
                found.append(paths[normal(path)])
        found = found or names[row['title']]
        matches = {g.findtext('ID'): g for g in found}
        assert len(matches) == 1, (row['title'], list(matches))
        game = next(iter(matches.values()))
        entries = [game] + [a for a in platform.findall('AdditionalApplication')
                            if a.findtext('GameID') == game.findtext('ID')
                            and a.findtext('ApplicationPath', '').lower().endswith(('.iso', '.xex'))]
        targets = []
        for entry in entries:
            path = lb / entry.findtext('ApplicationPath').replace('\\', '/')
            eid = entry.findtext('EmulatorId') if entry.tag == 'AdditionalApplication' else entry.findtext('Emulator')
            eid = eid or game.findtext('Emulator')
            emulator = lb / emulators[eid].findtext('ApplicationPath').replace('\\', '/')
            assert 'Xenia' in str(emulator)
            command = entry.findtext('CommandLine') or game.findtext('CommandLine') or ''
            config = game_config(command, lb)
            targets.append(dict(path=path, config=config, emulator=emulator.parent,
                                title_id=execution_id(path, command, config)))
        result.append(dict(title=row['title'], id=game.findtext('ID'), targets=targets))
    return result


def selections(data):
    names = {p['name'] for p in data['patch']}
    selected = names & {'60 FPS', 'Unlock FPS', 'FPS Uncap', '60 FPS frame wait', '60 FPS - Game Speed Fix'}
    tid = data['title_id']
    # These unlocks only remove limits already higher than the requested 60.
    if str(tid).upper() in {'545407F2', '454108F7'}:
        return set()
    if '60 FPS' in selected:
        selected.discard('FPS Uncap')
    if selected and 'Havok physics FPS fix' in names:
        selected.add('Havok physics FPS fix')
    return selected


def enable_blocks(local, upstream, selected):
    """Replace only selected upstream blocks, retaining every other local block."""
    wanted = tomllib.loads(upstream.decode())
    before = tomllib.loads(local.decode())
    assert before['title_id'] == wanted['title_id'] and before['hash'] == wanted['hash']
    chunks = re.split(rb'(?m)(?=^\[\[patch\]\][ \t]*\r?$)', local)
    incoming = re.split(rb'(?m)(?=^\[\[patch\]\][ \t]*\r?$)', upstream)
    lookup = {tomllib.loads(b.decode())['patch'][0]['name']: b for b in incoming[1:]}
    changed, seen, merged = [], set(), [chunks[0]]
    for chunk in chunks[1:]:
        block = tomllib.loads(chunk.decode())['patch'][0]
        name = block['name']
        if name in selected:
            new = lookup[name]
            new, count = re.subn(rb'(?m)^(\s*is_enabled\s*=\s*)false\b', rb'\g<1>true', new)
            assert count == 1 or tomllib.loads(new.decode())['patch'][0]['is_enabled']
            if chunk != new:
                changed.append(name)
            chunk = new
            seen.add(name)
        merged.append(chunk)
    for name in sorted(selected - seen):
        new, count = re.subn(rb'(?m)^(\s*is_enabled\s*=\s*)false\b', rb'\g<1>true', lookup[name])
        assert count == 1
        merged.append(b'\n' + new)
        changed.append(name)
    result = b''.join(merged)
    after = tomllib.loads(result.decode())
    assert {k: v for k, v in before.items() if k != 'patch'} == {k: v for k, v in after.items() if k != 'patch'}
    assert [b for b in before['patch'] if b['name'] not in selected] == [b for b in after['patch'] if b['name'] not in selected]
    assert all(b['is_enabled'] for b in after['patch'] if b['name'] in selected)
    return result, changed


def prepare(items, upstream_dir):
    files = list(upstream_dir.glob('*.patch.toml'))
    grouped = collections.defaultdict(list)
    for path in files:
        data = tomllib.loads(path.read_text())
        tid = data['title_id']
        grouped[f'{tid:08X}' if isinstance(tid, int) else tid.upper()].append(path)
    originals, outputs, titles, changes, no_patch = {}, {}, [], [], []
    seen, new_fps_keys = set(), set()

    def output(path, data):
        old = path.read_bytes() if path.exists() else None
        originals.setdefault(path, old)
        if data != old:
            outputs[path] = data

    for game in items:
        supported = False
        for target in game['targets']:
            emulator, tid = target['emulator'], target['title_id']
            sources = grouped[tid] + list((emulator / 'patches').glob(tid + ' - *.patch.toml'))
            enabled, newly_enabled_fps = False, False
            for source in sources:
                data = tomllib.loads(source.read_text())
                chosen = selections(data)
                if not chosen:
                    continue
                enabled = supported = True
                dest = emulator / 'patches' / source.name
                if dest in seen:
                    continue
                seen.add(dest)
                old = dest.read_bytes() if dest.exists() else source.read_bytes()
                new, blocks = enable_blocks(old, source.read_bytes(), chosen)
                prior_blocks = {b['name']: b for b in tomllib.loads(old.decode())['patch']}
                if any(name != 'Havok physics FPS fix' and not prior_blocks.get(name, {}).get('is_enabled', False)
                       for name in chosen):
                    newly_enabled_fps = True
                    new_fps_keys.add((emulator, tid))
                output(dest, new)
                if blocks:
                    changes.append((game['title'], source.name, blocks))
            if not enabled:
                continue
            config = target['config']
            assert config and config.exists(), (game['title'], 'missing per-game config')
            opts = {'General.apply_patches': True}
            if newly_enabled_fps or (emulator, tid) in new_fps_keys or tid == '5454082B':
                opts['GPU.framerate_limit'] = 60
            current = tomllib.loads(config.read_text())
            if tid == '5454082B':
                if 'vsync' in current['GPU']:
                    opts['GPU.vsync'] = False
                elif 'guest_display_refresh_cap' in current['GPU']:
                    opts['GPU.guest_display_refresh_cap'] = False
            output(config, cfg.merge(config.read_bytes(), opts))
            override = emulator / 'config' / (tid + '.config.toml')
            if override.exists():
                partial = tomllib.loads(override.read_text())
                partial_opts = {k: v for k, v in opts.items() if k != 'General.apply_patches'
                                or partial.get('General', {}).get('apply_patches') is False}
                output(override, cfg.merge(override.read_bytes(), partial_opts))
            preset = emulator / 'PatchManager/optimized-settings.json'
            if preset.exists() and 'GPU.framerate_limit' in opts:
                raw = outputs.get(preset, preset.read_bytes())
                doc = json.loads(raw)
                prior = copy.deepcopy(doc)
                for row in doc.get('Overrides', []):
                    if row['TitleId'] == tid and 'GPU.framerate_limit' in row['Options']:
                        row['Options']['GPU.framerate_limit'] = '60'
                if prior != doc:
                    output(preset, (json.dumps(doc, ensure_ascii=False, indent=2) + '\n').encode())
        (titles if supported else no_patch).append(game['title'])
    return originals, outputs, titles, changes, no_patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--launchbox', type=Path, required=True)
    parser.add_argument('--patches', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    protected = [args.results, args.launchbox / 'Data/Platforms/Microsoft Xbox 360.xml', args.launchbox / 'Data/Emulators.xml']
    untouched = {p: p.read_bytes() for p in protected}
    items = inventory(args.results, args.launchbox)
    originals, outputs, titles, changes, no_patch = prepare(items, args.patches)
    print('Checked:', len(items), 'untested games; FPS options:', len(titles),
          '; no applicable FPS option:', len(no_patch), '; changed files:', len(outputs), flush=True)
    for title, filename, blocks in changes:
        print('PATCH', title, '|', filename, '|', ', '.join(blocks))
    print('FPS OPTIONS:', '; '.join(titles))
    if args.apply:
        for path, old in originals.items():
            assert (path.read_bytes() if path.exists() else None) == old, path
        backup = args.launchbox / 'Backups' / ('untested-fps-' + datetime.now(ZoneInfo('Europe/Berlin')).strftime('%Y%m%d-%H%M%S'))
        backup.mkdir()
        for path in outputs:
            if originals[path] is not None:
                dest = backup / path.relative_to(args.launchbox)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(originals[path])
                assert dest.read_bytes() == originals[path]
        for path, data in outputs.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + '.untested-fps.tmp')
            assert not temporary.exists()
            temporary.write_bytes(data)
            os.replace(temporary, path)
            assert path.read_bytes() == data
        print('Applied and verified. Backup:', backup)
    assert all(p.read_bytes() == old for p, old in untouched.items()), 'Protected input or LaunchBox XML changed'


if __name__ == '__main__':
    main()
