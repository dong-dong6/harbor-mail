/* Own only internal fragment navigation. Restore history before dirty prompts;
 * rejected Back retains the forward stack rather than pushing a duplicate. */
(() => {
  'use strict';
  let listener, index = 0, restoring = false, applying = false, pending = false;
  let current = location.hash.slice(1) || '/mail';
  let restored, queued, documentProtection;
  const safe = value => typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') && value.length <= 1500 && !/[\x00-\x1f\x7f]/.test(value);
  const state = () => ({ harborRoute: true, index });
  const url = route => location.pathname + location.search + '#' + route;
  const set = (route, replace) => {
    if (!safe(route)) return;
    if (route === current && !replace) {
      if (location.hash === '#' + route && history.state?.harborRoute) return;
      replace = true;
    }
    if (!replace) index++;
    current = route;
    history[replace ? 'replaceState' : 'pushState'](state(), '', url(route));
  };
  addEventListener('popstate', async event => {
    if (!listener) return;
    event.stopImmediatePropagation();
    if (restoring) { restoring = false; restored?.(); restored = undefined; return; }
    if (applying) {
      applying = false;
      if (queued) { const route = queued; queued = undefined; set(route, true); }
      return;
    }
    const targetIndex = event.state?.harborRoute ? event.state.index : index + 1;
    if (!event.state?.harborRoute) history.replaceState({harborRoute:true,index:targetIndex}, '', location.href);
    const target = location.hash.slice(1) || '/mail';
    const delta = targetIndex - index;
    if (!delta) return;
    if (pending) { restoring = true; history.go(-delta); return; }
    pending = true; restoring = true;
    await new Promise(resolve => { restored = resolve; history.go(-delta); });
    let accepted = false;
    try { accepted = safe(target) && await listener(target); } catch (_) {}
    if (accepted) { index = targetIndex; current = target; applying = true; history.go(delta); }
    pending = false;
    if (!accepted && queued) { const route = queued; queued = undefined; set(route, false); }
  }, true);
  addEventListener('beforeunload', event => {
    if (documentProtection?.()) { event.preventDefault(); event.returnValue = ''; }
  });
  window.HarborNavigation = {
    location: () => current,
    listen: callback => {
      listener = callback;
      const old = history.state;
      index = old?.harborRoute && Number.isInteger(old.index) ? old.index : 0;
      current = safe(current) ? current : '/mail';
      history.replaceState(state(), '', url(current));
    },
    write: (route, replace = false) => {
      if (pending || applying) { if (safe(route)) queued = route; }
      else set(route, replace);
    },
    protectDocument: callback => { documentProtection = callback; },
    dispose: () => { listener = undefined; documentProtection = undefined; },
  };
})();
