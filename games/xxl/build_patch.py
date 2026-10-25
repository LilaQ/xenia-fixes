"""Build a hash-scoped XXL RuntimeHost optimization for Xenia Edge.

The replacement copies exactly the requested bytes, using scalar 64-bit
accesses instead of the Xenon routine's alignment and cache-prefetch paths.
Xenia implements these accesses without the Xenon's alignment restriction.
This is an emulator patch, not a patch suitable for original hardware.
"""
import struct
from pathlib import Path

BASE = 0x823570D0
RUNTIME_HASH = "0F8C087D6FEA1BD4"
FLUSH_ENTRY = 0x82395080
FLUSH_CODE = 0x823571C0
FLUSH_CACHE = 0x823572D0
KERNEL_NAME = 0x823572E0
GET_MODULE = 0x829D1E5C
GET_PROC = 0x829D1D6C


def flush_code():
    """Call Edge's existing KeSweepIcacheRange, preserving the caller ABI.

    The replacement memcpy no longer enters its original alignment paths.
    Use part of that unreachable code for this routine and its cached export.
    The kernel trampoline is resolved through imports already in RuntimeHost.
    Failed resolution leaves the original synchronization behavior intact.
    """
    words, labels, fixups = [], {}, []

    def emit(word):
        words.append(word)

    def label(name):
        labels[name] = len(words) * 4

    def conditional(bo, bi, target):
        fixups.append((len(words), bo, bi, target))
        emit(0)

    def address(reg, value):
        emit(0x3C000000 | reg << 21 | (value >> 16))  # lis
        emit(0x60000000 | reg << 21 | reg << 16 | (value & 0xFFFF))
        emit(0x5400003E | reg << 21 | reg << 16)  # zero-extend address

    def call(target):
        displacement = target - (FLUSH_CODE + len(words) * 4)
        assert -0x2000000 <= displacement < 0x2000000
        emit(0x48000001 | (displacement & 0x3FFFFFC))

    emit(0x28040000)  # cmplwi r4,0
    emit(0x4D820020)  # beqlr
    emit(0x7C0802A6)  # mflr r0
    emit(0xF801FFF8)  # std r0,-8(r1)
    emit(0x9421FF80)  # stwu r1,-128(r1)
    emit(0xF8610050)  # std r3,80(r1)
    emit(0xF8810058)  # std r4,88(r1)
    address(11, FLUSH_CACHE)
    emit(0x818B0000)  # lwz r12,0(r11)
    emit(0x280C0000)  # cmplwi r12,0
    conditional(4, 2, "invoke")  # bne
    address(3, KERNEL_NAME)
    emit(0x38810060)  # addi r4,r1,96; module handle output
    call(GET_MODULE)
    emit(0x28030000)
    conditional(4, 2, "finish")
    emit(0x80610060)  # lwz r3,96(r1)
    emit(0x388000AB)  # KeSweepIcacheRange ordinal
    emit(0x38A10064)  # addi r5,r1,100; function pointer output
    emit(0x38000000)  # clear output in case lookup fails without writing it
    emit(0x90010064)
    call(GET_PROC)
    emit(0x28030000)
    conditional(4, 2, "finish")
    emit(0x81810064)  # lwz r12,100(r1)
    emit(0x280C0000)
    conditional(12, 2, "finish")
    address(11, FLUSH_CACHE)
    emit(0x918B0000)  # stw r12,0(r11)
    label("invoke")
    emit(0xE8610050)  # ld r3,80(r1)
    emit(0xE8810058)  # ld r4,88(r1)
    emit(0x7D8903A6)  # mtctr r12
    emit(0x4E800421)  # bctrl
    label("finish")
    emit(0x7C0004AC)  # sync
    emit(0x4C00012C)  # isync
    emit(0xE8010078)  # ld r0,120(r1)
    emit(0x38210080)  # restore stack
    emit(0x7C0803A6)  # mtlr r0
    emit(0x4E800020)
    for index, bo, bi, target in fixups:
        displacement = labels[target] - index * 4
        words[index] = 0x40000000 | bo << 21 | bi << 16 | (displacement & 0xFFFC)
    code = b"".join(struct.pack(">I", word) for word in words)
    assert FLUSH_CODE + len(code) <= FLUSH_CACHE
    return code


