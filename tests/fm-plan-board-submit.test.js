const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const queued = [];
const status = { textContent: '' };
let title = 'Decision';
const form = {
  dataset: { lavishQuestion: 'decision.one' },
  addEventListener: (_, handler) => { form.submit = handler; },
  querySelector: selector => selector === 'legend' ? { textContent: title } : status,
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
function checkReader(item, expectedAnswer, expectedLabel) {
  const resultFile = path.join(path.dirname(process.argv[2]), 'submission.toon');
  const prompt = 'Context data: ' + JSON.stringify(item.context.data);
  fs.writeFileSync(resultFile, 'prompts[1]{tag,text,prompt}:\n  ' +
    [item.context.tag, item.context.text, prompt].map(JSON.stringify).join(',') + '\n');
  const result = spawnSync('bash', [process.argv[3], 'answers', resultFile], { encoding: 'utf8' });
  assert.strictEqual(result.status, 0, result.stderr);
  const [key, answer, label] = result.stdout.trimEnd().split('\t');
  assert.strictEqual(key, 'decision.one');
  assert.strictEqual(answer, expectedAnswer);
  assert.strictEqual(label, expectedLabel);
}
title = 'Long question '.repeat(100);
submit('pick', 'review again');
assert.deepStrictEqual(JSON.parse(JSON.stringify(queued[0].context.data)), {
  schema: 'fm-bearings-answer.v1', question: 'decision.one', selection: 'pick', note: 'review again',
});
checkReader(queued[0], 'pick', 'pick - review again');
submit('', '  reconcile  ');
assert.strictEqual(queued.length, 1);
assert.match(status.textContent, /different words/);
submit('pick', 'reconcile');
assert.strictEqual(queued.length, 2);
checkReader(queued.pop(), 'pick', 'pick - reconcile');
submit('', 'é'.repeat(256));
assert.strictEqual(queued.length, 2);
checkReader(queued[1], 'é'.repeat(256), 'é'.repeat(256));
submit('', 'é'.repeat(257));
assert.strictEqual(queued.length, 2);
assert.match(status.textContent, /512 bytes maximum/);
submit('pick', 'x'.repeat(505));
assert.strictEqual(queued.length, 3);
checkReader(queued[2], 'pick', 'pick - ' + 'x'.repeat(505));
submit('pick', 'x'.repeat(506));
assert.strictEqual(queued.length, 3);
assert.match(status.textContent, /512 bytes maximum/);
console.log('ok - generated board queues versioned choices and enforces the answer byte limit');
