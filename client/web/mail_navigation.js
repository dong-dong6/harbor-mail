/* Own internal fragment navigation. Restore committed history before dirty
 * prompts. The browser's temporary hash is never an application acceptance. */
(() => {
  'use strict';
  let listener, index = 0, restoring = false, applying = false, pending = false;
  let current = location.hash.slice(1) || '/mail';
  let queued, documentProtection;
  let restoreWaiters = [];
  const safe = value => typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') && value.length <= 1500 && !/[\x00-\x1f\x7f]/.test(value);
  const owned = value => value?.harborRoute === true && Number.isInteger(value.index);
  const state = () => ({ harborRoute: true, index, route: current });
  const url = route => location.pathname + location.search + '#' + route;
  const position = () => owned(history.state) ? history.state.index : index;
  const set = (route, replace) => {
    if (!safe(route)) return;
    if (route === current && !replace) {
      if (location.hash === '#' + route && owned(history.state)) return;
      replace = true;
    }
    if (!replace) index++;
    current = route;
    history[replace ? 'replaceState' : 'pushState'](state(), '', url(route));
  };
  const driveRestore = () => {
    const delta = index - position();
    if (delta) { history.go(delta); return; }
    restoring = false;
    const waiters = restoreWaiters; restoreWaiters = [];
    for (const resolve of waiters) resolve();
  };
  const restoreCommitted = () => new Promise(resolve => {
    restoreWaiters.push(resolve); restoring = true; driveRestore();
  });
  const finishApply = () => {
    applying = false;
    if (queued) { const route = queued; queued = undefined; set(route, true); }
  };
  addEventListener('popstate', async event => {
    if (!listener) return;
    event.stopImmediatePropagation();
    // Rapid traversals can queue events whose entry is no longer current.
    // Never read the new entry's hash as the stale event's destination.
    if (owned(event.state) && owned(history.state) && event.state.index !== history.state.index) return;
    const targetIndex = owned(event.state) ? event.state.index : index + 1;
    const target = safe(event.state?.route) ? event.state.route : location.hash.slice(1) || '/mail';
    if (!owned(event.state)) history.replaceState({harborRoute:true,index:targetIndex,route:target}, '', location.href);
    if (restoring) { driveRestore(); return; }
    if (applying) {
      if (position() === index) finishApply();
      else history.go(index - position());
      return;
    }
    if (targetIndex === index) return;
    if (pending) { void restoreCommitted(); return; }
    pending = true;
    await restoreCommitted();
    let accepted = false;
    try { accepted = safe(target) && await listener(target); } catch (_) {}
    // A repeated Back during the asynchronous guard may still be restoring.
    await restoreCommitted();
    if (accepted) {
      index = targetIndex; current = target; applying = true;
      if (position() === index) finishApply();
      else history.go(index - position());
    }
    pending = false;
    if (!accepted && queued) { const route = queued; queued = undefined; set(route, false); }
  }, true);
  addEventListener('beforeunload', event => {
    if (documentProtection?.()) { event.preventDefault(); event.returnValue = ''; }
  });
  window.HarborNavigation = {
    location: () => current,
    // Read-only navigation state, useful for accessibility/tests and diagnostics.
    // Contains no mail content, account credentials or authentication data.
    status: () => ({location:current,index,settled:!pending&&!restoring&&!applying,pending,restoring,applying}),
    listen: callback => {
      listener = callback;
      const old = history.state;
      index = owned(old) ? old.index : 0;
      current = safe(current) ? current : '/mail';
      history.replaceState(state(), '', url(current));
    },
    write: (route, replace = false) => {
      if (pending || restoring || applying) { if (safe(route)) queued = route; }
      else set(route, replace);
    },
    protectDocument: callback => { documentProtection = callback; },
    dispose: () => { listener = undefined; documentProtection = undefined; },
  };
})();
