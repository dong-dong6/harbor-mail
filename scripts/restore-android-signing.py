#!/usr/bin/env python3
"""Restore CI signing material and verify its pinned public certificate; never generate keys."""
import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import subprocess


def restore(environ, destination):
    names = ['HARBOR_ANDROID_KEYSTORE_BASE64', 'HARBOR_ANDROID_STORE_PASSWORD',
             'HARBOR_ANDROID_KEY_PASSWORD', 'HARBOR_ANDROID_KEY_ALIAS',
             'HARBOR_ANDROID_CERTIFICATE_SHA256']
    if any(not environ.get(name, '').strip() for name in names):
        raise ValueError('Configure all persistent Android signing Secrets before publishing')
    expected = environ['HARBOR_ANDROID_CERTIFICATE_SHA256'].strip().lower()
    if not re.fullmatch('[0-9a-f]{64}', expected):
        raise ValueError('The pinned signing certificate must be a SHA-256 digest')
    encoded = environ['HARBOR_ANDROID_KEYSTORE_BASE64']
    if len(encoded) > 90_000:
        raise ValueError('Signing keystore exceeds the allowed size')
    try:
        data = base64.b64decode(''.join(encoded.split()), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError('Signing keystore must be valid Base64') from error
    if not 1 <= len(data) <= 64 * 1024:
        raise ValueError('Signing keystore is empty or exceeds the allowed size')
    destination = destination.resolve()
    if '\n' in str(destination) or '\r' in str(destination):
        raise ValueError('Invalid signing destination')
    # Exclusive creation: never overwrite an existing identity or follow a symlink.
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        result = subprocess.run(
            ['keytool', '-exportcert', '-keystore', str(destination),
             '-alias', environ['HARBOR_ANDROID_KEY_ALIAS'],
             '-storepass:env', 'HARBOR_ANDROID_STORE_PASSWORD'],
            capture_output=True, timeout=30, env=environ, check=False)
        if result.returncode != 0 or not 1 <= len(result.stdout) <= 16 * 1024:
            raise ValueError('Cannot open the configured signing key and alias')
        if hashlib.sha256(result.stdout).hexdigest() != expected:
            raise ValueError('Signing key does not match the pinned certificate; refusing identity change')
        return destination, expected
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    try:
        path, certificate = restore(os.environ, args.destination)
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
            output.write(f'HARBOR_ANDROID_KEYSTORE={path}\n')
            output.write(f'HARBOR_ANDROID_CERTIFICATE_SHA256={certificate}\n')
        print('Persistent Android signing certificate verified: ' + certificate)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Tool output and secret values never enter logs.
        raise SystemExit('Persistent Android signing setup failed: ' + str(error)) from None


if __name__ == '__main__':
    main()
