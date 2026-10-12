#!/usr/bin/env python3
"""No-dependency tests for deterministic packaging and upgrade invalidation."""
import gzip
import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('assets', pathlib.Path(__file__).with_name('prepare-web-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class WebAssetsTest(unittest.TestCase):
    def test_exact_allowlist_compression_and_upgrade(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            source, dest, manifest = root / 'web', root / 'static', root / 'public.json'
            source.mkdir()
            (source / 'index.html').write_text('<html>current bootstrap</html>')
            content = b'const application = "full public build";\n' * 1000
            (source / 'main.dart.js').write_bytes(content)
            (source / 'shader.frag').write_bytes(b'shader bytes')
            (source / 'oauth-complete.html').write_text('<html>return to app</html>')
            (source / 'main.dart.js.map').write_text('private source mapping')
            (source / '.last_build_id').write_text('metadata')
            first = assets.prepare(source, dest, manifest)
            self.assertEqual(set(first), {'/index.html', '/main.dart.js', '/shader.frag'})
            self.assertFalse((dest / 'main.dart.js.map').exists())
            self.assertTrue((dest / 'oauth-complete.html').exists())
            self.assertNotIn('/oauth-complete.html', first)
            self.assertEqual(gzip.decompress((dest / 'main.dart.js.gz').read_bytes()), content)
            self.assertLess(first['/main.dart.js']['gzipLength'], len(content))
            compressed = (dest / 'main.dart.js.gz').read_bytes()
            self.assertEqual(first, assets.prepare(source, dest, manifest))
            self.assertEqual(compressed, (dest / 'main.dart.js.gz').read_bytes())
            (source / 'main.dart.js').write_bytes(content + b'new release')
            (source / 'shader.frag').unlink()
            updated = assets.prepare(source, dest, manifest)
            self.assertNotEqual(first['/main.dart.js']['etag'], updated['/main.dart.js']['etag'])
            self.assertNotEqual(first['/main.dart.js']['gzipEtag'], updated['/main.dart.js']['gzipEtag'])
            self.assertNotIn('/shader.frag', updated)
            self.assertFalse((dest / 'shader.frag').exists())


if __name__ == '__main__':
    unittest.main()
