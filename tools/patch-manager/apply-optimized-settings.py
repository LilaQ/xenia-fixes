"""Merge local Xenia Manager recommendations into an existing LaunchBox library.

The library input is the cabinet's previously verified Title-ID inventory. All
live writes require a prepared, reviewed plan and create a dated backup first.
"""
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse, copy, hashlib, json, os, re, xml.etree.ElementTree as ET
try:
    import tomllib
except ImportError:
    from pip._vendor import tomli as tomllib

CANARY = '172cd787-98f0-4b99-b10c-db5b0782916f'
MANAGED_KEYS = {'GPU.framerate_limit', 'GPU.vsync', 'CPU.break_on_debugbreak'}


def flatten(data, prefix=''):
    result = {}
    for key, value in data.items():
        name = (prefix + '.' + key).strip('.')
        if isinstance(value, dict):
            result.update(flatten(value, name))
        else:
            result[name] = value
    return result


def literal(value):
    if isinstance(value, bool):
        return str(value).lower()
    return json.dumps(value, ensure_ascii=False)


def parsed(data):
    return flatten(tomllib.loads(data.decode('utf-8-sig')))


def merge(data, options):
    text = data.decode('utf-8-sig')
    newline = '\r\n' if '\r\n' in text else '\n'
    expected = parsed(data)
    for name, value in options.items():
        if expected.get(name) == value:
            continue
        section, key = name.rsplit('.', 1)
        header = re.search(r'(?m)^\[' + re.escape(section) + r'\][ \t]*(?:#[^\r\n]*)?\r?\n', text)
        if not header:
            text = text.rstrip() + newline * 2 + '[' + section + ']' + newline + key + ' = ' + literal(value) + newline
        else:
            next_section = re.search(r'(?m)^\[', text[header.end():])
            end = header.end() + next_section.start() if next_section else len(text)
            body = text[header.end():end]
            pattern = r'(?m)^([ \t]*' + re.escape(key) + r'[ \t]*=[ \t]*)([^#\r\n]*)([^\r\n]*)'
            match = re.search(pattern, body)
            if match:
                token = literal(value)
                body, count = re.subn(pattern, lambda m: m[1] + token + ' ' * max(1, len(m[2]) - len(token)) + m[3], body)
                assert count == 1, name
            else:
                body = key + ' = ' + literal(value) + newline + body
            text = text[:header.end()] + body + text[end:]
        expected[name] = value
    result = text.encode('utf-8')
    assert parsed(result) == expected, 'Unexpected TOML changes'
    return result


def winpath(path, lb):
    return 'D:\\LaunchBox\\' + str(path.relative_to(lb)).replace('/', '\\')


def merge_presets(presets, selected):
    result = copy.deepcopy(presets)
    overrides = {row['TitleId']: row for row in result['Overrides']}
    for tid, opts in selected.items():
        owned = {key: literal(value) for key, value in opts.items() if key in MANAGED_KEYS}
        if owned:
            row = overrides.setdefault(tid, {'TitleId': tid, 'Options': {}})
            row['Options'].update(owned)
    result['Overrides'] = [overrides[tid] for tid in sorted(overrides)]
    return result


