#!/usr/bin/env python3
"""Verify the integrated JAR serves the exact CI APK and metadata."""
import argparse
import hashlib
import json
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url', required=True)
parser.add_argument('--source-commit', required=True)
args = parser.parse_args()
base = args.url.rstrip('/')
# CI supplies the trusted local demo origin, never a metadata-provided origin.
with urllib.request.urlopen(base + '/downloads/android/manifest.json', timeout=15) as response:
    assert response.status == 200
    data = response.read(64 * 1024 + 1)
    assert len(data) <= 64 * 1024
    manifest = json.loads(data)
assert manifest['available'] is True
assert manifest['sourceCommit'] == args.source_commit
assert manifest['downloadPath'] == '/downloads/android/app.apk'
assert manifest['packageName'] == 'dev.harbor.harbor_mail.dev'
assert manifest['signing']['classification'] == 'development-debug'
if 'releaseNotes' in manifest:
    assert isinstance(manifest['releaseNotes'], str)
    assert len(manifest['releaseNotes']) <= 4000
with urllib.request.urlopen(base + '/downloads/android/app.apk', timeout=30) as response:
    assert response.status == 200
    assert response.headers.get('Content-Type') == 'application/vnd.android.package-archive'
    assert response.headers.get('Content-Disposition') == 'attachment; filename="harbor-mail-dev.apk"'
    assert response.headers.get('X-Content-Type-Options') == 'nosniff'
    assert response.headers.get('ETag') == '"' + manifest['sha256'] + '"'
    digest = hashlib.sha256()
    size = 0
    while chunk := response.read(1024 * 1024):
        size += len(chunk)
        assert size <= 256 * 1024 * 1024
        digest.update(chunk)
assert size == manifest['sizeBytes']
assert digest.hexdigest() == manifest['sha256']
print('Integrated development APK verified: actual download size, SHA-256, headers, package and source commit match.')
