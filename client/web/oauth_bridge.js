/* OAuth UI notifications only. No credentials or OAuth state enter this channel. */
(() => {
  'use strict';
  const flows = new Map();
  const origin = location.origin;
  const validId = id => /^[a-f0-9]{32}$/.test(id);
  const event = 'harbor-mail-connected';
  const ack = 'harbor-mail-connected-ack';
  function dispose(flow, close) {
    clearTimeout(flow.timer);
    flow.channel?.close();
    window.removeEventListener('message', flow.listener);
    flows.delete(flow.id);
    if (close) { try { flow.popup.close(); } catch (_) {} }
  }
  window.HarborOAuth = {
    prepare(completed) {
      // Called synchronously by the user gesture, before the start HTTP request.
      const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
        x => x.toString(16).padStart(2, '0')).join('');
      const popup = window.open('about:blank', '_blank', 'popup,width=600,height=760');
      if (!popup) return '';
      const flow = { id, popup, completed, channel: null };
      const finish = respond => {
        if (!flows.has(id)) return;
        // The Dart listener closes settings; the existing mailbox refreshes without reload.
        completed(true);
        respond();
        window.focus();
        dispose(flow, false);
      };
      flow.listener = e => {
        if (e.origin !== origin || e.source !== popup ||
            e.data?.type !== event || e.data?.id !== id) return;
        finish(() => popup.postMessage({ type: ack, id }, origin));
      };
      window.addEventListener('message', flow.listener);
      try {
        flow.channel = new BroadcastChannel('harbor-mail-oauth-' + id);
        // BroadcastChannel is inherently same-origin. The random non-auth identifier
        // correlates a single pending UI flow even when a provider severs window.opener.
        flow.channel.onmessage = e => {
          if (e.data === event) finish(() => flow.channel.postMessage(ack));
        };
      } catch (_) { /* postMessage remains available */ }
      flow.timer = setTimeout(() => {
        if (!flows.has(id)) return;
        dispose(flow, false);
        completed(false);
      }, 600000);
      flows.set(id, flow);
      return id;
    },
    open(id, url) {
      const flow = flows.get(id);
      if (!flow) return false;
      try {
        if (new URL(url).protocol !== 'https:') return false;
        flow.popup.location.replace(url);
        return true;
      } catch (_) { return false; }
    },
    cancel(id) {
      const flow = flows.get(id);
      if (flow) dispose(flow, true);
    },
    consumeReturn() {
      if (location.hash !== '#oauth-connected') return false;
      history.replaceState(null, '', location.pathname + location.search);
      return true;
    }
  };

  if (document.documentElement.dataset.oauthComplete !== 'true') return;
  const id = location.hash.slice(1);
  // Remove the correlation marker before any user navigation or copy/paste.
  history.replaceState(null, '', location.pathname);
  let channel, done = false;
  const back = () => location.replace('/#oauth-connected');
  let fallback;
  const accepted = () => {
    if (done) return;
    done = true;
    clearTimeout(fallback);
    channel?.close();
    document.getElementById('status').textContent = '邮箱已连接，原邮箱窗口正在刷新。若本窗口没有自动关闭，可关闭它或点击下方返回。';
    window.close();
  };
  if (validId(id)) {
    window.addEventListener('message', e => {
      if (e.origin === origin && e.source === window.opener &&
          e.data?.type === ack && e.data?.id === id) accepted();
    });
    try {
      channel = new BroadcastChannel('harbor-mail-oauth-' + id);
      channel.onmessage = e => { if (e.data === ack) accepted(); };
      channel.postMessage(event);
    } catch (_) {}
    try { window.opener?.postMessage({ type: event, id }, origin); } catch (_) {}
  }
  fallback = setTimeout(() => {
    channel?.close();
    if (!done) back();
  }, 1500);
})();
