// What an open board does with its live block, run from a board stamped by bin/fm-board-live.sh.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const stamped = html.match(/<script data-fm-board-live="([^"]*)">([\s\S]*?)<\/script>/);
assert.ok(stamped, 'the stamped board carries no live block');
const attribute = stamped[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&');
const config = JSON.parse(attribute);
const READY = { name: config.name, state: 'ready', at: 1795713337, rev: config.rev };
const WORKING = { ...READY, state: 'working' };
const NEWER = { ...READY, rev: config.rev + 1 };
const RELOAD = 'A newer version is ready. Reload this tab to see it.';

function world({ sdk = true, name = '', hidden = false } = {}) {
  let now = 1000000;
  const timers = [];
  const pending = [];
  const probes = [];
  const listeners = {};
  let reloads = 0;
  class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.attributes = {}; this.style = {}; this.textContent = ''; }
    setAttribute(key, value) { this.attributes[key] = value; }
    getAttribute(key) { return this.attributes[key]; }
    attachShadow() { return this; }
    appendChild(child) {
      child.parent = this;
      this.children.push(child);
      if (child.tag === 'script') pending.push(child);
      if (child.tag === 'link') probes.push(child);
      return child;
    }
    remove() { this.parent.children = this.parent.children.filter(child => child !== this); }
  }
  const lavishScript = new Element('script');
  lavishScript.setAttribute('src', '/sdk.js?key=k&artifact_revision=3&artifact_load_token=t');
  const current = new Element('script');
  current.setAttribute('data-fm-board-live', attribute);
  const body = new Element('body');
  const window = { name, innerHeight: 800, location: { reload() { reloads += 1; } } };
  const document = {
    currentScript: current, hidden, body, head: new Element('head'), documentElement: new Element('html'),
    createElement: tag => new Element(tag),
    querySelector: selector => (sdk && selector.includes('sdk.js') ? lavishScript : null),
    addEventListener: (type, handler) => { listeners[type] = handler; },
  };
  vm.runInNewContext(stamped[2], {
    window, document,
    getComputedStyle: () => ({ backgroundColor: 'rgb(18, 26, 24)', color: 'rgb(234, 240, 236)', minHeight: '0px' }),
    setTimeout: (handler, wait) => { const timer = { handler, at: now + wait }; timers.push(timer); return timer; },
    clearTimeout: timer => { if (timers.includes(timer)) timers.splice(timers.indexOf(timer), 1); },
    Date: class extends Date {
      constructor(...values) { if (values.length) super(...values); else super(now); }
      static now() { return now; }
    },
  });
  const line = () => body.children[0] && body.children[0].children[1];
  return {
    window, document, pending, probes, listeners,
    reloads: () => reloads,
    text: () => (line() ? line().children[1].textContent : null),
    mode: () => line().getAttribute('data-mode'),
    advance(wait) {
      const end = now + wait;
      for (;;) {
        const due = timers.filter(timer => timer.at <= end).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers.splice(timers.indexOf(due), 1);
        now = due.at;
        due.handler();
      }
      now = end;
    },
    // Answer the oldest outstanding state-file request the way the board server would.
    serve(payload) {
      const request = pending.shift();
      assert.ok(request, 'the page asked for nothing');
      if (payload) { window.__fmBoardLive(payload); request.onload(); } else request.onerror();
    },
  };
}

const local = new Date(READY.at * 1000);
const clock = [local.getHours(), local.getMinutes()].map(value => String(value).padStart(2, '0')).join(':');

