#!/usr/bin/env python3
"""Signing setup tests with synthetic keystore bytes and controlled keytool output."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('restore_signing', Path(__file__).with_name('restore-android-signing.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RestoreSigningTests(unittest.TestCase):
    def env(self):
        return {
            'HARBOR_ANDROID_KEYSTORE_BASE64': base64.b64encode(b'synthetic-keystore').decode(),
            'HARBOR_ANDROID_STORE_PASSWORD': 'synthetic-store-secret',
            'HARBOR_ANDROID_KEY_PASSWORD': 'synthetic-key-secret',
            'HARBOR_ANDROID_KEY_ALIAS': 'synthetic-alias',
            'HARBOR_ANDROID_CERTIFICATE_SHA256': hashlib.sha256(b'synthetic-certificate').hexdigest(),
        }

    def test_repeated_restores_keep_same_identity_and_do_not_log_passwords(self):
        with tempfile.TemporaryDirectory() as work:
            paths = [Path(work) / 'first.p12', Path(work) / 'second.p12']
            with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'synthetic-certificate')) as tool:
                pins = [module.restore(self.env(), path)[1] for path in paths]
            self.assertEqual(pins[0], pins[1])
            self.assertEqual(paths[0].read_bytes(), paths[1].read_bytes())
            for call in tool.call_args_list:
                args = call.args[0]
                self.assertIn('-exportcert', args)
                self.assertIn('-storepass:env', args)
                self.assertNotIn('synthetic-store-secret', args)
                self.assertNotIn('synthetic-key-secret', args)

    def test_missing_config_or_malformed_input_never_creates_a_keystore(self):
        cases = []
        for name in self.env():
            env = self.env()
            del env[name]
            cases.append(env)
        cases.extend([{**self.env(), 'HARBOR_ANDROID_KEYSTORE_BASE64': '!!!'},
                      {**self.env(), 'HARBOR_ANDROID_CERTIFICATE_SHA256': 'not-a-digest'}])
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'key.p12'
            for env in cases:
                with self.subTest(keys=list(env)), patch.object(module.subprocess, 'run') as tool:
                    with self.assertRaises(ValueError):
                        module.restore(env, path)
                    self.assertFalse(path.exists())
                    tool.assert_not_called()

    def test_mismatched_or_unreadable_identity_cleans_up_without_exposing_secrets(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'key.p12'
            for result in [SimpleNamespace(returncode=0, stdout=b'different-certificate'),
                           SimpleNamespace(returncode=1, stdout=b'synthetic-store-secret')]:
                with patch.object(module.subprocess, 'run', return_value=result):
                    with self.assertRaises(ValueError) as error:
                        module.restore(self.env(), path)
                    self.assertNotIn('synthetic-store-secret', str(error.exception))
                    self.assertFalse(path.exists())

    def test_existing_key_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'key.p12'
            path.write_bytes(b'existing-identity')
            with self.assertRaises(FileExistsError):
                module.restore(self.env(), path)
            self.assertEqual(b'existing-identity', path.read_bytes())


if __name__ == '__main__':
    unittest.main()
