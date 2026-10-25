"""Execute the patch words against synthetic guest memory, without game data."""
from pathlib import Path
import tomllib
import unittest


PATCH = Path(__file__).resolve().parents[1] / (
    "534307E7 - Just Cause 2 TU0 Required Streaming.patch.toml"
)


class StreamingPatchTest(unittest.TestCase):
    def test_hook_preserves_wait_list_and_other_memory(self):
        document = tomllib.loads(PATCH.read_text())
        self.assertEqual(document["title_id"], "534307E7")
        self.assertEqual(document["hash"], "12134BD1769BFB2B")
        words = {p["address"]: p["value"] for p in document["patch"][0]["be32"]}
        self.assertEqual(len(words), 6)
        for flags in range(256):
            registers = [0x12340000 + i for i in range(32)]
            registers[1], registers[11] = 0x70001000, 0x41002000
            original_registers = registers.copy()
            memory = {0x41002000 + i: i for i in range(40)}
            memory[0x41002014] = flags
            original_memory = memory.copy()
            pc = 0x823265E0
            for _ in range(6):
                word = words[pc]
                opcode = word >> 26
                rt, ra = (word >> 21) & 31, (word >> 16) & 31
                immediate = word & 0xFFFF
                displacement = immediate - 0x10000 if immediate & 0x8000 else immediate
                address = registers[ra] + displacement
                if opcode == 34:  # lbz
                    registers[rt] = memory[address]
                elif opcode == 24:  # ori
                    registers[ra] = registers[rt] | immediate
                elif opcode == 38:  # stb
                    memory[address] = registers[rt] & 255
                elif opcode == 36:  # stw, big endian
                    for i, byte in enumerate(registers[rt].to_bytes(4, "big")):
                        memory[address + i] = byte
                elif opcode == 18:  # b; neither absolute nor link
                    self.assertEqual(word & 3, 0)
                    offset = word & 0x03FFFFFC
                    if offset & 0x02000000:
                        offset -= 0x04000000
                    pc += offset
                    continue
                else:
                    self.fail(f"Unexpected instruction {word:08X}")
                pc += 4
            self.assertEqual(pc, 0x823265E4)
            self.assertEqual(memory[0x41002014], flags | 0x80)
            self.assertEqual(bytes(memory[0x70001050 + i] for i in range(4)), b"\x41\x00\x20\x00")
            for address, byte in original_memory.items():
                if address != 0x41002014:
                    self.assertEqual(memory[address], byte)
            for i, value in enumerate(original_registers):
                if i != 9:
                    self.assertEqual(registers[i], value)


if __name__ == "__main__":
    unittest.main()