def prepare(args):
    lb = args.launchbox
    emulator = lb / 'Emulators/Xenia Canary'
    root = args.plan
    root.mkdir(parents=True, exist_ok=True)
    base = (emulator / 'xenia-canary.config.toml').read_bytes()
    schema_path = getattr(args, 'schema', None)
    schema = parsed(schema_path.read_bytes()) if schema_path else parsed(base)
    library = json.loads(args.library.read_text())
    templates = {p.stem: parsed(p.read_bytes()) for p in args.settings.glob('*.toml')}
    db = json.loads(args.database.read_text())
    aliases = {}
    for row in db:
        ids = [row['id']] + row.get('alternative_id', [])
        matches = set(ids).intersection(templates)
        if len(matches) == 1:
            for tid in ids:
                if tid not in templates:
                    aliases[tid] = next(iter(matches))
    xmls = {system: (lb / 'Data/Platforms' / (system + '.xml')).read_bytes()
            for system in ('Microsoft Xbox 360', 'Microsoft Xbox Live Arcade')}
    roots = {system: ET.fromstring(data) for system, data in xmls.items()}
    games = {g.findtext('ID'): g for root_xml in roots.values() for g in root_xml.findall('Game')}
    assert len(games) == sum(not g['app'] for g in library)
    originals, outputs, selected, skipped, xml_commands = {}, {}, {}, [], {}
    matched, backends = [], []

    def remember(path):
        rel = str(path.relative_to(lb))
        if rel not in originals:
            originals[rel] = path.read_bytes() if path.exists() else None
        return originals[rel]

    def output(path, data):
        old = remember(path)
        if old != data:
            outputs[str(path.relative_to(lb))] = data

    for item in library:
        if item['app']:
            continue
        game = games[item['id']]
        assert str(lb / game.findtext('ApplicationPath').replace('\\', '/')) == item['path']
        assert (game.findtext('CommandLine') or '') == item['command']
        assert game.findtext('Emulator') == item['emulator']
        tid = item['title_id']
        source_tid = tid if tid in templates else aliases.get(tid)
        if source_tid not in templates or item['emulator'] != CANARY:
            continue
        options = copy.deepcopy(templates[source_tid])
        for key in list(options):
            if key not in schema:
                skipped.append((tid, key, options.pop(key), 'unsupported by installed build'))
        # AC3's two discs have different launch modules in their existing args.
        if 'General.launch_module' in options:
            skipped.append((tid, 'General.launch_module', options.pop('General.launch_module'), 'existing disc-specific launch route retained'))
        # Upstream explicitly limits this Minecraft workaround to TU2--TU11.
        # This cabinet currently has only the verified base package; do not
        # apply a conditional workaround without a matching installed update.
        if tid == '584111F7' and options.get('GPU.render_target_path_d3d12') == 'rov':
            skipped.append((tid, 'GPU.render_target_path_d3d12', options.pop('GPU.render_target_path_d3d12'), 'only for TU2--TU11; update version not verified'))
        selected[tid] = options
        matched.append({k: item[k] for k in ('id', 'title', 'system', 'title_id')})
        if 'GPU.gpu' in options:
            backends.append((item['title'], options['GPU.gpu']))
        command = item['command']
        existing = re.search(r'--config="([^"]+)"', command)
        if existing:
            assert existing[1].startswith('D:\\LaunchBox\\')
            path = lb / existing[1][len('D:\\LaunchBox\\'):].replace('\\', '/')
            before = remember(path)
            assert before is not None
        else:
            assert item['system'] == 'Microsoft Xbox Live Arcade'
            stem = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', item['title']).strip(' .')[:100]
            path = emulator / 'config/games' / (stem + ' [' + item['id'][:8] + '].toml')
            assert not path.exists(), 'Unlinked pre-existing config requires review'
            before = base
            xml_commands[item['id']] = '--config="' + winpath(path, lb) + '"' + (' ' + command if command else '')
        output(path, merge(before, options))
        # Existing patch companion configs load later; merge to prevent them
        # from undoing recommendations from the game's startup config.
        partial = emulator / 'config' / (tid + '.config.toml')
        data = remember(partial)
        if data is not None:
            output(partial, merge(data, options))

    for system, original in xmls.items():
        updated = original
        for game in roots[system].findall('Game'):
            gid = game.findtext('ID')
            if gid not in xml_commands:
                continue
            blocks = [m for m in re.finditer(rb'<Game>.*?</Game>', updated, re.S)
                      if ('<ID>' + gid + '</ID>').encode() in m[0]]
            assert len(blocks) == 1
            m = blocks[0]
            text = xml_commands[gid].replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            replacement = ('<CommandLine>' + text + '</CommandLine>').encode()
            block, count = re.subn(rb'<CommandLine(?:\s*/>|>.*?</CommandLine>)', lambda _: replacement, m[0], flags=re.S)
            assert count == 1
            updated = updated[:m.start()] + block + updated[m.end():]
        after = ET.fromstring(updated)
        assert len(after) == len(roots[system])
        for a, b in zip(roots[system], after):
            expected = copy.deepcopy(a)
            if a.tag == 'Game' and a.findtext('ID') in xml_commands:
                expected.find('CommandLine').text = xml_commands[a.findtext('ID')]
            assert ET.tostring(expected) == ET.tostring(b), 'Unexpected XML changes'
        path = lb / 'Data/Platforms' / (system + '.xml')
        output(path, updated)

    state_path = emulator / 'PatchManager/settings.json'
    state = json.loads(remember(state_path))
    for row in state['Managed']:
        for key, value in selected.get(row['TitleId'], {}).items():
            if key in MANAGED_KEYS and key in row['Original']:
                row['Original'][key] = literal(value)
    output(state_path, (json.dumps(state, indent=2) + '\n').encode())
    presets_path = emulator / 'PatchManager/optimized-settings.json'
    old_presets = remember(presets_path)
    presets = json.loads(old_presets) if old_presets is not None else {'Overrides': []}
    presets = merge_presets(presets, selected)
    output(presets_path, (json.dumps(presets, indent=2) + '\n').encode())
    module = emulator / 'PatchManager/PatchManager.Core.psm1'
    output(module, (Path(__file__).parent / 'PatchManager.Core.psm1').read_bytes())
    manifest = {'files': [], 'matched': matched, 'selected': selected, 'skipped': skipped, 'backends': backends}
    for rel, data in outputs.items():
        old = originals[rel]
        stage = root / 'after' / rel
        stage.parent.mkdir(parents=True, exist_ok=True)
        stage.write_bytes(data)
        if old is not None:
            snapshot = root / 'before' / rel
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            snapshot.write_bytes(old)
        manifest['files'].append({'path': rel, 'before': hashlib.sha256(old).hexdigest() if old is not None else None,
                                  'after': hashlib.sha256(data).hexdigest()})
    # Protect both XMLs even if only the XBLA XML is being changed.
    manifest['xml_hashes'] = {str((lb / 'Data/Platforms' / (s + '.xml')).relative_to(lb)): hashlib.sha256(raw).hexdigest() for s, raw in xmls.items()}
    (root / 'plan.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print('Matched:', len(matched), 'games;', len(selected), 'Title IDs; changes:', len(outputs), 'files; new XBLA config links:', len(xml_commands))
    print('Backend changes:', backends)
    print('Skipped:', skipped)


def install(args):
    lb, root = args.launchbox, args.plan
    plan = json.loads((root / 'plan.json').read_text())
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    for rel, expected in plan['xml_hashes'].items():
        assert digest(lb / rel) == expected, 'XML changed since preparation: ' + rel
    for row in plan['files']:
        assert digest(lb / row['path']) == row['before'], 'Concurrent change: ' + row['path']
        assert digest(root / 'after' / row['path']) == row['after']
    backup_prefix = getattr(args, 'backup_prefix', 'xenia-optimized-settings')
    assert re.fullmatch(r'[a-zA-Z0-9_-]+', backup_prefix), 'Invalid backup prefix'
    backup = lb / 'Backups' / (backup_prefix + '-' + datetime.now(ZoneInfo('Europe/Berlin')).strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True)
    for row in plan['files']:
        if row['before'] is not None:
            dest = backup / row['path']
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((lb / row['path']).read_bytes())
            assert digest(dest) == row['before']
    (backup / 'restore.json').write_text(json.dumps({'created': [r['path'] for r in plan['files'] if r['before'] is None]}, indent=2))
    changed = []
    def atomic(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + '.codex-new')
        assert not temp.exists()
        try:
            temp.write_bytes(data)
            os.replace(temp, path)
        finally:
            if temp.exists():
                temp.unlink()
    try:
        for row in plan['files']:
            path = lb / row['path']
            assert digest(path) == row['before'], 'Concurrent change: ' + row['path']
            atomic(path, (root / 'after' / row['path']).read_bytes())
            changed.append(row)
            assert digest(path) == row['after']
        for row in plan['files']:
            path = lb / row['path']
            if path.suffix == '.toml':
                parsed(path.read_bytes())
            elif path.suffix == '.xml':
                ET.parse(path)
            elif path.suffix == '.json':
                json.loads(path.read_text())
        for rel, oldhash in plan['xml_hashes'].items():
            row = next((r for r in plan['files'] if r['path'] == rel), None)
            assert digest(lb / rel) == (row['after'] if row else oldhash)
    except BaseException:
        for row in reversed(changed):
            path = lb / row['path']
            if digest(path) != row['after']:
                print('Rollback preserved an external edit:', row['path'])
                continue
            if row['before'] is None:
                path.unlink()
            else:
                atomic(path, (backup / row['path']).read_bytes())
        raise
    print('Installed', len(plan['files']), 'verified files. Backup:', backup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launchbox', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--database', type=Path)
    parser.add_argument('--schema', type=Path, help='Verified schema for an emulator update staged with the plan')
    parser.add_argument('--backup-prefix', default='xenia-optimized-settings')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.apply:
        install(args)
    else:
        for name in ('library', 'settings', 'database'):
            if getattr(args, name) is None:
                parser.error('--' + name + ' is required when preparing')
        prepare(args)


if __name__ == '__main__':
    main()
