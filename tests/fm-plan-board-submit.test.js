const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const vm = require('vm');

// The generated board's first script is its sender: every answer leaves through it.
const html = fs.readFileSync(process.argv[2], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const queued = [];
let sends = 0;
const window = {};
vm.runInNewContext(script, { window, TextEncoder });
const lavish = {
  queuePrompt: (prompt, context) => queued.push({ prompt, context }),
  sendQueuedPrompts: () => { sends += 1; },
};
let title = 'Decision';
function send(answers, target = lavish) {
  return window.fmPlanBoard.send(target, answers.map(([question, selection, note]) => (
    { question, title, selection, note, element: {} })));
}
function checkReader(item, expectedKey, expectedAnswer, expectedLabel) {
  const resultFile = path.join(path.dirname(process.argv[2]), 'submission.toon');
  const prompt = 'Context data: ' + JSON.stringify(item.context.data);
  fs.writeFileSync(resultFile, 'prompts[1]{tag,text,prompt}:\n  ' +
    [item.context.tag, item.context.text, prompt].map(JSON.stringify).join(',') + '\n');
  const result = spawnSync('bash', [process.argv[3], 'answers', resultFile], { encoding: 'utf8' });
  assert.strictEqual(result.status, 0, result.stderr);
  const [key, answer, label] = result.stdout.trimEnd().split('\t');
  assert.strictEqual(key, expectedKey);
  assert.strictEqual(answer, expectedAnswer);
  assert.strictEqual(label, expectedLabel);
}
title = 'Long question '.repeat(100);
assert.strictEqual(send([['decision.one', 'pick', 'review again']]).sent, 1);
assert.deepStrictEqual(JSON.parse(JSON.stringify(queued[0].context.data)), {
  schema: 'fm-bearings-answer.v1', question: 'decision.one', selection: 'pick', note: 'review again',
});
assert.strictEqual(queued[0].context.queueKey, 'decision.one');
assert.strictEqual(sends, 1);
checkReader(queued[0], 'decision.one', 'pick', 'pick - review again');
title = 'Decision';
assert.match(send([['decision.one', '', 'reconcile']]).message, /different words/);
assert.strictEqual(queued.length, 1);
send([['decision.one', 'pick', 'reconcile']]);
assert.strictEqual(queued.length, 2);
checkReader(queued.pop(), 'decision.one', 'pick', 'pick - reconcile');
send([['decision.one', '', 'x'.repeat(512)]]);
assert.strictEqual(queued.length, 2);
checkReader(queued.pop(), 'decision.one', 'x'.repeat(512), 'x'.repeat(512));
send([['decision.one', '', 'é'.repeat(256)]]);
assert.strictEqual(queued.length, 2);
// Verify Unicode at the board boundary; shared reader encoding is outside this board's contract.
assert.strictEqual(queued[1].context.data.note, 'é'.repeat(256));
assert.strictEqual(queued[1].context.text, 'é'.repeat(256));
assert.match(send([['decision.one', '', 'é'.repeat(257)]]).message, /512 bytes maximum/);
assert.strictEqual(queued.length, 2);
send([['decision.one', 'pick', 'x'.repeat(505)]]);
assert.strictEqual(queued.length, 3);
checkReader(queued[2], 'decision.one', 'pick', 'pick - ' + 'x'.repeat(505));
assert.match(send([['decision.one', 'pick', 'x'.repeat(506)]]).message, /512 bytes maximum/);
assert.strictEqual(queued.length, 3);
console.log('ok - generated board queues versioned choices and enforces the answer byte limit');

// One send carries every answer, each under its own key, and a bad answer holds the whole send back.
sends = 0;
const all = send([['direction', 'overview', ''], ['review-length', 'short', ''], ['defaults', '', 'use list price'], ['go', 'go', '']]);
assert.strictEqual(all.sent, 4);
assert.strictEqual(all.message, 'Sent.');
assert.strictEqual(sends, 1);
const batch = queued.slice(3);
assert.deepStrictEqual(batch.map(item => item.context.data.question), ['direction', 'review-length', 'defaults', 'go']);
checkReader(batch[0], 'direction', 'overview', 'overview');
checkReader(batch[2], 'defaults', 'use list price', 'use list price');
checkReader(batch[3], 'go', 'go', 'go');
assert.strictEqual(send([['review-length', 'short', ''], ['rollout', '', 'reconcile']]).sent, 0);
assert.strictEqual(queued.length, 7);
assert.strictEqual(sends, 1);
assert.match(send([]).message, /Pick an answer/);
assert.match(window.fmPlanBoard.send(null, [{ question: 'rollout', title, selection: 'next', note: '', element: {} }]).message, /Preview only/);
assert.match(window.fmPlanBoard.send({}, [{ question: 'rollout', title, selection: 'next', note: '', element: {} }]).message, /Preview only/);
assert.strictEqual(queued.length, 7);
const quiet = { queuePrompt: (prompt, context) => queued.push({ prompt, context }) };
assert.strictEqual(window.fmPlanBoard.send(quiet, [{ question: 'rollout', title, selection: 'next', note: '', element: {} }]).message, 'Queued for sending.');
console.log('ok - one send delivers every answer under its own key, or none when one is refused');
