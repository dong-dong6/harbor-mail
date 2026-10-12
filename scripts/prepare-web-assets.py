#!/usr/bin/env python3
"""Index exact public Flutter assets and generate deterministic gzip sidecars."""
import argparse
import gzip
import hashlib
import json
import pathlib
import shutil

MIME = {
    '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif',
    '.wasm': 'application/wasm', '.otf': 'font/otf', '.ttf': 'font/ttf',
    '.woff': 'font/woff', '.woff2': 'font/woff2', '.bin': 'application/octet-stream',
    '.frag': 'application/octet-stream',
}
COMPRESSIBLE = {'.html', '.js', '.css', '.json', '.svg', '.wasm', '.otf', '.ttf', '.bin', '.frag'}


def digest(data):
    return '"' + hashlib.sha256(data).hexdigest() + '"'


def prepare(source, destination, manifest):
    if not (source / 'index.html').is_file():
        raise ValueError('A complete Flutter web build with index.html is required')
    if source.resolve() == destination.resolve():
        raise ValueError('Source and destination must differ')
    destination.mkdir(parents=True, exist_ok=True)
    for child in destination.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    assets = {}
    for file in sorted(source.rglob('*')):
        relative = file.relative_to(source)
        if not file.is_file() or file.is_symlink() or any(p.startswith('.') for p in relative.parts):
            continue
        if file.suffix in {'.map', '.symbols', '.gz', '.br'}:
            continue
        data = file.read_bytes()
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        # Authentication completion stays on the original no-store policy.
        if relative.as_posix() == 'oauth-complete.html':
            continue
        entry = {'etag': digest(data), 'length': len(data),
                 'contentType': MIME.get(file.suffix, 'application/octet-stream')}
        if file.suffix in COMPRESSIBLE or relative.as_posix() == 'assets/NOTICES':
            compressed = gzip.compress(data, compresslevel=9, mtime=0)
            if len(data) >= 512 and len(compressed) < len(data):
                target.with_name(target.name + '.gz').write_bytes(compressed)
                entry.update(gzipEtag=digest(compressed), gzipLength=len(compressed))
        assets['/' + relative.as_posix()] = entry
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(assets, ensure_ascii=True, sort_keys=True, indent=2) + '\n')
    return assets


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=pathlib.Path)
    root = parser.parse_args().root
    assets = prepare(root / 'client/build/web', root / 'server/src/main/resources/static',
                     root / 'server/src/main/resources/META-INF/public-web-assets.json')
    original = sum(a['length'] for a in assets.values())
    transferred = sum(a.get('gzipLength', a['length']) for a in assets.values())
    print(f'Indexed {len(assets)} public assets: {original:,} identity bytes / '
          f'{transferred:,} gzip-or-identity bytes (all built variants, not one page load).')
