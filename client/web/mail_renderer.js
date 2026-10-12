/* Untrusted mail never enters the application DOM. Parse into an inert template,
 * copy a small allowlist, then display in an opaque-origin, script-free iframe. */
(function () {
  'use strict';
  const tags = new Set('a abbr b blockquote br caption center code col colgroup dd del div dl dt em font h1 h2 h3 h4 h5 h6 hr i img li ol p pre s small span strong sub sup table tbody td th thead tfoot tr u ul'.split(' '));
  const drop = new Set('script style iframe frame frameset object embed svg math form input button textarea select option link meta base template noscript audio video source track'.split(' '));
  const properties = new Set(('background background-color color font font-family font-size font-style font-weight line-height text-align text-decoration text-decoration-line text-decoration-style text-decoration-color text-decoration-thickness text-transform letter-spacing word-spacing white-space vertical-align border border-top border-right border-bottom border-left border-color border-width border-style border-radius border-top-left-radius border-top-right-radius border-bottom-left-radius border-bottom-right-radius border-top-width border-right-width border-bottom-width border-left-width border-top-style border-right-style border-bottom-style border-left-style border-top-color border-right-color border-bottom-color border-left-color border-collapse border-spacing padding padding-top padding-right padding-bottom padding-left margin margin-top margin-right margin-bottom margin-left width max-width min-width height max-height min-height display table-layout overflow overflow-x overflow-y overflow-wrap word-break list-style-type').split(' '));
  function safeUrl(raw) {
    try {
      const u = new URL(raw);
      if (!['https:', 'http:', 'mailto:'].includes(u.protocol) || u.username || u.password) return null;
      return u.href;
    } catch (_) { return null; }
  }
  function styles(raw) {
    const probe = document.createElement('span');
    probe.style.cssText = raw;
    const result = [];
    // Chromium expands indexed CSSOM entries into longhands (unlike jsdom).
    // Read the supported properties by name, including longhands, so shorthand
    // border radius/width/style/color survives consistently across engines.
    for (const name of properties) {
      const value = probe.style.getPropertyValue(name);
      if (!value) continue;
      // No URLs, escapes, custom variables or executable/unknown functions.
      if (!properties.has(name) || /[\\@<>]|url\s*\(|expression|var\s*\(/i.test(value)) continue;
      if (/([a-z-]+)\s*\(/ig.test(value) && !/^(rgba?|hsla?)\([\d\s.,%/+\-deg]+\)$/i.test(value)) continue;
      result.push(name + ':' + value);
    }
    return result.join(';');
  }
  function render(raw, allowImages, verifiedImages) {
    // Only the trusted host supplies these raster data URLs, after bearer-authenticated
    // proxy requests. A boolean opt-in alone can never enable origin requests.
    let images = Object.create(null);
    try {
      const value = typeof verifiedImages === 'string' ? JSON.parse(verifiedImages) : verifiedImages;
      if (value && typeof value === 'object' && !Array.isArray(value)) images = value;
    } catch (_) { /* fail closed */ }
    let imagePlacements = 0, imageDataCharacters = 0;
    function verifiedRaster(source) {
      if (!Object.prototype.hasOwnProperty.call(images, source)) return null;
      const value = images[source];
      if (typeof value !== 'string' || value.length > 5592430 || imagePlacements >= 32 ||
          imageDataCharacters + value.length > 22370336 ||
          !/^data:image\/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$/.test(value)) return null;
      // Repeated references must spend the budget too: one 4 MiB response must
      // never turn thousands of duplicate <img> tags into gigabytes of srcdoc.
      imagePlacements++;
      imageDataCharacters += value.length;
      return value;
    }
    const source = document.createElement('template');
    source.innerHTML = String(raw).slice(0, 2097152);
    const inert = source.content.ownerDocument;
    const output = inert.createElement('div');
    let nodes = 0;
    function copy(node, parent, depth) {
      if (++nodes > 40000 || depth > 100) return;
      if (node.nodeType === Node.TEXT_NODE) { parent.appendChild(inert.createTextNode(node.data)); return; }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const tag = node.localName.toLowerCase();
      if (drop.has(tag)) return;
      if (!tags.has(tag)) { for (const child of node.childNodes) copy(child, parent, depth + 1); return; }
      const el = inert.createElement(tag);
      const css = styles(node.getAttribute('style') || '');
      if (css) el.setAttribute('style', css);
      for (const attr of ['title', 'alt', 'align', 'valign', 'dir', 'lang']) {
        if (node.hasAttribute(attr)) el.setAttribute(attr, node.getAttribute(attr).slice(0, 2000));
      }
      for (const attr of ['width', 'height', 'colspan', 'rowspan', 'cellpadding', 'cellspacing', 'border']) {
        const val = node.getAttribute(attr);
        if (val && /^\d{1,4}%?$/.test(val)) el.setAttribute(attr, val);
      }
      for (const attr of ['bgcolor', 'color']) {
        const val = node.getAttribute(attr);
        if (val && /^(#[\da-f]{3,8}|[a-z]{1,20})$/i.test(val)) el.setAttribute(attr, val);
      }
      if (tag === 'a') {
        const href = safeUrl(node.getAttribute('href'));
        if (href) { el.href = href; el.target = '_blank'; el.rel = 'noopener noreferrer'; el.title = href; }
      }
      if (tag === 'img') {
        const source = (node.getAttribute('src') || '').trim();
        const src = allowImages ? verifiedRaster(source) : null;
        if (src) {
          el.setAttribute('referrerpolicy', 'no-referrer'); el.setAttribute('src', src);
        } else {
          const placeholder = inert.createElement('span');
          placeholder.textContent = '[' + (node.getAttribute('alt') || '图片已阻止') + ']';
          placeholder.setAttribute('style', 'display:inline-block;padding:12px;color:#687080;background-color:#eef1f5;border-radius:6px');
          parent.appendChild(placeholder); return;
        }
      }
      for (const child of node.childNodes) copy(child, el, depth + 1);
      parent.appendChild(el);
    }
    for (const child of source.content.childNodes) copy(child, output, 0);
    const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src " + (allowImages ? 'data:' : "'none'") + "; font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";
    return '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="' + csp + '"><meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;padding:0;background:#fff;color:#202124;font:15px/1.6 Arial,sans-serif}body{padding:8px;overflow-wrap:anywhere}*{box-sizing:border-box}img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}a{color:#0b57d0}#mail-content{overflow-x:auto;max-width:100%}</style></head><body><div id="mail-content">' + output.innerHTML + '</div></body></html>';
  }
  window.harborRenderMail = render;
}());
