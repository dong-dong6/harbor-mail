#!/usr/bin/env python3
"""Publish this project's verified development APK into private JAR resources.

No SDK installation, license acceptance, signing, credentials, or remote calls.
Only aapt/apksigner from an already installed official Android SDK are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

MAX_APK_BYTES = 256 * 1024 * 1024
MAX_TOOL_BYTES = 64 * 1024
MAX_RELEASE_NOTES_CHARS = 4000
PACKAGE = 'dev.harbor.harbor_mail.dev'
DOWNLOAD_PATH = '/downloads/android/app.apk'


def checked_tool(command):
    # Bound parsing and time; output is spooled, rather than kept in RAM.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                timeout=60, check=False, env={**os.environ, 'LC_ALL': 'C'})
        output.seek(0)
        data = output.read(MAX_TOOL_BYTES + 1)
    if result.returncode != 0 or len(data) > MAX_TOOL_BYTES:
        raise ValueError('Android SDK inspection failed or exceeded its output limit')
    return data.decode('utf-8', errors='strict')


def inspect_metadata(badging, certificates, version_name, version_code):
    package_lines = re.findall(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']*)'", badging, re.M)
    if len(package_lines) != 1:
        raise ValueError('APK must have one readable package and version')
    package, actual_code, actual_name = package_lines[0]
    if package != PACKAGE or actual_name != version_name or int(actual_code) != version_code:
        raise ValueError('APK package/version does not match this development build')
    if not re.search(r'^application-debuggable(?:\s|$)', badging, re.M):
        raise ValueError('Development download must be an explicitly debuggable build')
    certs = re.findall(r'^Signer #([0-9]+) certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$', certificates, re.M)
    names = re.findall(r'^Signer #([0-9]+) certificate DN: (.+)$', certificates, re.M)
    if len(certs) != 1 or certs[0][0] != '1' or len(names) != 1 or names[0][0] != '1':
        raise ValueError('APK must have exactly one verified signing certificate')
    if not re.search(r'(?:^|,\s*)CN=Android Debug(?:,|$)', names[0][1]):
        raise ValueError('Development download must use the Android debug certificate')
    return {'packageName': package, 'versionName': actual_name, 'versionCode': int(actual_code),
            'signing': {'classification': 'development-debug', 'certificateSha256': certs[0][1].lower()}}


def read_release_notes(path):
    if path is None:
        return None
    # UTF-8 uses at most four bytes per Unicode code point. Never load an
    # unbounded release document into the build's manifest.
    limit = MAX_RELEASE_NOTES_CHARS * 4
    if path.is_symlink() or not path.is_file():
        raise ValueError('Release notes must be a regular UTF-8 text file')
    with path.open('rb') as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Release notes exceed 4000 characters')
    notes = data.decode('utf-8', errors='strict')
    if len(notes) > MAX_RELEASE_NOTES_CHARS:
        raise ValueError('Release notes exceed 4000 characters')
    return notes


def prepare(apk, destination, aapt, apksigner, version_name, version_code, source_commit,
            release_notes_file=None, expected_certificate_sha256=None):
    if expected_certificate_sha256 is not None and not re.fullmatch(r'[0-9a-fA-F]{64}', expected_certificate_sha256):
        raise ValueError('Expected a pinned SHA-256 signing certificate')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version_name) or not 1 <= version_code <= 2100000000:
        raise ValueError('Expected a stable project version and positive Android version code')
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit):
        raise ValueError('A full source commit is required')
    release_notes = read_release_notes(release_notes_file)
    if apk.is_symlink() or not apk.is_file() or not 1 <= apk.stat().st_size <= MAX_APK_BYTES:
        raise ValueError('A real APK within the size limit is required')
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or (destination / 'app.apk').is_symlink() or (destination / 'manifest.json').is_symlink():
        raise ValueError('Download resources must not be symlinks')
    # Verify the exact staged bytes later embedded in the JAR, not a mutable input.
    with tempfile.TemporaryDirectory(prefix='.android-stage-', dir=destination.parent) as work:
        staged = Path(work) / 'app.apk'
        with apk.open('rb') as src, staged.open('wb') as dst:
            size = 0
            digest = hashlib.sha256()
            while chunk := src.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_APK_BYTES:
                    raise ValueError('APK exceeds the size limit')
                digest.update(chunk)
                dst.write(chunk)
        with staged.open('rb') as src:
            if src.read(4) != b'PK\x03\x04':
                raise ValueError('Input is not an APK ZIP container')
        badging = checked_tool([str(aapt), 'dump', 'badging', str(staged)])
        # Successful verify exit status is mandatory; text alone is not proof.
        certificates = checked_tool([str(apksigner), 'verify', '--verbose', '--print-certs', str(staged)])
        metadata = inspect_metadata(badging, certificates, version_name, version_code)
        if expected_certificate_sha256 is not None and metadata['signing']['certificateSha256'] != expected_certificate_sha256.lower():
            raise ValueError('APK signing certificate differs from the pinned persistent identity')
        manifest = {'schemaVersion': 1, 'available': True, 'downloadPath': DOWNLOAD_PATH,
                    'fileName': 'harbor-mail-dev.apk', 'sizeBytes': size, 'sha256': digest.hexdigest(),
                    'sourceCommit': source_commit, **metadata}
        if release_notes is not None:
            manifest['releaseNotes'] = release_notes
        staged_manifest = Path(work) / 'manifest.json'
        staged_manifest.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n', encoding='utf-8')
        # Package offline after both files are written; never run this against a live exploded server.
        os.replace(staged, destination / 'app.apk')
        os.replace(staged_manifest, destination / 'manifest.json')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--aapt', type=Path, required=True)
    parser.add_argument('--apksigner', type=Path, required=True)
    parser.add_argument('--version-name', required=True)
    parser.add_argument('--version-code', type=int, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--expected-certificate-sha256', help='Required certificate identity for distributable CI builds')
    parser.add_argument('--release-notes-file', type=Path,
                        help='Optional UTF-8 plain-text release notes, at most 4000 Unicode characters')
    args = parser.parse_args()
    try:
        metadata = prepare(args.apk, args.destination, args.aapt, args.apksigner,
                           args.version_name, args.version_code, args.source_commit, args.release_notes_file,
                           args.expected_certificate_sha256)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        raise SystemExit('Android download preparation failed: ' + str(exc)) from exc
    print(json.dumps(metadata, sort_keys=True))
