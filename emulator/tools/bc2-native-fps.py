#!/usr/bin/env python3
"""Build a bounded BC2 PAL config.zz replacement; input/output archives stay local.

Supply the original 51263-byte archive from ISO offset 4719882240.
Only the Xenon VSync/MaxFps settings change. Runtime FPS requires verification.
This tool writes an output archive, never the ISO itself.
"""
import argparse
import copy
import io
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("original", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
raw = args.original.read_bytes()
source = zipfile.ZipFile(io.BytesIO(raw))
assert source.testzip() is None
buffer = io.BytesIO()
with zipfile.ZipFile(buffer, "w") as target:
    for entry in source.infolist():
        data = source.read(entry.filename)
        if entry.filename == "Game.cfg":
            text = data.decode()
            start = text.index("elseif platform == 'Xenon' then")
            end = text.index("elseif platform == 'Win32' then", start)
            block = text[start:end]
            assert block.count("Game.VsyncEnable true") == 1
            block = block.replace("Game.VsyncEnable true", "Game.VsyncEnable false\r\n\tGame.MaxFps 60")
            data = (text[:start] + block + text[end:]).encode()
        target.writestr(copy.copy(entry), data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
payload = buffer.getvalue()
assert len(payload) <= len(raw)
payload += bytes(len(raw) - len(payload))
check = zipfile.ZipFile(io.BytesIO(payload))
assert check.testzip() is None
for name in source.namelist():
    if name != "Game.cfg":
        assert source.read(name) == check.read(name)
args.output.write_bytes(payload)