let page = world();
assert.strictEqual(page.pending.length, 1);
assert.ok(page.pending[0].src.startsWith(encodeURIComponent(config.name) + '.live.js?t='), page.pending[0].src);
assert.strictEqual(page.text(), null, 'a line appeared before the board had a recorded state');
page.serve(READY);
assert.strictEqual(page.text(), 'Ready for you, updated ' + clock);
assert.strictEqual(page.mode(), 'ready');
assert.strictEqual(page.document.documentElement.style.paddingTop, '28px', 'the line must not cover board content');
page.advance(1999);
assert.strictEqual(page.pending.length, 0);
page.advance(1);
page.serve(WORKING);
assert.strictEqual(page.text(), 'Working on your changes');
assert.strictEqual(page.mode(), 'working');
page.advance(2000);
page.serve({ ...READY, name: 'another-board.html' });
assert.strictEqual(page.text(), 'Working on your changes', 'another board changed this one');
assert.strictEqual(page.reloads(), 0);
console.log('ok - the open page shows the recorded state and flips without reloading');

// A newer board the page never received: wait out Lavish's own reload, prove
// this page load is still current, then reload the frame exactly once.
page.advance(2000);
page.serve(NEWER);
assert.strictEqual(page.text(), 'Working on your changes', 'an old page claimed the new version was ready');
page.advance(1000);
page.serve(NEWER);
page.advance(1000);
page.serve(NEWER);
assert.strictEqual(page.probes.length, 0, 'the page did not leave Lavish time to reload it');
page.advance(1000);
page.serve(NEWER);
assert.strictEqual(page.probes.length, 1);
assert.ok(page.probes[0].href.startsWith('/sdk.js?key=k&artifact_revision=3&artifact_load_token=t&'), page.probes[0].href);
assert.strictEqual(page.reloads(), 0, 'the page reloaded before proving its load was current');
page.probes[0].onload();
assert.strictEqual(page.reloads(), 1);
assert.strictEqual(page.window.name, 'fm-board-live:' + NEWER.rev);
console.log('ok - a stale page whose load is still current refreshes itself once');

function stale(options) {
  const fresh = world(options);
  fresh.serve(NEWER);
  for (let second = 0; second < 4; second += 1) {
    fresh.advance(1000);
    while (fresh.pending.length) fresh.serve(NEWER);
  }
  return fresh;
}

page = stale({ name: 'fm-board-live:' + NEWER.rev });
assert.strictEqual(page.probes.length, 0);
assert.strictEqual(page.reloads(), 0, 'the page reloaded twice for one version');
assert.strictEqual(page.text(), RELOAD);
assert.strictEqual(page.mode(), 'reload');

page = stale();
page.probes[0].onerror();
assert.strictEqual(page.reloads(), 0, 'a retired page load reloaded into an error page');
assert.strictEqual(page.text(), RELOAD);
page.advance(2000);
page.serve(NEWER);
assert.strictEqual(page.probes.length, 1, 'a refused refresh was retried at once');
page.advance(30000);
while (page.pending.length) page.serve(NEWER);
assert.strictEqual(page.probes.length, 2, 'a refused refresh was never tried again');

page = stale();
page.advance(4000);
assert.strictEqual(page.text(), RELOAD, 'an unanswered check left the page claiming progress');
assert.strictEqual(page.reloads(), 0);

page = stale({ sdk: false });
assert.strictEqual(page.reloads(), 0);
assert.strictEqual(page.text(), RELOAD);

page = stale({ name: 'named-by-the-board' });
assert.strictEqual(page.reloads(), 0, 'the page overwrote a frame name it does not own');
assert.strictEqual(page.text(), RELOAD);
console.log('ok - a page that cannot refresh itself says to reload instead of claiming ready');

page = world();
for (let attempt = 0; attempt < 3; attempt += 1) { page.serve(null); page.advance(15000); }
assert.strictEqual(page.pending.length, 0, 'a copy with no state file kept asking for one');
assert.strictEqual(page.text(), null);

page = world({ hidden: true });
page.serve(READY);
page.advance(14999);
assert.strictEqual(page.pending.length, 0, 'a hidden page kept the visible pace');
page.advance(1);
page.serve(READY);
page.document.hidden = false;
page.listeners.visibilitychange();
assert.strictEqual(page.pending.length, 1, 'returning to the tab did not check at once');
console.log('ok - a copy without a state file goes quiet, and a hidden tab slows down and catches up on return');
