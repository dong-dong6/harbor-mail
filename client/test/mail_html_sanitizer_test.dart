import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/mail_html_sanitizer.dart';
import 'package:html/parser.dart';

const _png =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z/D/PwAG/gL+DHWJ3gAAAABJRU5ErkJggg==';
const _source = 'https://images.example.invalid/banner.png';

void main() {
  test(
    'preserves normal headings emphasis lists links and table formatting',
    () {
      final safe = sanitizeMailHtml('''
      <h2>Monthly report &amp; plans</h2>
      <p style="font-size:16px;color:#123456">Hello <strong>team</strong> <em>today</em>.</p>
      <ul><li>First</li><li>Second</li></ul>
      <table border="1" cellpadding="8" style="border-collapse:collapse;width:100%">
        <thead><tr><th>Item</th><th>Total</th></tr></thead>
        <tbody><tr><td colspan="1" style="background:#eef1f5">Widgets</td><td>42</td></tr></tbody>
      </table>
      <a href="https://example.invalid/report?q=1&amp;page=2">View report</a>
    ''');
      final body = parseFragment(safe.html);
      expect(body.querySelector('h2')?.text, 'Monthly report & plans');
      expect(body.querySelector('strong')?.text, 'team');
      expect(body.querySelector('em')?.text, 'today');
      expect(body.querySelectorAll('li'), hasLength(2));
      expect(body.querySelectorAll('table td'), hasLength(2));
      expect(
        body.querySelector('p')?.attributes['style'],
        contains('color:#123456'),
      );
      expect(
        body.querySelector('td')?.attributes['style'],
        'background-color:#eef1f5',
      );
      expect(
        body.querySelector('a')?.attributes['href'],
        'https://example.invalid/report?q=1&page=2',
      );
      expect(safe.text, contains('Widgets\t42'));
      expect(safe.truncated, isFalse);
    },
  );

  test(
    'drops executable interactive and foreign elements with their content',
    () {
      final safe = sanitizeMailHtml('''
      <p onclick="evil()">Visible</p><script>script-secret</script>
      <style>@import 'https://tracking.invalid/css';body{background:url(https://tracking.invalid/a)}</style>
      <iframe src="https://tracking.invalid/frame">frame-secret</iframe>
      <form action="https://tracking.invalid/send"><input value="secret">form-secret</form>
      <object data="file:///private">object-secret</object>
      <svg><a xlink:href="javascript:evil()">svg-secret</a></svg>
      <math><mi>math-secret</mi></math><template>template-secret</template>
      <audio src="https://tracking.invalid/audio"></audio>
      <video poster="https://tracking.invalid/poster"></video>
      <meta http-equiv="refresh" content="0;url=https://tracking.invalid/refresh">
      <base href="https://tracking.invalid/"><link rel="stylesheet" href="https://tracking.invalid/style">
    ''');
      expect(safe.text, 'Visible');
      expect(safe.html, isNot(contains('tracking.invalid')));
      expect(safe.html, isNot(contains('secret')));
      expect(safe.html, isNot(contains('onclick')));
      expect(safe.images, isEmpty);
    },
  );

  test('removes CSS resources escapes variables and positional overlays', () {
    final safe = sanitizeMailHtml(r'''
      <div style="color:red;background-image:url(https://tracking.invalid/1);
          background:url(https://tracking.invalid/2);font-family:evil;
          position:fixed;top:0;z-index:9999;--secret:url(https://tracking.invalid/3);
          width:expression(evil());height:var(--h);border:u\72l(https://tracking.invalid/4);
          padding:4px;border-radius:8px">Text</div>
    ''');
    expect(safe.html, contains('color:red'));
    expect(safe.html, contains('padding:4px'));
    expect(safe.html, contains('border-radius:8px'));
    for (final blocked in [
      'url',
      'tracking.invalid',
      'position',
      'z-index',
      'expression',
      'var(',
      '\\',
    ]) {
      expect(safe.html, isNot(contains(blocked)));
    }
  });

  test(
    'images are blocked by default including inline data file cid and forged IDs',
    () {
      final safe = sanitizeMailHtml(
        '''
      <img src="$_source" srcset="https://tracking.invalid/2 2x" onerror="evil()" alt="Banner">
      <img src="$_png" data-harbor-image="0"><img src="file:///secret">
      <img src="asset:///secrets"><img src="cid:attachment"><img src="//tracking.invalid/pixel">
    ''',
        verifiedImages: {_source: _png},
      );
      expect(safe.html, contains('[Banner]'));
      expect(safe.html, isNot(contains('<img')));
      expect(safe.html, isNot(contains('src')));
      expect(safe.html, isNot(contains('data-harbor-image')));
      expect(safe.images, isEmpty);
    },
  );

  test(
    'opt-in alone cannot load origins, only exact proxy PNG matches work',
    () {
      final blocked = sanitizeMailHtml(
        '<img src="$_source">',
        allowImages: true,
      );
      expect(blocked.images, isEmpty);
      final safe = sanitizeMailHtml(
        '''
      <img src="$_source" alt="Safe"><img src="https://tracking.invalid/other">
      <img src="$_png"><img data-harbor-image="0">
    ''',
        allowImages: true,
        verifiedImages: {_source: _png},
      );
      expect(safe.images, hasLength(1));
      final image = parseFragment(safe.html).querySelector('img')!;
      expect(image.attributes['data-harbor-image'], '0');
      expect(image.attributes.containsKey('src'), isFalse);
      expect(safe.html, isNot(contains(_source)));
      expect(safe.html, isNot(contains('base64')));
    },
  );

  test(
    'proxy strings cannot reintroduce URL SVG invalid or oversized image data',
    () {
      final oversized = Uint8List(4 * 1024 * 1024 + 1)
        ..setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
      final bomb = base64Decode(_png.split(',').last);
      ByteData.sublistView(bomb).setUint32(16, 8193);
      for (final value in [
        'https://tracking.invalid/fallback',
        'data:image/svg+xml;base64,PHN2Zz4=',
        'data:image/png;base64,iVBORw0KGgo=',
        'data:image/png;base64,${base64Encode(oversized)}',
        'data:image/png;base64,${base64Encode(bomb)}',
        'data:image/png;base64,invalid',
        'data:image/png;base64,${_png.split(',').last}\n',
      ]) {
        final safe = sanitizeMailHtml(
          '<img src="$_source">',
          allowImages: true,
          verifiedImages: {_source: value},
        );
        expect(safe.images, isEmpty);
        expect(safe.html, isNot(contains('<img')));
      }
    },
  );

  test(
    'duplicate proxy placements spend both count and decoded byte budgets',
    () {
      final safe = sanitizeMailHtml(
        '<img src="$_source">' * 100,
        allowImages: true,
        verifiedImages: {_source: _png},
      );
      expect(safe.images, hasLength(32));
      final large = Uint8List(4 * 1024 * 1024)
        ..setRange(0, 33, base64Decode(_png.split(',').last));
      final bounded = sanitizeMailHtml(
        '<img src="$_source">' * 10,
        allowImages: true,
        verifiedImages: {
          _source: 'data:image/png;base64,${base64Encode(large)}',
        },
      );
      expect(bounded.images, hasLength(4));
    },
  );

  test('unsafe hrefs and additional tracking attributes never survive', () {
    for (final url in [
      'javascript:evil()',
      'java&#x73;cript:evil()',
      'data:text/html,evil',
      'file:///private',
      'intent://app',
      'mailto:someone@example.invalid',
      '//example.invalid/path',
      '/relative',
      '#fragment',
      'https://user:password@example.invalid/',
    ]) {
      final safe = sanitizeMailHtml(
        '<a href="$url" ping="https://tracking.invalid" download="private" target="_self">Link</a>',
      );
      final anchor = parseFragment(safe.html).querySelector('a')!;
      expect(anchor.attributes.containsKey('href'), isFalse, reason: url);
      expect(anchor.attributes.containsKey('ping'), isFalse);
      expect(anchor.attributes.containsKey('download'), isFalse);
      expect(anchor.attributes.containsKey('target'), isFalse);
    }
  });

  test(
    'HTTP(S) links require a proper destination without hidden characters',
    () {
      expect(safeMailLink(' HTTPS://example.invalid/hello?a=1 '), isNotNull);
      expect(safeMailLink('http://example.invalid:8080/hello'), isNotNull);
      for (final url in [
        'https://',
        'https:/example.invalid',
        'https://example.invalid:0',
        'https://example.invalid:65536',
        'https://example.invalid:not-a-port',
        'https://example.invalid/\npath',
        'https://example.invalid/\u202epath',
        r'https://example.invalid\@tracking.invalid/',
      ]) {
        expect(safeMailLink(url), isNull, reason: url);
      }
    },
  );

  test(
    'malformed markup is repaired while malicious attributes remain absent',
    () {
      final safe = sanitizeMailHtml(
        '<p>Start &lt;script&gt;<strong>bold<table><tr><td>Cell<img src=x onerror=evil()>',
      );
      expect(safe.text, contains('Start <script>bold'));
      expect(safe.text, contains('Cell'));
      expect(safe.html, isNot(contains('onerror')));
      expect(safe.html, isNot(contains('src=')));
      expect(safe.html, contains('&lt;script&gt;'));
    },
  );

  test('depth text and layout sizes are bounded', () {
    final deep = sanitizeMailHtml('${'<div>' * 200}Hidden${'</div>' * 200}');
    expect(deep.truncated, isTrue);
    final long = sanitizeMailHtml('x' * (2 * 1024 * 1024 + 1));
    expect(long.truncated, isTrue);
    expect(long.text.length, 256 * 1024);
    final layout = sanitizeMailHtml(
      '<table><tr><td colspan="9999" rowspan="9999" style="width:999999px;height:1e100px;font-size:90000px">Cell</td></tr></table>',
    );
    final cell = parseFragment(layout.html).querySelector('td')!;
    expect(cell.attributes, isEmpty);
  });

  test(
    'aggregate decoded pixels are bounded for both repeated and distinct images',
    () {
      final large = base64Decode(_png.split(',').last);
      ByteData.sublistView(large)
        ..setUint32(16, 4000)
        ..setUint32(20, 2000);
      final eightMegapixels = 'data:image/png;base64,${base64Encode(large)}';
      final repeated = sanitizeMailHtml(
        '<img src="$_source">' * 32,
        allowImages: true,
        verifiedImages: {_source: eightMegapixels},
      );
      expect(repeated.images, hasLength(2));
      final distinct = sanitizeMailHtml(
        List.generate(32, (i) => '<img src="$_source/$i">').join(),
        allowImages: true,
        verifiedImages: {
          for (var i = 0; i < 32; i++) '$_source/$i': eightMegapixels,
        },
      );
      expect(distinct.images, hasLength(2));
    },
  );

  test(
    'node-count limit truncates before building an excessive widget tree',
    () {
      final safe = sanitizeMailHtml('<br>' * 10000);
      expect(safe.truncated, isTrue);
      expect(parseFragment(safe.html).querySelectorAll('br'), hasLength(8000));
    },
  );
}
