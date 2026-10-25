"""Validate the consolidated source collection without game files or network access."""
from pathlib import Path
import ast
import json
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def validate():
    catalog = json.loads((ROOT / 'catalog.json').read_text())
    indexed = set()
    for record in catalog:
        path = ROOT / record['file']
        data = tomllib.loads(path.read_text())
        assert re.fullmatch(r'[0-9A-Fa-f]{8}', data['title_id']), path
        assert re.fullmatch(r'[0-9A-Fa-f]{16}', data['hash']), path
        assert data['title_name'] == record['game'], path
        assert data['title_id'] == record['title_id'], path
        assert data['hash'] == record['module_hash'], path
        assert data.get('patch'), path
        assert [{'name': p['name'], 'enabled': p.get('is_enabled', False)}
                for p in data['patch']] == record['options'], path
        indexed.add(record['file'])
    assert indexed == {p.relative_to(ROOT).as_posix()
                       for p in (ROOT / 'patches').glob('*.patch.toml')}
    sources = json.loads((ROOT / 'patch-sources.json').read_text())
    for entry in sources:
        assert (ROOT / entry['path']).read_bytes() == (ROOT / entry['source']).read_bytes(), entry
    assert indexed == {e['path'] for e in sources}
    provenance = json.loads((ROOT / 'provenance.json').read_text())
    assert len(provenance) == 18
    assert len({p['repository'] for p in provenance}) == 18
    for entry in provenance:
        assert (ROOT / entry['directory']).is_dir(), entry
        assert re.fullmatch(r'[0-9a-f]{40}', entry['commit']), entry
    forbidden = {'.exe', '.dll', '.pdb', '.iso', '.xex', '.xexp', '.pe', '.stfs',
                 '.rdc', '.xtr', '.etl', '.log', '.dmp', '.bin'}
    for path in ROOT.rglob('*'):
        if not path.is_file() or '.git' in path.parts or '__pycache__' in path.parts:
            continue
        assert path.suffix.lower() not in forbidden, path
        assert '.github/workflows' not in path.as_posix(), path
        if path.suffix == '.py':
            ast.parse(path.read_text(), filename=str(path))
    readme = (ROOT / 'README.md').read_text()
    for target in re.findall(r'\]\((?:<([^>]+)>|([^\s)]+))\)', readme):
        link = next(t for t in target if t)
        if '://' not in link:
            assert (ROOT / link.split('#')[0]).exists(), link
    print(f'PASS: {len(catalog)} indexed patch files, {len(provenance)} source projects; '
          'all source copies, version guards, Python syntax and main links checked.')


if __name__ == '__main__':
    validate()
