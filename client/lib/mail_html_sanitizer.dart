import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// A deliberately small mail format, never a general-purpose browser document.
///
/// Resource URLs, executable elements, event handlers and sender-supplied image
/// data are not copied. Approved proxy PNGs are kept outside the HTML and are
/// referenced only by renderer-created IDs. The native renderer also disables
/// every resource-loading factory, independently of this sanitizer.
class SanitizedMailHtml {
  final String html;
  final String text;
  final Map<String, Uint8List> images;
  final bool truncated;

  const SanitizedMailHtml._(this.html, this.text, this.images, this.truncated);
}

const _allowedTags = {
  'a',
  'abbr',
  'b',
  'blockquote',
  'br',
  'caption',
  'center',
  'code',
  'col',
  'colgroup',
  'dd',
  'del',
  'div',
  'dl',
  'dt',
  'em',
  'font',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'i',
  'img',
  'li',
  'ol',
  'p',
  'pre',
  's',
  'small',
  'span',
  'strong',
  'sub',
  'sup',
  'table',
  'tbody',
  'td',
  'th',
  'thead',
  'tfoot',
  'tr',
  'u',
  'ul',
};
const _dropTags = {
  'script',
  'style',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'svg',
  'math',
  'form',
  'input',
  'button',
  'textarea',
  'select',
  'option',
  'link',
  'meta',
  'base',
  'template',
  'noscript',
  'audio',
  'video',
  'source',
  'track',
  'canvas',
  'applet',
};
const _blockTags = {
  'blockquote',
  'br',
  'caption',
  'dd',
  'div',
  'dl',
  'dt',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'li',
  'ol',
  'p',
  'pre',
  'table',
  'tr',
  'ul',
};
const _styleProperties = {
  'background-color',
  'color',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'line-height',
  'text-align',
  'text-decoration',
  'text-decoration-line',
  'text-decoration-style',
  'text-decoration-color',
  'text-transform',
  'letter-spacing',
  'word-spacing',
  'white-space',
  'vertical-align',
  'border',
  'border-top',
  'border-right',
  'border-bottom',
  'border-left',
  'border-color',
  'border-width',
  'border-style',
  'border-radius',
  'border-collapse',
  'border-spacing',
  'padding',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'margin',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'width',
  'max-width',
  'min-width',
  'height',
  'max-height',
  'min-height',
  'display',
  'table-layout',
  'overflow-wrap',
  'word-break',
  'list-style-type',
};

/// Only a deliberate, confirmed HTTP(S) navigation may leave the mail reader.
/// No relative links, custom schemes, credentials, control characters or
/// backslashes are admitted. Validation is repeated at the point of launch.
Uri? safeMailLink(String? raw) {
  if (raw == null || raw.length > 4096) return null;
  final value = raw.trim();
  if (value.isEmpty ||
      RegExp(r'[\x00-\x20\x7f\\\u202a-\u202e\u2066-\u2069]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  // Reading the port also rejects malformed authorities such as :not-a-port.
  try {
    if (uri.port < 1 || uri.port > 65535) return null;
  } on FormatException {
    return null;
  }
  return uri;
}

String _safeStyles(String raw) {
  final result = <String>[];
  // Intentionally conservative instead of accepting a general CSS grammar.
  // CSS escapes, at-rules, URL functions, variables and comments cannot survive.
  for (final declaration
      in raw.substring(0, raw.length.clamp(0, 8192)).split(';')) {
    final colon = declaration.indexOf(':');
    if (colon < 1) continue;
    var name = declaration.substring(0, colon).trim().toLowerCase();
    final value = declaration.substring(colon + 1).trim();
    if (name == 'background') name = 'background-color';
    if (!_styleProperties.contains(name) ||
        value.isEmpty ||
        value.length > 512 ||
        !RegExp(r'''^[a-zA-Z0-9\s#.,%()+/"'\-]+$''').hasMatch(value) ||
        RegExp(
          r'url|expression|var\s*\(|/\*|\*/',
          caseSensitive: false,
        ).hasMatch(value)) {
      continue;
    }
    if ((value.contains('(') || value.contains(')')) &&
        !RegExp(
          r'^(rgb|rgba|hsl|hsla)\([0-9\s.,%/+\-deg]+\)$',
          caseSensitive: false,
        ).hasMatch(value)) {
      continue;
    }
    // Bound layout sizes, without mistaking a hexadecimal color for a number.
    final numericValue = value.replaceAll(
      RegExp(r'#[0-9a-f]{3,8}\b', caseSensitive: false),
      '',
    );
    if (RegExp(r'\d\s*[eE][+-]?\d').hasMatch(numericValue) ||
        RegExp(r'-?\d+(?:\.\d+)?')
            .allMatches(numericValue)
            .any(
              (match) =>
                  (double.tryParse(match[0]!)?.abs() ?? double.infinity) > 4096,
            )) {
      continue;
    }
    if (name == 'display' &&
        !{
          'block',
          'inline',
          'inline-block',
          'none',
          'table',
          'table-row',
          'table-cell',
          'table-row-group',
        }.contains(value.toLowerCase())) {
      continue;
    }
    result.add('$name:$value');
  }
  return result.join(';');
}

/// The API proxy already re-encodes and bounds raster images. Recheck the
/// envelope and PNG dimensions here before any bytes reach Flutter's decoder.
Uint8List? _proxyPng(String? value) {
  if (value == null ||
      value.length > 5592430 ||
      !RegExp(
        r'^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$',
      ).hasMatch(value)) {
    return null;
  }
  try {
    final bytes = base64Decode(
      value.substring('data:image/png;base64,'.length),
    );
    if (bytes.length < 33 || bytes.length > 4 * 1024 * 1024) return null;
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(8) != 13 || header.getUint32(12) != 0x49484452) {
      return null;
    }
    final width = header.getUint32(16), height = header.getUint32(20);
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 8000000) {
      return null;
    }
    return bytes;
  } on FormatException {
    return null;
  }
}

