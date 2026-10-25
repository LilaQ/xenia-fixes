import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('optimized', Path(__file__).with_name('apply-optimized-settings.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OptimizedSettingsTests(unittest.TestCase):
    def test_partial_import_retains_other_games_and_existing_preferences(self):
        before = {'FormatVersion': 1, 'Overrides': [
            {'TitleId': '11111111', 'Options': {'GPU.framerate_limit': '60', 'GPU.vsync': 'true'}},
            {'TitleId': '22222222', 'Options': {'GPU.framerate_limit': '50'}}
        ]}
        snapshot = json.loads(json.dumps(before))
        after = module.merge_presets(before, {
            '11111111': {'GPU.framerate_limit': 120},
            '33333333': {'Memory.protect_zero': False}
        })
        self.assertEqual(before, snapshot)
        self.assertEqual(after['FormatVersion'], 1)
        rows = {r['TitleId']: r['Options'] for r in after['Overrides']}
        self.assertEqual(rows['11111111'], {'GPU.framerate_limit': '120', 'GPU.vsync': 'true'})
        self.assertEqual(rows['22222222'], {'GPU.framerate_limit': '50'})
        self.assertNotIn('33333333', rows)

    def test_nested_sections_preserve_controls_and_comments(self):
        before = b'[GPU]\nframerate_limit = 60 # patch cap\ngpu = "d3d12"\n[GPU.Debug]\ngamma_render_target_as_unorm16 = true\n[HID]\nhid = "xinput" # cabinet input\n'
        after = module.merge(before, {'GPU.framerate_limit': 120, 'GPU.readback_resolve': 'full', 'GPU.Debug.gamma_render_target_as_unorm16': False})
        self.assertEqual(module.parsed(after), {'GPU.framerate_limit': 120, 'GPU.gpu': 'd3d12', 'GPU.readback_resolve': 'full', 'GPU.Debug.gamma_render_target_as_unorm16': False, 'HID.hid': 'xinput'})
        self.assertIn(b'# patch cap', after)
        self.assertIn(b'hid = "xinput" # cabinet input', after)

    def make_install_fixture(self, directory):
        lb = Path(directory) / 'lb'
        plan_dir = Path(directory) / 'plan'
        files = []
        for name, before, after in [('a.toml', b'[GPU]\nvsync = true\n', b'[GPU]\nvsync = false\n'), ('b.toml', None, b'[GPU]\nframerate_limit = 120\n')]:
            (plan_dir / 'after').mkdir(parents=True, exist_ok=True)
            lb.mkdir(exist_ok=True)
            if before is not None:
                (lb / name).write_bytes(before)
            (plan_dir / 'after' / name).write_bytes(after)
            files.append({'path': name, 'before': hashlib.sha256(before).hexdigest() if before else None, 'after': hashlib.sha256(after).hexdigest()})
        (plan_dir / 'plan.json').write_text(json.dumps({'files': files, 'xml_hashes': {}}))
        return SimpleNamespace(launchbox=lb, plan=plan_dir)

    def test_concurrent_edit_prevents_all_mutations(self):
        with tempfile.TemporaryDirectory(prefix='.test-', dir=Path(__file__).parent) as directory:
            args = self.make_install_fixture(directory)
            (args.launchbox / 'a.toml').write_bytes(b'[GPU]\nvsync = false # owner edit\n')
            with self.assertRaisesRegex(AssertionError, 'Concurrent change'):
                module.install(args)
            self.assertFalse((args.launchbox / 'Backups').exists())
            self.assertFalse((args.launchbox / 'b.toml').exists())

    def test_write_failure_rolls_back_and_keeps_verified_backup(self):
        with tempfile.TemporaryDirectory(prefix='.test-', dir=Path(__file__).parent) as directory:
            args = self.make_install_fixture(directory)
            original = (args.launchbox / 'a.toml').read_bytes()
            replace = module.os.replace
            def fail_second(source, destination):
                if Path(destination).name == 'b.toml':
                    raise OSError('simulated remote write failure')
                return replace(source, destination)
            with patch.object(module.os, 'replace', side_effect=fail_second):
                with self.assertRaisesRegex(OSError, 'simulated remote write failure'):
                    module.install(args)
            self.assertEqual((args.launchbox / 'a.toml').read_bytes(), original)
            self.assertFalse((args.launchbox / 'b.toml').exists())
            self.assertEqual(next((args.launchbox / 'Backups').glob('*/a.toml')).read_bytes(), original)
            self.assertFalse(list(args.launchbox.glob('*.codex-new')))

    def test_rollback_preserves_owner_edit_during_install(self):
        with tempfile.TemporaryDirectory(prefix='.test-', dir=Path(__file__).parent) as directory:
            args = self.make_install_fixture(directory)
            replace = module.os.replace
            owner_edit = b'[GPU]\nvsync = true # changed during install\n'
            def edit_then_fail(source, destination):
                if Path(destination).name == 'b.toml':
                    (args.launchbox / 'a.toml').write_bytes(owner_edit)
                    raise OSError('remote write failed after owner edit')
                return replace(source, destination)
            with patch.object(module.os, 'replace', side_effect=edit_then_fail):
                with self.assertRaisesRegex(OSError, 'remote write failed'):
                    module.install(args)
            self.assertEqual((args.launchbox / 'a.toml').read_bytes(), owner_edit)
            self.assertFalse((args.launchbox / 'b.toml').exists())


if __name__ == '__main__':
    unittest.main()
