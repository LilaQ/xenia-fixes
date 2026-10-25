from pathlib import Path
import importlib.util
import tomllib
import unittest

spec = importlib.util.spec_from_file_location('fps', Path(__file__).with_name('enable-fps-from-tests.py'))
fps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fps)

PATCH = b'''title_name = "Game"
title_id = "12345678"
hash = "0123456789ABCDEF"
# Header comment stays here.
[[patch]]
name = "60 FPS"
is_enabled = false
[[patch.be32]]
address = 0x82000000
value = 1
[[patch]]
name = "User graphics option"
is_enabled = true # User choice remains enabled.
[[patch.be32]]
address = 0x82000004
value = 7
'''


class PatchTests(unittest.TestCase):
    def test_enable_preserves_other_options_and_hash(self):
        updated = PATCH.replace(b'value = 1', b'value = 2')
        result, changed = fps.enable_blocks(PATCH, updated, {'60 FPS'})
        before, after = tomllib.loads(PATCH.decode()), tomllib.loads(result.decode())
        self.assertEqual(changed, ['60 FPS'])
        self.assertEqual(after['hash'], before['hash'])
        self.assertEqual(after['patch'][1], before['patch'][1])
        self.assertIn(b'# User choice remains enabled.', result)
        self.assertTrue(after['patch'][0]['is_enabled'])
        self.assertEqual(after['patch'][0]['be32'][0]['value'], 2)
        repeated, changed = fps.enable_blocks(result, updated, {'60 FPS'})
        self.assertEqual(repeated, result)
        self.assertEqual(changed, [])

    def test_wrong_version_is_rejected(self):
        with self.assertRaises(AssertionError):
            fps.enable_blocks(PATCH, PATCH.replace(b'0123456789ABCDEF', b'1111111111111111'), {'60 FPS'})

    def test_add_missing_fps_block_preserves_local_block(self):
        local = PATCH.split(b'[[patch]]')[0] + b'[[patch]]' + PATCH.split(b'[[patch]]')[2]
        result, changed = fps.enable_blocks(local, PATCH, {'60 FPS'})
        self.assertEqual(changed, ['60 FPS'])
        self.assertEqual(tomllib.loads(result.decode())['patch'][0], tomllib.loads(local.decode())['patch'][0])

    def test_select_60_instead_of_alternative_uncap(self):
        doc = {'title_id': '545408A7', 'patch': [{'name': '60 FPS'}, {'name': 'FPS Uncap'}, {'name': 'Show FPS'}]}
        self.assertEqual(fps.selections(doc), {'60 FPS'})

    def test_companion_and_above_60_only_exclusion(self):
        doc = {'title_id': '545107FC', 'patch': [{'name': '60 FPS'}, {'name': 'Havok physics FPS fix'}]}
        self.assertEqual(fps.selections(doc), {'60 FPS', 'Havok physics FPS fix'})
        doc = {'title_id': '454108F7', 'patch': [{'name': 'Unlock FPS'}]}
        self.assertEqual(fps.selections(doc), set())


if __name__ == '__main__':
    unittest.main()
