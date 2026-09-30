#!/usr/bin/env python3
"""Check package versions; pushed version tags must match both manifests."""
import os
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
version = ET.parse(root / 'server/pom.xml').getroot().findtext('{http://maven.apache.org/POM/4.0.0}version')
client = re.search(r'^version:\s*(\S+)', (root / 'client/pubspec.yaml').read_text(), re.M)
if not version or not client or client[1].split('+')[0] != version:
    raise SystemExit('Server and Flutter versions must match')
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('Expected a stable X.Y.Z project version')
if os.environ.get('REF_TYPE') == 'tag' and os.environ.get('REF_NAME') != f'v{version}':
    raise SystemExit(f'Release tag must be v{version}; update both manifests before a new release')
print(version)