SanitizedMailHtml sanitizeMailHtml(
  String raw, {
  bool allowImages = false,
  Map<String, String> verifiedImages = const {},
}) {
  // Bound the input before DOM parsing, not merely the output after parsing.
  // The original text alternative remains available in the reader for long mail.
  const maxCharacters = 256 * 1024, maxNodes = 8000, maxDepth = 64;
  var truncated = raw.length > maxCharacters;
  final source = parser.parseFragment(
    raw.substring(0, raw.length.clamp(0, maxCharacters)),
  );
  final output = dom.Element.tag('div');
  final images = <String, Uint8List>{};
  final decoded = <String, Uint8List?>{};
  var nodes = 0, imageBytes = 0, imagePixels = 0;

  void copy(dom.Node node, dom.Node parent, int depth) {
    if (++nodes > maxNodes || depth > maxDepth) {
      truncated = true;
      return;
    }
    if (node is dom.Text) {
      parent.nodes.add(dom.Text(node.data));
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (_dropTags.contains(tag)) return;
    if (!_allowedTags.contains(tag)) {
      for (final child in node.nodes) {
        if (nodes >= maxNodes) {
          truncated = true;
          break;
        }
        copy(child, parent, depth + 1);
      }
      return;
    }
    final element = dom.Element.tag(tag!);
    final css = _safeStyles(node.attributes['style'] ?? '');
    if (css.isNotEmpty) element.attributes['style'] = css;
    for (final attr in ['title', 'alt', 'align', 'valign', 'dir', 'lang']) {
      final value = node.attributes[attr];
      if (value != null) {
        element.attributes[attr] = value.substring(
          0,
          value.length.clamp(0, 2000),
        );
      }
    }
    for (final attr in [
      'width',
      'height',
      'cellpadding',
      'cellspacing',
      'border',
    ]) {
      final value = node.attributes[attr];
      if (value != null &&
          RegExp(r'^\d{1,4}%?$').hasMatch(value) &&
          int.parse(value.replaceAll('%', '')) <= 4096) {
        element.attributes[attr] = value;
      }
    }
    for (final attr in ['colspan', 'rowspan']) {
      final value = int.tryParse(node.attributes[attr] ?? '');
      if (value != null && value > 0 && value <= 100) {
        element.attributes[attr] = '$value';
      }
    }
    for (final attr in ['bgcolor', 'color']) {
      final value = node.attributes[attr];
      if (value != null &&
          RegExp(
            r'^(#[\da-f]{3,8}|[a-z]{1,20})$',
            caseSensitive: false,
          ).hasMatch(value)) {
        element.attributes[attr] = value;
      }
    }
    if (tag == 'a') {
      final href = safeMailLink(node.attributes['href']);
      if (href != null) {
        element.attributes['href'] = href.toString();
        element.attributes['title'] = href.toString();
      }
    }
    if (tag == 'img') {
      final source = (node.attributes['src'] ?? '').trim();
      Uint8List? bytes;
      if (allowImages &&
          images.length < 32 &&
          verifiedImages.containsKey(source)) {
        bytes = decoded.putIfAbsent(
          source,
          () => _proxyPng(verifiedImages[source]),
        );
      }
      final pixels = bytes == null
          ? 0
          : ByteData.sublistView(bytes).getUint32(16) *
                ByteData.sublistView(bytes).getUint32(20);
      if (bytes != null &&
          imageBytes + bytes.length <= 16 * 1024 * 1024 &&
          imagePixels + pixels <= 16000000) {
        final id = '${images.length}';
        images[id] = bytes;
        imageBytes += bytes.length;
        imagePixels += pixels;
        element.attributes['data-harbor-image'] = id;
        // No src, srcset or original URL ever enters the native widget parser.
      } else {
        final placeholder = dom.Element.tag('span')
          ..text = '[${element.attributes['alt'] ?? '图片已阻止'}]'
          ..attributes['style'] = 'color:#687080;background-color:#eef1f5';
        parent.nodes.add(placeholder);
        return;
      }
    }
    for (final child in node.nodes) {
      if (nodes >= maxNodes) {
        truncated = true;
        break;
      }
      copy(child, element, depth + 1);
    }
    parent.nodes.add(element);
  }

  for (final child in source.nodes) {
    if (nodes >= maxNodes) {
      truncated = true;
      break;
    }
    copy(child, output, 0);
  }
  final text = StringBuffer();
  void plain(dom.Node node) {
    if (node is dom.Text) text.write(node.data);
    if (node is dom.Element) {
      final block = _blockTags.contains(node.localName);
      if (block) text.writeln();
      for (final child in node.nodes) {
        plain(child);
      }
      if (block) text.writeln();
      if (node.localName == 'td' || node.localName == 'th') text.write('\t');
      if (node.localName == 'img') {
        text.write('[${node.attributes['alt'] ?? '图片'}]');
      }
    }
  }

  plain(output);
  return SanitizedMailHtml._(
    output.innerHtml,
    text.toString().trim(),
    Map.unmodifiable(images),
    truncated,
  );
}
