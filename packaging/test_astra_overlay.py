import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('astra_overlay', Path(__file__).with_name('astra-overlay.py'))
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)


class OverlayTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bundle, self.package, self.base, self.backup = [root / n for n in ('bundle', 'package', 'base', 'backup')]
        for p in (self.bundle, self.package, self.base):
            p.mkdir()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        (self.base / 'gateway.json').write_text(json.dumps({'port': port}))
        files = []
        for index, (scope, target_root) in enumerate([('package', self.package), ('base', self.base)]):
            target = target_root / 'target'
            target.write_bytes(b'original' + bytes([index]))
            target.chmod(0o755 if index else 0o644)
            payload = self.bundle / str(index)
            payload.write_bytes(b'patched' + bytes([index]))
            files.append({'scope': scope, 'path': 'target', 'payload': str(index),
                          'original_sha256': overlay.digest(target), 'patched_sha256': overlay.digest(payload)})
        (self.bundle / 'manifest.json').write_text(json.dumps({'format': 1, 'files': files}))

    def run_overlay(self, action):
        overlay.run(action, self.bundle, self.package, self.base, self.backup)

    def targets(self):
        return [(p / 'target').read_bytes() for p in (self.package, self.base)]

    def test_round_trip_restores_exact_bytes_and_modes(self):
        before = self.targets()
        self.run_overlay('apply')
        self.assertEqual(self.targets(), [b'patched\x00', b'patched\x01'])
        self.assertEqual((self.base / 'target').stat().st_mode & 0o777, 0o755)
        self.run_overlay('rollback')
        self.assertEqual(self.targets(), before)
        self.assertEqual(self.backup.stat().st_mode & 0o777, 0o700)

    def test_unknown_installed_bytes_refuse_before_any_mutation(self):
        (self.base / 'target').write_bytes(b'other build')
        before = self.targets()
        with self.assertRaisesRegex(RuntimeError, 'unrecognized'):
            self.run_overlay('apply')
        self.assertEqual(self.targets(), before)
        self.assertFalse(self.backup.exists())

    def test_bad_payload_refuses_before_backup_or_writes(self):
        (self.bundle / '1').write_bytes(b'corrupt')
        before = self.targets()
        with self.assertRaisesRegex(RuntimeError, 'payload hash'):
            self.run_overlay('apply')
        self.assertEqual(self.targets(), before)
        self.assertFalse(self.backup.exists())

    def test_listening_gateway_prevents_apply(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            (self.base / 'gateway.json').write_text(json.dumps({'port': listener.getsockname()[1]}))
            before = self.targets()
            with self.assertRaisesRegex(RuntimeError, 'stop the gateway'):
                self.run_overlay('apply')
            self.assertEqual(self.targets(), before)
            self.assertFalse(self.backup.exists())

    def test_second_write_failure_restores_both_originals(self):
        before = self.targets()
        real_write = overlay.atomic_write
        calls = 0
        def fail_second(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('simulated second-file failure')
            real_write(*args)
        with patch.object(overlay, 'atomic_write', side_effect=fail_second):
            with self.assertRaises(OSError):
                self.run_overlay('apply')
        self.assertEqual(self.targets(), before)

    def test_tampered_backup_prevents_rollback(self):
        self.run_overlay('apply')
        before = self.targets()
        (self.backup / '1.original').write_bytes(b'tampered')
        with self.assertRaisesRegex(RuntimeError, 'backup hash'):
            self.run_overlay('rollback')
        self.assertEqual(self.targets(), before)


if __name__ == '__main__':
    unittest.main()
