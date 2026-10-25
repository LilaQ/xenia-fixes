"""Check immediate-mode instruction effects without distributing game data."""
from pathlib import Path
import tomllib
import unittest


class PresentationPatchTest(unittest.TestCase):
    def test_tu1_variants_are_exclusive_and_immediate_loads_are_correct(self):
        path = Path(__file__).resolve().parents[1] / (
            "534307E7 - Just Cause 2 TU1 60FPS.patch.toml"
        )
        patch = tomllib.loads(path.read_text())
        self.assertEqual(patch["title_id"], "534307E7")
        self.assertEqual(patch["hash"], "6CDA2880AB433BFF")
        self.assertEqual(sum(bool(p["is_enabled"]) for p in patch["patch"]), 1)
        immediate = patch["patch"][1]
        self.assertEqual(len(immediate["be32"]), 2)
        expected = {0x82BD9004: 30, 0x82BE52B0: 4}
        for entry in immediate["be32"]:
            word = entry["value"]
            self.assertEqual(word >> 26, 15)  # addis
            self.assertEqual((word >> 16) & 31, 0)  # lis alias, zero base
            self.assertEqual((word >> 21) & 31, expected[entry["address"]])
            immediate_value = word & 0xFFFF
            signed = immediate_value - 0x10000 if immediate_value & 0x8000 else immediate_value
            self.assertEqual((signed << 16) & 0xFFFFFFFF, 0x80000000)

    def test_engine_budget_is_sixty_hz_without_changing_clock_speed(self):
        path = Path(__file__).resolve().parents[1] / (
            "534307E7 - Just Cause 2 TU1 60FPS.patch.toml"
        )
        patch = tomllib.loads(path.read_text())
        active = next(p for p in patch["patch"] if p["is_enabled"])
        entries = {p["address"]: p["value"] for p in active["be32"]}
        self.assertEqual(len(entries), 3)
        word = entries[0x82214400]
        self.assertEqual(word >> 26, 24)  # ori, with r9 already zero
        self.assertEqual((word >> 21) & 31, 9)
        self.assertEqual((word >> 16) & 31, 8)
        budget_us = word & 0xFFFF
        # The game's existing integer timebase conversion is retained.
        frequency = 50_000_000
        budget_ticks = budget_us * frequency // 1_000_000
        self.assertAlmostEqual(frequency / budget_ticks, 60, delta=0.01)
        self.assertEqual(budget_us // 1000, 16)  # maximum integer-ms sleep
        # Device creation and its runtime update must retain immediate mode.
        self.assertEqual(entries[0x82BD9004], 0x3FC08000)
        self.assertEqual(entries[0x82BE52B0], 0x3C808000)


if __name__ == "__main__":
    unittest.main()
