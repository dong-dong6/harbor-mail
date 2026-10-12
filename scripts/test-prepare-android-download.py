#!/usr/bin/env python3
"""Synthetic contract tests; these fixtures are NOT installable or signed APKs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('android_download', Path(__file__).with_name('prepare-android-download.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BADGING = "package: name='dev.harbor.harbor_mail.dev' versionCode='5' versionName='0.2.3' platformBuildVersionName=''\napplication-debuggable\n"
CERTS = 'Signer #1 certificate DN: CN=Android Debug, O=Android, C=US\nSigner #1 certificate SHA-256 digest: ' + 'a' * 64 + '\n'


class PrepareAndroidTests(unittest.TestCase):
    def test_actual_staged_bytes_generate_digest_and_no_paths(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'input.apk'
            source.write_bytes(b'PK\x03\x04synthetic-contract-fixture-only')
            destination = root / 'private-resources'
            with patch.object(module, 'checked_tool', side_effect=[BADGING, CERTS]) as inspect:
                manifest = module.prepare(source, destination, Path('aapt'), Path('apksigner'), '0.2.3', 5, 'b' * 40)
            self.assertEqual(['aapt', 'apksigner'], [call.args[0][0] for call in inspect.call_args_list])
            self.assertIn('verify', inspect.call_args_list[1].args[0])
            data = (destination / 'app.apk').read_bytes()
            self.assertEqual(source.read_bytes(), data)
            self.assertEqual(hashlib.sha256(data).hexdigest(), manifest['sha256'])
            self.assertEqual(len(data), manifest['sizeBytes'])
            self.assertEqual(manifest, json.loads((destination / 'manifest.json').read_text()))
            self.assertNotIn(directory, json.dumps(manifest))
            self.assertEqual('/downloads/android/app.apk', manifest['downloadPath'])
            self.assertEqual('development-debug', manifest['signing']['classification'])
            self.assertEqual(1, manifest['schemaVersion'])
            self.assertNotIn('releaseNotes', manifest)

    def test_optional_release_notes_are_plain_text_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, notes = root / 'source.apk', root / 'notes.txt'
            source.write_bytes(b'PK\x03\x04synthetic-contract-fixture-only')
            for content in ['', '更新说明\n- 保留设置。\n<script>plain text</script>\n', '📨' * 4000]:
                with self.subTest(length=len(content)):
                    notes.write_text(content, encoding='utf-8')
                    with patch.object(module, 'checked_tool', side_effect=[BADGING, CERTS]):
                        manifest = module.prepare(source, root / 'out', Path('aapt'), Path('apksigner'),
                                                  '0.2.3', 5, 'b' * 40, release_notes_file=notes)
                    self.assertEqual(1, manifest['schemaVersion'])
                    self.assertEqual(content, manifest['releaseNotes'])
                    self.assertEqual(content, json.loads((root / 'out' / 'manifest.json').read_text(encoding='utf-8'))['releaseNotes'])

    def test_invalid_release_notes_fail_before_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, notes, destination = root / 'source.apk', root / 'notes.txt', root / 'out'
            source.write_bytes(b'PK\x03\x04synthetic-contract-fixture-only')
            for content in [b'x' * 4001, ('📨' * 4001).encode('utf-8'), b'\xffinvalid UTF-8']:
                with self.subTest(length=len(content)):
                    notes.write_bytes(content)
                    with patch.object(module, 'checked_tool') as inspect, self.assertRaises(ValueError):
                        module.prepare(source, destination, Path('aapt'), Path('apksigner'),
                                       '0.2.3', 5, 'b' * 40, release_notes_file=notes)
                    inspect.assert_not_called()
                    self.assertFalse((destination / 'manifest.json').exists())
                    self.assertFalse((destination / 'app.apk').exists())

    def test_release_notes_file_must_exist_and_not_be_a_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes, link = root / 'notes.txt', root / 'link.txt'
            notes.write_text('Current release', encoding='utf-8')
            link.symlink_to(notes)
            for candidate in [root / 'missing.txt', root, link]:
                with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                    module.read_release_notes(candidate)

    def test_rejects_wrong_package_version_and_non_debug_build(self):
        for invalid in [BADGING.replace('.dev\'', '\''), BADGING.replace("versionCode='5'", "versionCode='6'"),
                        BADGING.replace("versionName='0.2.3'", "versionName='0.2.4'"),
                        BADGING.replace('application-debuggable', ''), BADGING + BADGING]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                module.inspect_metadata(invalid, CERTS, '0.2.3', 5)

    def test_rejects_fake_certificate_multisigner_and_release_claim(self):
        for invalid in [CERTS.replace('Android Debug', 'Production'), CERTS.replace('a' * 64, 'invalid'),
                        CERTS + CERTS, '', CERTS.replace('Signer #1', 'Signer #2')]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                module.inspect_metadata(BADGING, invalid, '0.2.3', 5)

    def test_bad_input_or_failed_verify_does_not_publish_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, dest = root / 'source.apk', root / 'out'
            for content in [b'', b'not an APK']:
                source.write_bytes(content)
                with self.assertRaises(ValueError):
                    module.prepare(source, dest, Path('aapt'), Path('apksigner'), '0.2.3', 5, 'b' * 40)
                self.assertFalse((dest / 'manifest.json').exists())
                self.assertFalse((dest / 'app.apk').exists())
            source.write_bytes(b'PK\x03\x04synthetic')
            with patch.object(module, 'checked_tool', side_effect=[BADGING, ValueError('signature verification failed')]):
                with self.assertRaises(ValueError):
                    module.prepare(source, dest, Path('aapt'), Path('apksigner'), '0.2.3', 5, 'b' * 40)
            self.assertFalse((dest / 'manifest.json').exists())
            self.assertFalse((dest / 'app.apk').exists())


    def test_tool_failure_timeout_and_bounded_output_fail_closed(self):
        import subprocess
        from types import SimpleNamespace
        with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
            with self.assertRaises(ValueError):
                module.checked_tool(['apksigner', 'verify', 'synthetic.apk'])
        def oversized(command, **kwargs):
            kwargs['stdout'].write(b'x' * (module.MAX_TOOL_BYTES + 1))
            return SimpleNamespace(returncode=0)
        with patch.object(module.subprocess, 'run', side_effect=oversized):
            with self.assertRaises(ValueError):
                module.checked_tool(['aapt', 'dump', 'badging', 'synthetic.apk'])
        with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired('aapt', 60)):
            with self.assertRaises(subprocess.TimeoutExpired):
                module.checked_tool(['aapt', 'dump', 'badging', 'synthetic.apk'])

    def test_refuses_symlink_input_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.apk'
            source.write_bytes(b'PK\x03\x04synthetic')
            link = root / 'link.apk'
            link.symlink_to(source)
            for candidate in [link, root / 'absent.apk']:
                with self.assertRaises(ValueError):
                    module.prepare(candidate, root / 'out', Path('aapt'), Path('apksigner'), '0.2.3', 5, 'b' * 40)
            with patch.object(module, 'MAX_APK_BYTES', 3), self.assertRaises(ValueError):
                module.prepare(source, root / 'out', Path('aapt'), Path('apksigner'), '0.2.3', 5, 'b' * 40)


if __name__ == '__main__':
    unittest.main()
