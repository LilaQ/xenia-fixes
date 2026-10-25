"""Validate the patch against an owner's unmodified XEX and decompressed virtual PE.

Usage: python verify.py Mafia2_ReleaseDLL.xex Mafia2_ReleaseDLL.xex.pe
Requires Python 3.11+ and xxhash. Game data is neither included nor written.
"""
from pathlib import Path
import math
import struct
import sys
import tomllib

import xxhash


def u32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def loaded_code_hash(xex, image):
    """Reproduce Xenia's code-page hash after kernel import thunk resolution."""
    mem = bytearray(image)
    security = u32(xex, 16)
    base = u32(xex, security + 0x110)
    count = u32(xex, security + 0x180)
    pages = [i for i in range(count)
             if u32(xex, security + 0x184 + 24 * i) & 15 == 1]
    start, end = min(pages) * 65536, (max(pages) + 1) * 65536
    assert end <= len(mem)
    headers = dict(struct.unpack_from(">II", xex, 24 + i * 8)
                   for i in range(u32(xex, 20)))
    imports = headers[0x103FF]
    size, strings_size, strings_count = struct.unpack_from(">III", xex, imports)
    names, pos = [], imports + 12
    for _ in range(strings_count):
        stop = xex.index(b"\0", pos)
        names.append(xex[pos:stop].decode())
        pos = imports + 12 + ((stop - (imports + 12) + 4) & ~3)
    pos = imports + 12 + strings_size
    while pos < imports + size:
        library_size = u32(xex, pos)
        assert library_size >= 0x28 and pos + library_size <= imports + size
        name_index, count = struct.unpack_from(">HH", xex, pos + 0x24)
        assert names[name_index & 255].lower() in ("xam.xex", "xboxkrnl.exe")
        for i in range(count):
            offset = u32(xex, pos + 0x28 + i * 4) - base
            kind = u32(mem, offset) >> 24
            if kind == 1:
                mem[offset:offset + 16] = struct.pack(
                    ">IIII", 0x44000042, 0x4E800020, 0x60000000, 0x60000000)
            else:
                assert kind == 0 and not start <= offset < end
        pos += library_size
    assert pos == imports + size
    return base, f"{xxhash.xxh3_64_intdigest(mem[start:end]):016X}"


def verify(xex_path, image_path):
    xex, image = xex_path.read_bytes(), image_path.read_bytes()
    patch = tomllib.loads(next(Path(__file__).parent.glob("*.patch.toml")).read_text())
    base, digest = loaded_code_hash(xex, image)
    assert base == 0x88000000 and digest == patch["hash"] == "D0F70B7B6332890A"
    assert patch["title_id"] == "545407E6"
    original = {0x88190E48: 0x3CE08802, 0x88190E4C: 0xC3E78ACC}
    expected = {0x88190E48: 0x3CE08800, 0x88190E4C: 0xC3E77740}
    blocks = patch["patch"]
    assert len(blocks) == 1 and blocks[0]["is_enabled"]
    writes = blocks[0]["be32"]
    assert len(writes) == 2
    assert {w["address"]: w["value"] for w in writes} == expected
    after = bytearray(image)
    for write in writes:
        offset = write["address"] - base
        assert u32(image, offset) == original[write["address"]]
        struct.pack_into(">I", after, offset, write["value"])
    # Decode the instruction pair and check the actual float it now loads.
    lis, lfs = (u32(after, address - base) for address in expected)
    displacement = struct.unpack(">h", struct.pack(">H", lfs & 0xFFFF))[0]
    target = ((lis & 0xFFFF) << 16) + displacement
    assert target == 0x88007740
    assert math.isclose(struct.unpack_from(">f", after, target - base)[0], 1 / 60,
                        rel_tol=1e-7)
    assert math.isclose(struct.unpack_from(">f", after, 0x88018ACC - base)[0], 1 / 30,
                        rel_tol=1e-7)
    offset = 0x88190E48 - base
    assert after[:offset] == image[:offset] and after[offset + 8:] == image[offset + 8:]
    print(f"Verified module {digest}, original instructions, 1/60 wait target; "
          "all bytes outside the two instructions unchanged.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
