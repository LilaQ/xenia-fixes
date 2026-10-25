#!/usr/bin/env python3
"""Relink an existing Edge Windows build with the isolated content-open fix.

Requires a completed, internally consistent Ninja build; does not rebuild or
modify its sources, objects, libraries, or original executable. No game assets.
"""
import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile


def command(build, target):
    result = subprocess.run(
        ['ninja', '-t', 'commands', target], cwd=build,
        check=True, capture_output=True, text=True)
    return shlex.split(result.stdout.strip().splitlines()[-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    source, build, output = (p.resolve() for p in
                             (args.source, args.build, args.output))
    original = source / 'src/xenia/kernel/xam/xam_content.cc'
    patch = Path(__file__).resolve().parents[1] / 'patches/edge-phantom-pain-content-reopen.patch'
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        parser.error('Output already exists; select a new filename.')
    with tempfile.TemporaryDirectory(prefix='phantom-build-', dir=output.parent) as tmp:
        temp = Path(tmp)
        modified = temp / 'xam_content.cc'
        subprocess.run(['patch', '-o', str(modified), str(original), str(patch)], check=True)
        compile_args = command(build, 'src/xenia/kernel/CMakeFiles/xenia-kernel.dir/xam/xam_content.cc.obj')
        obj = temp / 'xam_content.cc.obj'
        for flag, value in [('-o', obj), ('-MF', temp / 'content.d'), ('-c', modified)]:
            compile_args[compile_args.index(flag) + 1] = str(value)
        subprocess.run(compile_args, cwd=build, check=True)
        link_args = command(build, 'bin/Windows/xenia_edge.exe')
        if link_args[:2] != [':', '&&'] or link_args[-2:] != ['&&', ':']:
            raise RuntimeError('Unexpected Ninja linker command wrapper.')
        link_args = link_args[2:-2]
        link_args[link_args.index('-o') + 1] = str(output)
        # Resolve this translation unit before the unmodified static archive.
        link_args.insert(link_args.index('obj/Windows/libxenia-kernel.a'), str(obj))
        subprocess.run(link_args, cwd=build, check=True)
    print(output)


if __name__ == '__main__':
    main()
