#!/usr/bin/env bash
# Public-interface plan-board validation, rendered structure, and pre-show lint.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-plan-board)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import copy
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
command = ['bash', str(root / 'bin/fm-plan-board.sh')]
sample = json.loads((root / 'tests/assets/plan-board-sample.json').read_text())
payload = scratch / 'payload.json'
board = scratch / 'board.html'


def run(args, expected=None):
    result = subprocess.run(command + list(map(str, args)), capture_output=True, text=True)
    if expected is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0, f'accepted bad input: {expected}'
        assert expected in result.stderr, result.stderr
    return result.stdout


def build(data, expected=None):
    payload.write_text(json.dumps(data))
    return run(['build', payload, board], expected)


build(sample)
original = board.read_text()
run(['lint', board])


class Inspect(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))

    def handle_data(self, text):
        self.text.append(text)


parsed = Inspect()
parsed.feed(original)
assert len([1 for tag, attrs in parsed.tags if tag == 'textarea' and attrs.get('name') == 'note']) == 2
assert len([1 for tag, attrs in parsed.tags if tag == 'input' and attrs.get('type') == 'radio']) == 4
assert not any('checked' in attrs for tag, attrs in parsed.tags if tag == 'input')
assert len([1 for tag, attrs in parsed.tags if attrs.get('class') == 'recommended']) == 2
assert all('open' not in attrs for tag, attrs in parsed.tags if tag == 'details')
assert sample['title'] in parsed.text and sample['tldr'] in parsed.text
print('ok - valid payload renders decisions, recommendations, free text and collapsed detail')

for key in sample:
    bad = copy.deepcopy(sample)
    del bad[key]
    build(bad, 'missing or unexpected fields')
for key in sample['decisions'][0]:
    bad = copy.deepcopy(sample)
    del bad['decisions'][0][key]
    build(bad, 'missing or unexpected fields')
for key in sample['decisions'][0]['options'][0]:
    bad = copy.deepcopy(sample)
    del bad['decisions'][0]['options'][0][key]
    build(bad, 'missing or unexpected fields')
assert board.read_text() == original
print('ok - missing fields refuse without replacing the existing board')

cases = [
    ('schema', 'wrong', 'unsupported schema'),
    ('title', '  ', 'nonblank text'),
    ('decisions', {}, 'nonempty list'),
    ('builder_detail', 1, 'nonblank text'),
]
for field, value, expected in cases:
    bad = copy.deepcopy(sample)
    bad[field] = value
    build(bad, expected)
for mutate, expected in [
    (lambda d: d.update(recommended='absent'), 'must match an option'),
    (lambda d: d['options'][1].update(value='reconcile'), 'option value reconcile is reserved'),
    (lambda d: d.update(options=d['options'][:1]), 'at least two options'),
    (lambda d: d['options'][1].update(value=d['options'][0]['value']), 'duplicate option'),
    (lambda d: d.update(key='bad key'), 'invalid identifier'),
    (lambda d: d.update(question=None), 'nonblank text'),
]:
    bad = copy.deepcopy(sample)
    mutate(bad['decisions'][0])
    build(bad, expected)
bad = copy.deepcopy(sample)
bad['decisions'][0]['options'][0]['value'] = 'reconcile'
bad['decisions'][0]['recommended'] = 'reconcile'
build(bad, 'option value reconcile is reserved')
bad = copy.deepcopy(sample)
bad['decisions'].append(bad['decisions'][0])
build(bad, 'duplicate decision')
payload.write_text('{')
run(['build', payload, board], 'fm-plan-board:')
print('ok - malformed and inconsistent payloads refuse')

for content, expected in [
    (original.replace('<main>', '<main><p>Read this first.</p>'), 'TL;DR must be the first block'),
    (original.replace('<main>', '<main>Read this first.'), 'TL;DR must be the first block'),
    (original.replace('id="tldr"', 'id="overview"'), 'TL;DR must be the first block'),
    (original.replace('>TL;DR<', '>Overview<'), 'TL;DR must be the first text'),
    (original.replace('id="builder-detail"', 'id="builder-detail" open'), 'must start collapsed'),
    (original.replace(sample['tldr'], 'word ' * 401), 'maximum is 400'),
    (original.replace(sample['tldr'], 'Review the JSON.'), 'code words above the fold'),
    (original.replace(sample['tldr'], '<code>value</code>'), 'code markup above the fold'),
]:
    board.write_text(content)
    run(['lint', board], expected)
for phrase in ('Use --verbose.', 'Read bin/worker.sh.', 'Change the task_id.', 'Use queuePrompt.', 'Set `value`.', 'Use the backend.'):
    bad = copy.deepcopy(sample)
    bad['tldr'] = phrase
    build(bad, 'code words above the fold')
print('ok - every pre-show lint rule refuses its bad case')

# The exact word budget includes template labels, option text and summary.
build(sample)
count = int(run(['lint', board]).split('(')[1].split()[0])
base = len(sample['tldr'].split())
bad = copy.deepcopy(sample)
bad['tldr'] = ' '.join(['word'] * (400 - count + base))
assert '(400 visible words)' in build(bad)
bad['tldr'] += ' extra'
build(bad, 'maximum is 400')
print('ok - exactly 400 visible words pass; 401 refuse')

safe = copy.deepcopy(sample)
safe['builder_detail'] = '</div><script>alert("unsafe")</script>\n' + 'JSON schema task_id ' * 500
build(safe)
parsed = Inspect()
parsed.feed(board.read_text())
assert safe['builder_detail'] in parsed.text
# The template's own script and the stamped live block are the only scripts.
assert [attrs.get('data-fm-board-live') is not None for tag, attrs in parsed.tags if tag == 'script'] == [False, True]
assert not any(tag == 'img' for tag, _ in parsed.tags)
print('ok - builder detail stays escaped and outside the visible word budget')
PY
if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/fm-plan-board-submit.test.js" "$TMP_ROOT/board.html" "$ROOT/bin/fm-procevent-lavish.sh"
else
  printf '%s\n' 'skip - generated board submission requires node'
fi
