#!/usr/bin/env python3
"""Upload the prepared identity with an already authenticated official GitHub CLI.

No Git credential-helper access, token extraction, or credential logging.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

NAMES = {'ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_PASSWORD',
         'ANDROID_KEY_ALIAS', 'ANDROID_SIGNING_CERTIFICATE_SHA256'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--secrets-file', type=Path, required=True)
    parser.add_argument('--repo', default='dong-dong6/harbor-mail')
    parser.add_argument('--gh', default='gh')
    args = parser.parse_args()
    executable = shutil.which(args.gh)
    if not executable:
        raise SystemExit('Install the official GitHub CLI and run gh auth login first.')
    values = json.loads(args.secrets_file.read_text(encoding='utf-8'))
    if set(values) != NAMES or any(not isinstance(value, str) or not value for value in values.values()):
        raise SystemExit('The signing setup file must contain exactly the five nonempty signing Secrets.')
    auth = subprocess.run([executable, 'auth', 'status'], capture_output=True, timeout=30)
    if auth.returncode:
        raise SystemExit('GitHub CLI login is required. Run gh auth login; do not paste tokens into chat.')
    command = [executable, 'secret', 'list', '--repo', args.repo, '--json', 'name']
    listed = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if listed.returncode:
        raise SystemExit('GitHub CLI cannot manage Actions Secrets for this repository.')
    existing = {item['name'] for item in json.loads(listed.stdout)}
    if NAMES & existing:
        raise SystemExit('Signing Secrets already exist. Refusing to replace an existing signing identity.')
    for name in sorted(NAMES):
        result = subprocess.run([executable, 'secret', 'set', name, '--repo', args.repo, '--app', 'actions'],
                                input=values[name], text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise SystemExit('Failed to store ' + name + '; stop and inspect the repository settings.')
        print('Configured ' + name)
    print('All five Actions signing Secrets configured; CI will verify the actual certificate before publishing.')


if __name__ == '__main__':
    main()
