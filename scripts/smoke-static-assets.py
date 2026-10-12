#!/usr/bin/env python3
"""Check actual integrated HTTP responses, cold/warm payloads and cache isolation."""
import argparse
import gzip
import hashlib
import json
import pathlib
import urllib.error
import urllib.request


def get(base, path, method='GET', **headers):
    request = urllib.request.Request(base.rstrip('/') + path, method=method, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def check(base, manifest):
    report = []
    paths = ['/index.html', '/flutter_bootstrap.js', '/version.json', '/manifest.json',
             '/flutter_service_worker.js', '/main.dart.js',
             '/assets/assets/fonts/NotoSansSC.otf', '/canvaskit/chromium/canvaskit.wasm']
    for path in paths:
        expected = manifest[path]
        status, headers, plain = get(base, path, **{'Accept-Encoding': 'identity'})
        assert status == 200, (path, status)
        assert headers['Cache-Control'] == 'public, no-cache, must-revalidate', path
        assert headers['ETag'] == expected['etag'], path
        assert headers.get('Content-Encoding') is None, path
        assert len(plain) == expected['length'], path
        assert '"' + hashlib.sha256(plain).hexdigest() + '"' == expected['etag'], path
        status, headers, encoded = get(base, path, **{'Accept-Encoding': 'br, gzip'})
        assert status == 200, (path, status)
        assert 'Accept-Encoding' in ','.join(headers.get_all('Vary', [])), path
        assert 'Origin' in ','.join(headers.get_all('Vary', [])), path
        etag = headers['ETag']
        assert etag == expected.get('gzipEtag', expected['etag']), path
        if 'gzipEtag' in expected:
            assert headers['Content-Encoding'] == 'gzip', path
            assert gzip.decompress(encoded) == plain, path
        else:
            assert encoded == plain, path
        status, warm_headers, warm = get(base, path, **{'Accept-Encoding': 'br, gzip', 'If-None-Match': etag})
        assert status == 304 and not warm, (path, status, len(warm))
        assert warm_headers['Cache-Control'] == 'public, no-cache, must-revalidate', path
        status, _, body = get(base, path, **{'If-None-Match': '"previous-release"'})
        assert status == 200 and body == plain, path
        status, head_headers, head = get(base, path, 'HEAD', **{'Accept-Encoding': 'gzip'})
        assert status == 200 and not head, path
        assert int(head_headers['Content-Length']) == len(encoded), path
        report.append({'path': path, 'coldIdentityBytes': len(plain), 'coldEncodedBytes': len(encoded),
                       'warmStatus': 304, 'warmBodyBytes': len(warm), 'encoding': headers.get('Content-Encoding', 'identity')})
    for path in ['/api/v1/accounts', '/api/v1/messages', '/api/v1/attachments/missing',
                 '/api/v1/accounts/missing/messages/missing/images', '/oauth-complete.html',
                 '/nonexistent-private-data.js']:
        status, headers, _ = get(base, path, **{'Accept-Encoding': 'gzip', 'If-None-Match': '*'})
        assert headers['Cache-Control'] == 'no-store', path
        assert headers.get('Content-Encoding') is None, path
        assert status != 304, path
        if path.startswith('/api/'):
            assert status == 401, (path, status)
    status, headers, _ = get(base, '/')
    assert status == 200 and headers['ETag'] == manifest['/index.html']['etag']
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:8080')
    parser.add_argument('--manifest', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] /
                        'server/src/main/resources/META-INF/public-web-assets.json')
    args = parser.parse_args()
    print(json.dumps(check(args.url, json.loads(args.manifest.read_text())), indent=2))
