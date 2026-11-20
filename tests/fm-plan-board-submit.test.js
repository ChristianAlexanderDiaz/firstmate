const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const queued = [];
const status = { textContent: '' };
const form = {
  dataset: { lavishQuestion: 'decision.one' },
  addEventListener: (_, handler) => { form.submit = handler; },
  querySelector: selector => selector === 'legend' ? { textContent: 'Decision' } : status,
};
let values = {};
vm.runInNewContext(script, {
  document: { querySelectorAll: () => [form] },
  window: { lavish: { queuePrompt: (prompt, context) => queued.push({ prompt, context }) } },
  FormData: class { get(key) { return values[key] || null; } },
  TextEncoder,
});
function submit(answer, note) {
  values = { answer, note };
  form.submit({ preventDefault() {} });
}
submit('reconcile', 'review again');
assert.deepStrictEqual(JSON.parse(JSON.stringify(queued[0].context.data)), {
  schema: 'fm-bearings-answer.v1', question: 'decision.one', selection: 'reconcile', note: 'review again',
});
submit('', 'é'.repeat(256));
assert.strictEqual(queued.length, 2);
submit('', 'é'.repeat(257));
assert.strictEqual(queued.length, 2);
assert.match(status.textContent, /512 bytes maximum/);
submit('pick', 'x'.repeat(505));
assert.strictEqual(queued.length, 3);
submit('pick', 'x'.repeat(506));
assert.strictEqual(queued.length, 3);
assert.match(status.textContent, /512 bytes maximum/);
console.log('ok - generated board queues versioned choices and enforces the answer byte limit');
