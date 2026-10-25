"""Install the exact tested output with backup and unchanged cabinet data checks."""
import argparse
from datetime import datetime
import hashlib
from pathlib import Path
import os
import shutil
import uuid

from build_fix import EDGE_SHA256

LEGACY_SHA256 = '63c91475b7764c52e4b9577c8231a599af86d4a59e34453b9f47ef74bc579c30'
PREVIOUS_SHA256 = 'd6e0b1326382cc73dc5da4e0f056027e7af4ae75c8d6ead1c7abcc43666e5e36'
PATCHED_SHA256 = '7d967e69f466fd2b23d30fe0b2a8f95866e0165dd8962a5bdb2e3c8fb2d1ec3e'

RENDER_PASS_SHA256 = '9aefd41a85d8a48e0f4798a27ad23b362e376fccc118b8adad33f794b46505cd'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def install(launchbox, patched):
    edge = launchbox / 'Emulators/Xenia Edge'
    target = edge / 'xenia_edge_hitman.exe'
    expected_original = digest(target)
    desired = digest(patched)
    if desired not in (PATCHED_SHA256, RENDER_PASS_SHA256):
        raise ValueError('Output is not one of the execution-tested builds')
    if expected_original == desired:
        print('Verified Hitman build is already installed:', target)
        return
    if expected_original not in (EDGE_SHA256, LEGACY_SHA256, PREVIOUS_SHA256, PATCHED_SHA256, RENDER_PASS_SHA256):
        raise ValueError('Executable hashes do not match the verified inputs')
    # This supplements the operator's closure confirmation. An unclean exit
    # needs explicit inspection instead of silently replacing a running file.
    with (edge / 'xenia.log').open('rb') as stream:
        stream.seek(max(0, (edge / 'xenia.log').stat().st_size - 4096))
        if b'Cheap-skate exit!' not in stream.read():
            raise ValueError('Edge shutdown not confirmed in its latest log')
    configs = list((edge / 'config/games').glob('Hitman*Absolution*.toml'))
    if not configs:
        raise ValueError('No Hitman game config found for protection checks')
    protected = configs + [
        edge / 'xenia_edge.exe',
        edge / 'patches/53510804 - Hitman Absolution USA Rev1 60FPS.patch.toml',
        launchbox / 'Data/Platforms/Microsoft Xbox 360.xml',
        launchbox / 'Data/Emulators.xml',
    ]
    for emulator in ('Xenia Canary', 'Xenia Edge'):
        content = launchbox / 'Emulators' / emulator / 'content'
        for title in content.glob('*/53510804'):
            protected.extend(path for path in title.rglob('*') if path.is_file())
    unchanged = {path: digest(path) for path in protected}
    backup = launchbox / 'Backups' / ('hitman-water-shader-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir()
    original = backup / target.name
    shutil.copy2(target, original)
    if digest(original) != expected_original:
        raise ValueError('Backup byte verification failed')
    temporary = target.with_name('xenia_edge_hitman.' + uuid.uuid4().hex + '.tmp')
    try:
        shutil.copyfile(patched, temporary)
        if digest(temporary) != desired:
            raise ValueError('Temporary output verification failed')
        if digest(target) != expected_original:
            raise ValueError('Original executable changed during preparation')
        os.replace(temporary, target)
        if digest(target) != desired:
            raise ValueError('Installed output verification failed')
        for path, expected in unchanged.items():
            if digest(path) != expected:
                raise ValueError('An independently modified cabinet file needs review: ' + str(path))
    except BaseException:
        # Restore only our executable. Never overwrite a config or save that
        # might have changed independently while the installation was running.
        if digest(target) == desired:
            shutil.copyfile(original, temporary)
            os.replace(temporary, target)
        raise
    finally:
        if temporary.exists(): temporary.unlink()
    print('Installed:', target)
    print('Backup:', original)
    print('Stock Edge, configs, 60-FPS patch, LaunchBox XML and Hitman saves unchanged.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launchbox', type=Path, required=True)
    parser.add_argument('--patched', type=Path, required=True)
    args = parser.parse_args()
    install(args.launchbox, args.patched)


if __name__ == '__main__':
    main()
