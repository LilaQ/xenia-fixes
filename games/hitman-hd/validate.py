"""Validate module-scoped patches without modifying supplied game files."""

import argparse
from pathlib import Path
import struct
import tomllib

import xxhash


GAMES = {
    "SilentAssassin": ("5351081C - Hitman 2 Silent Assassin HD 60FPS.patch.toml", 0x821C3518, 0x39600002),
    "Contracts": ("5351081C - Hitman Contracts HD 60FPS.patch.toml", 0x82658AA0, 0x39200002),
    "BloodMoney": ("534307DB - Hitman Blood Money HD 60FPS.patch.toml", 0x822011E4, 0x38A00002),
}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def u32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def loaded_module_hash(xex, memory):
    """Match Xenia's code-page hash after function import resolution."""
    check(xex[:4] == b"XEX2", "Expected an XEX2 executable")
    security = u32(xex, 16)
    base = u32(xex, security + 0x110)
    count = u32(xex, security + 0x180)
    code = [i for i in range(count) if u32(xex, security + 0x184 + 24 * i) & 15 == 1]
    check(bool(code), "No code pages")
    start, end = min(code) * 65536, (max(code) + 1) * 65536
    check(end <= len(memory), "Supply a decompressed virtual memory image")
    headers = dict(struct.unpack_from(">II", xex, 24 + i * 8) for i in range(u32(xex, 20)))
    imports = headers[0x103FF]
    size, strings_size, strings_count = struct.unpack_from(">III", xex, imports)
    names, position = [], imports + 12
    for _ in range(strings_count):
        stop = xex.index(b"\0", position)
        names.append(xex[position:stop].decode())
        position = imports + 12 + ((stop - (imports + 12) + 4) & ~3)
    position = imports + 12 + strings_size
    loaded = bytearray(memory)
    while position < imports + size:
        library_size = u32(xex, position)
        check(library_size > 0 and position + library_size <= imports + size, "Invalid import library size")
        name_index, import_count = struct.unpack_from(">HH", xex, position + 0x24)
        check(names[name_index & 255].lower() in ("xam.xex", "xboxkrnl.exe"), "Unsupported import library")
        for i in range(import_count):
            offset = u32(xex, position + 0x28 + i * 4) - base
            kind = u32(loaded, offset) >> 24
            if kind == 1:
                loaded[offset:offset + 16] = struct.pack(">IIII", 0x44000042, 0x4E800020, 0x60000000, 0x60000000)
            else:
                check(kind == 0 and not start <= offset < end, "Variable import inside hashed code requires resolution")
        position += library_size
    return base, f"{xxhash.xxh3_64_intdigest(loaded[start:end]):016X}"


def validate(game, xex_path, memory_path):
    filename, address, original = GAMES[game]
    patch = tomllib.loads((Path(__file__).parent / "patches" / filename).read_text())
    memory = memory_path.read_bytes()
    base, actual_hash = loaded_module_hash(xex_path.read_bytes(), memory)
    check(actual_hash == patch["hash"], f"Module hash mismatch: {actual_hash}")
    check(u32(memory, address - base) == original, "Original instruction differs")
    check(len(patch["patch"]) == 1 and patch["patch"][0]["is_enabled"], "Expected one enabled patch")
    check(patch["patch"][0]["be32"] == [{"address": address, "value": original - 1}], "Unexpected patch write")
    print(f"{game}: hash {actual_hash}, original opcode and interval 2 -> 1 verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", choices=GAMES)
    parser.add_argument("xex", type=Path)
    parser.add_argument("memory", type=Path)
    args = parser.parse_args()
    validate(args.game, args.xex, args.memory)
