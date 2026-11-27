// Board live line. bin/fm-board-live.sh owns the contract and stamps this file into a board.
(function () {
  'use strict';
  var script = document.currentScript;
  var config;
  try { config = JSON.parse(script.getAttribute('data-fm-board-live')); } catch (error) { return; }
  if (!config || window.__fmBoardLive) return;

  var VISIBLE_MS = 2000, HIDDEN_MS = 15000, GRACE_MS = 3000, PROBE_MS = 4000, RETRY_MS = 30000, HEIGHT = 28;
  var MARK = 'fm-board-live:';
  var latest = null, newerSince = 0, cannotRefresh = false, probing = false, probedAt = 0;
  var failures = 0, everLoaded = false, timer = null, line = null, label = null;

  function pad(value) { return (value < 10 ? '0' : '') + value; }

  function text() {
    if (!latest) return '';
    if (latest.rev > config.rev) {
      return cannotRefresh ? 'A newer version is ready. Reload this tab to see it.' : 'Working on your changes';
    }
    if (latest.state !== 'ready') return 'Working on your changes';
    var at = new Date(latest.at * 1000);
    return 'Ready for you, updated ' + pad(at.getHours()) + ':' + pad(at.getMinutes());
  }

  function mode() {
    if (latest.rev > config.rev) return cannotRefresh ? 'reload' : 'working';
    return latest.state === 'ready' ? 'ready' : 'working';
  }

  function opaque(color) { return color && color !== 'transparent' && !/,\s*0\)$/.test(color); }

  function build() {
    var root = document.documentElement, body = document.body;
    var host = document.createElement('div');
    host.id = 'fm-board-live';
    var shadow = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
    var bodyStyle = getComputedStyle(body), rootStyle = getComputedStyle(root);
    var background = opaque(bodyStyle.backgroundColor) ? bodyStyle.backgroundColor
      : opaque(rootStyle.backgroundColor) ? rootStyle.backgroundColor : 'Canvas';
    var style = document.createElement('style');
    style.textContent =
      '.line{position:fixed;top:0;left:0;right:0;z-index:2147483000;box-sizing:border-box;height:' + HEIGHT + 'px;' +
      'display:flex;align-items:center;gap:8px;padding:0 16px;margin:0;background:' + background + ';color:' + bodyStyle.color + ';' +
      'font:500 13px/1 system-ui,-apple-system,"Segoe UI",sans-serif;letter-spacing:0;white-space:nowrap;overflow:hidden;' +
      'border-bottom:1px solid rgba(128,128,128,.28)}' +
      '.dot{flex:none;width:8px;height:8px;border-radius:50%;background:#d98a1f}' +
      '.label{overflow:hidden;text-overflow:ellipsis}' +
      '[data-mode=ready] .dot{background:#2e9e62}' +
      '[data-mode=reload] .dot{background:#c2452d}' +
      '[data-mode=working] .dot{animation:fm-board-live-pulse 1.4s ease-in-out infinite}' +
      '@keyframes fm-board-live-pulse{50%{opacity:.3}}' +
      '@media (prefers-reduced-motion:reduce){[data-mode=working] .dot{animation:none}}';
    line = document.createElement('div');
    line.className = 'line';
    line.setAttribute('role', 'status');
    line.setAttribute('aria-live', 'polite');
    var dot = document.createElement('span');
    dot.className = 'dot';
    label = document.createElement('span');
    label.className = 'label';
    line.appendChild(dot);
    line.appendChild(label);
    shadow.appendChild(style);
    shadow.appendChild(line);
    // Reserve the line's height on the root so it never covers board content,
    // and keep full-height boards from gaining a scrollbar because of it.
    root.style.boxSizing = 'border-box';
    root.style.paddingTop = HEIGHT + 'px';
    root.style.scrollPaddingTop = HEIGHT + 'px';
    if (Math.abs(parseFloat(bodyStyle.minHeight) - window.innerHeight) <= 1) {
      body.style.minHeight = 'calc(100vh - ' + HEIGHT + 'px)';
    }
    body.appendChild(host);
  }

  function render() {
    if (!latest || !document.body) return;
    if (!line) build();
    var next = text();
    if (label.textContent !== next) label.textContent = next;
    line.setAttribute('data-mode', mode());
  }

  // The board frame cannot read its own address through fetch, so a preload of
  // the script Lavish already added tells whether this page load is still the
  // current one: only then does reloading the frame return the new board.
  function refresh() {
    var marker = MARK + latest.rev;
    var sdk = document.querySelector('script[src*="/sdk.js?"]');
    var foreignName = window.name && window.name.indexOf(MARK) !== 0;
    if (!sdk || foreignName || window.name === marker) { cannotRefresh = true; render(); return; }
    probing = true;
    probedAt = Date.now();
    var probe = document.createElement('link');
    var settled = false;
    function settle(current) {
      if (settled) return;
      settled = true;
      probing = false;
      probe.remove();
      if (!current) { cannotRefresh = true; render(); return; }
      window.name = marker;
      window.location.reload();
    }
    probe.rel = 'preload';
    probe.as = 'script';
    probe.href = sdk.getAttribute('src') + '&fm_board_live=' + Date.now();
    probe.onload = function () { settle(true); };
    probe.onerror = function () { settle(false); };
    setTimeout(function () { settle(false); }, PROBE_MS);
    document.head.appendChild(probe);
  }

  window.__fmBoardLive = function (payload) {
    if (!payload || payload.name !== config.name) return;
    everLoaded = true;
    failures = 0;
    latest = payload;
    if (payload.rev > config.rev) {
      var now = Date.now();
      if (!newerSince) newerSince = now;
      else if (!probing && now - newerSince >= GRACE_MS && (!cannotRefresh || now - probedAt >= RETRY_MS)) refresh();
    } else {
      newerSince = 0;
      cannotRefresh = false;
    }
    render();
  };

  function schedule() {
    clearTimeout(timer);
    // A copy opened away from its board has no state file: stop asking.
    if (!everLoaded && failures >= 3) return;
    var wait = document.hidden ? HIDDEN_MS : newerSince && !cannotRefresh ? 1000 : VISIBLE_MS;
    timer = setTimeout(poll, wait);
  }

  function poll() {
    clearTimeout(timer);
    var request = document.createElement('script');
    request.src = encodeURIComponent(config.name) + '.live.js?t=' + Date.now();
    request.onload = function () { request.remove(); schedule(); };
    request.onerror = function () { failures += 1; request.remove(); schedule(); };
    document.head.appendChild(request);
  }

  document.addEventListener('visibilitychange', function () { if (!document.hidden) poll(); });
  poll();
})();
