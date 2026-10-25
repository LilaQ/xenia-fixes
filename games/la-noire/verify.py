"""Validate the patch against an owner's unmodified XEX and decompressed virtual PE.

Usage: python verify.py original.xex decompressed-virtual-image.pe
Requires Python 3.11+ and xxhash. Game data is neither included nor written.
"""
from pathlib import Path
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
    assert base == 0x82000000 and digest == patch["hash"] == "60E4E421F4445C2B"
    assert patch["title_id"] == "5454086C"
    original = {0x827748C8: 0x38A00002, 0x828A4898: 0x38800002,
                0x828A489C: 0x93FE0004}
    expected = {0x827748C8: 0x38A00001, 0x828A4898: 0x38800001,
                0x828A489C: 0x909E0004}
    blocks = patch["patch"]
    assert len(blocks) == 1 and blocks[0]["is_enabled"]
    writes = blocks[0]["be32"]
    assert len(writes) == 3 and {w["address"]: w["value"] for w in writes} == expected
    after = bytearray(image)
    for write in writes:
        offset = write["address"] - base
        assert u32(image, offset) == original[write["address"]]
        struct.pack_into(">I", after, offset, write["value"])
    # Check that both stores target divisor +4; preserve separate +0xC4 field.
    assert u32(image, 0x827748D8 - base) == 0x90AB0000  # stw r5,0(r11)
    assert u32(image, 0x828A4894 - base) == 0x3BE00002  # li r31,2
    assert u32(image, 0x828A48B4 - base) == 0x93FE00C4  # stw r31,0xC4(r30)
    # Getter reads display refresh and divisor, then multiplies (1/Hz)*divisor.
    assert u32(image, 0x827709F4 - base) == 0xC1AA00E8
    assert u32(image, 0x827709FC - base) == 0xEC006824
    assert u32(image, 0x82770A00 - base) == 0x81430004
    assert u32(image, 0x82770A14 - base) == 0xEC2B0032
    allowed = {a - base + i for a in expected for i in range(4)}
    changed = {i for i, (a, b) in enumerate(zip(image, after)) if a != b}
    assert changed and changed <= allowed
    print(f"Verified {digest}: constructor/gameplay divisor 2->1, "
          "matching timestep getter, unrelated timer fields unchanged.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python verify.py original.xex decompressed-virtual-image.pe")
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