def copy_code():
    words, labels, fixups = [], {}, []

    def emit(word):
        words.append(word)

    def label(name):
        labels[name] = len(words) * 4

    def branch(bo, bi, target):
        fixups.append((len(words), bo, bi, target))
        emit(0)

    def compare(size):
        emit(0x28050000 | size)  # cmplwi cr0,r5,size

    def advance(reg, amount):
        emit(0x38000000 | reg << 21 | reg << 16 | (amount & 0xFFFF))

    def copy64(offset):
        emit(0xE8000000 | 7 << 21 | 4 << 16 | offset)  # ld r7,offset(r4)
        emit(0xF8000000 | 7 << 21 | 6 << 16 | offset)  # std r7,offset(r6)

    emit(0x7C661B78)  # mr r6,r3; preserve the memcpy return value in r3
    compare(128)
    branch(12, 0, "small")  # blt
    label("bulk")
    for offset in range(0, 128, 8):
        copy64(offset)
    advance(4, 128)
    advance(6, 128)
    advance(5, -128)
    compare(128)
    branch(4, 0, "bulk")  # bge
    label("small")
    compare(8)
    branch(12, 0, "tail")
    label("eight")
    copy64(0)
    advance(4, 8)
    advance(6, 8)
    advance(5, -8)
    compare(8)
    branch(4, 0, "eight")
    label("tail")
    compare(0)
    emit(0x4D820020)  # beqlr
    emit(0x7CA903A6)  # mtctr r5
    label("byte")
    emit(0x88E40000)  # lbz r7,0(r4)
    emit(0x98E60000)  # stb r7,0(r6)
    advance(4, 1)
    advance(6, 1)
    branch(16, 0, "byte")  # bdnz
    emit(0x4E800020)  # blr

    for index, bo, bi, target in fixups:
        displacement = labels[target] - index * 4
        assert -0x8000 <= displacement < 0x8000 and displacement % 4 == 0
        words[index] = 0x40000000 | bo << 21 | bi << 16 | (displacement & 0xFFFC)
    return b"".join(struct.pack(">I", word) for word in words)


def render():
    data = copy_code()
    lines = [
        'title_name = "Serious Sam - Double D XXL"',
        'title_id = "58411249"',
        f'hash = "{RUNTIME_HASH}"',
        "",
        "[[patch]]",
        'name = "RuntimeHost copy and JIT cache repair"',
        'desc = "Xenia-only scalar memcpy and KeSweepIcacheRange replacement. Requires writable_code_segments = true. Experimental, not a verified performance fix or 60 FPS guarantee."',
        'author = "LilaQ"',
        "is_enabled = true",
    ]
    for offset in range(0, len(data), 4):
        word = struct.unpack_from(">I", data, offset)[0]
        lines.extend(["[[patch.be32]]", f"address = 0x{BASE + offset:08X}", f"value = 0x{word:08X}"])
    lines.extend([
        "[[patch.be32]]",
        f"address = 0x{FLUSH_ENTRY:08X}",
        f"value = 0x{0x48000000 | ((FLUSH_CODE - FLUSH_ENTRY) & 0x3FFFFFC):08X}",
    ])
    payloads = [(FLUSH_CODE, flush_code()), (FLUSH_CACHE, bytes(4)),
                (KERNEL_NAME, b"xboxkrnl.exe\0".ljust(16, b"\0"))]
    for start, payload in payloads:
        for offset in range(0, len(payload), 4):
            word = struct.unpack_from(">I", payload, offset)[0]
            lines.extend(["[[patch.be32]]", f"address = 0x{start + offset:08X}",
                          f"value = 0x{word:08X}"])
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    output = Path(__file__).with_name("58411249 - XXL RuntimeHost.patch.toml")
    output.write_text(render(), encoding="utf-8")
    print(f"Built {output.name}: {len(copy_code())} copy-function bytes")
