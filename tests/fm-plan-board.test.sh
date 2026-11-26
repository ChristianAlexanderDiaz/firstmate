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


def changed(mutate):
    data = copy.deepcopy(sample)
    mutate(data)
    return data


class Inspect(HTMLParser):
    voids = {'meta', 'input', 'rect', 'line', 'circle', 'path'}

    def __init__(self):
        super().__init__()
        self.tags = []
        self.text = []
        self.stack = []
        self.unshown = []
        self.labelled = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag not in self.voids:
            self.stack.append((tag, attrs))

    def handle_endtag(self, tag):
        if tag not in self.voids:
            self.stack.pop()

    def handle_data(self, text):
        self.text.append(text)
        if any('hidden' in attrs for _, attrs in self.stack):
            self.unshown.append(text)
        if any(tag == 'label' for tag, _ in self.stack):
            self.labelled.append(text)

    def having(self, tag, **wanted):
        return [attrs for name, attrs in self.tags
                if name == tag and all(attrs.get(key.replace('_', '-')) == value for key, value in wanted.items())]


def inspect():
    parsed = Inspect()
    parsed.feed(board.read_text())
    return parsed


build(sample)
original = board.read_text()
run(['lint', board])
parsed = inspect()
plan = sample['plans'][0]
assert ''.join(parsed.text).count('TOOL-1: make the next choice easier') == 2  # the page title and the heading
assert sample['tldr'] in parsed.text and plan['seen'] in ' '.join(parsed.text)
assert len(parsed.having('input', type='radio')) == 4
assert not any('checked' in attrs for tag, attrs in parsed.tags if tag == 'input')
assert len([1 for attrs in parsed.having('input', type='radio') if 'data-rec' in attrs]) == 2
assert len(parsed.having('span', **{'class': 'bd-rec'})) == 2
assert [attrs['data-lavish-question'] for attrs in parsed.having('fieldset')] == ['review-length', 'rollout']
assert len(parsed.having('div', data_lavish_question='defaults')) == 1
boxes = parsed.having('textarea', **{'class': 'bd-write-box'})
assert len(boxes) == 3 and all('hidden' in attrs for attrs in boxes)
assert [1 for attrs in parsed.having('details') if 'open' not in attrs and attrs['id'] == 'builder-detail'] == [1]
print('ok - valid payload renders the ticket, questions, recommendations, free text and collapsed detail')

words = ' '.join(parsed.text)
assert all(lead in words for lead in ('First,', 'Then,', 'Last,', 'When it is done,'))
details = parsed.having('p', **{'class': 'bd-step-detail'})
assert len(details) == 3 and all('hidden' in attrs for attrs in details)
assert plan['steps'][1]['does'] in parsed.unshown and plan['steps'][1]['say'] not in parsed.unshown
recommended = plan['questions'][0]['options'][0]
assert recommended['say'] in parsed.text and recommended['does'] in parsed.unshown
assert plan['questions'][0]['options'][1]['say'] not in parsed.text
print('ok - the story reads in order with plain sentences shown and technical wording behind closed details')

assert parsed.having('html')[0].get('data-lavish-annotate') == 'on'
for option in plan['questions'][0]['options']:
    assert option['label'] in parsed.text and option['label'] not in parsed.labelled
    assert option['detail'] not in parsed.labelled
print('ok - option words sit outside the pick control so a note can land on them')

for key in ('schema', 'ticket', 'title', 'tldr', 'plans', 'builder_detail'):
    build(changed(lambda d: d.pop(key)), 'missing or unexpected fields')
for key in plan:
    build(changed(lambda d: d['plans'][0].pop(key)), 'missing or unexpected fields')
for key in plan['questions'][0]:
    build(changed(lambda d: d['plans'][0]['questions'][0].pop(key)), 'missing or unexpected fields')
for key in plan['questions'][0]['options'][0]:
    build(changed(lambda d: d['plans'][0]['questions'][0]['options'][0].pop(key)), 'missing or unexpected fields')
for key in plan['steps'][1]:
    build(changed(lambda d: d['plans'][0]['steps'][1].pop(key)), 'missing or unexpected fields')
build(changed(lambda d: d.update(extra='x')), 'missing or unexpected fields')
build(changed(lambda d: d['plans'][0].update(name='A direction')), 'missing or unexpected fields')
assert board.read_text() == original
print('ok - missing and unexpected fields refuse without replacing the existing board')

for key in ('words', 'picture', 'defaults'):
    build(changed(lambda d: d.pop(key)))
build(changed(lambda d: d['picture'].pop('facts')))
build(changed(lambda d: d['picture']['bars'][0].update(share=1.5)), 'bar share')
build(changed(lambda d: d['picture'].update(bars=d['picture']['bars'][:1])), 'bars: 2 to 4')
build(changed(lambda d: d['picture'].pop('kind')), 'picture kind must be one of')
build(changed(lambda d: d['picture'].update(kind='poster')), 'picture kind must be one of')
for kind in ('before-after', 'flow', 'timeline', 'screenshot'):
    build(changed(lambda d: d['picture'].update(kind=kind)), 'in the spec but not drawn yet')
build(sample)
frames = inspect().having('div', **{'class': 'bd-frame'})
assert [frame.get('data-kind') for frame in frames] == ['comparison'] and 'style' not in frames[0]
build(changed(lambda d: d.update(defaults=[d['defaults'][0]] * 9)), 'defaults: at most 8')
print('ok - his words, the picture and the defaults are optional and still checked; the picture is a known kind in the fixed frame')

for field, value, expected in [
    ('schema', 'fm-plan-board.v1', 'unsupported schema'),
    ('ticket', 'tool-1', 'an id such as TOOL-112'),
    ('title', '  ', 'nonblank text'),
    ('plans', [], 'plans: 1 to 3'),
    ('builder_detail', 1, 'nonblank text'),
]:
    build(changed(lambda d: d.update({field: value})), expected)
for mutate, expected in [
    (lambda q: q.update(recommended='absent'), 'must match an option'),
    (lambda q: q['options'][1].update(value='reconcile'), 'option value reconcile is reserved'),
    (lambda q: q.update(options=q['options'][:1]), 'at least two options'),
    (lambda q: q['options'][1].update(value=q['options'][0]['value']), 'duplicate option'),
    (lambda q: q.update(key='bad key'), 'invalid identifier'),
    (lambda q: q.update(key='go'), 'question key go is reserved'),
    (lambda q: q.update(question=None), 'nonblank text'),
]:
    build(changed(lambda d: mutate(d['plans'][0]['questions'][0])), expected)
build(changed(lambda d: d['plans'][0]['questions'].append(d['plans'][0]['questions'][0])), 'duplicate question')
build(changed(lambda d: d['plans'][0]['steps'][0].update(question='absent')), 'unknown question')
build(changed(lambda d: d['plans'][0]['steps'].pop(0)), 'exactly one step')
build(changed(lambda d: d['plans'][0]['steps'].append({'question': 'rollout'})), 'exactly one step')
build(changed(lambda d: d['plans'][0].update(steps=d['plans'][0]['steps'] + [d['plans'][0]['steps'][1]] * 10)), 'steps: 1 to 12')
build(changed(lambda d: d['plans'][0].update(risk=[])), 'risk: 1 to 3')
payload.write_text('{')
run(['build', payload, board], 'fm-plan-board:')
print('ok - malformed and inconsistent payloads refuse')


def step(text):
    return changed(lambda d: d['plans'][0]['steps'][1].update(say=text))


for data, expected in [
    (changed(lambda d: d.update(tldr='Reviews are slow. Say go and they get shorter.')), 'the ticket at a glance'),
    (changed(lambda d: d.update(tldr='word ' * 61 + '.')), 'plain words: tldr'),
    (step('it opens a PR for the page.'), 'plain words: step say uses PR'),
    (step('it changes the page. It then checks it.'), 'must be one sentence'),
    (step('it ' + 'really ' * 24 + 'changes the page.'), 'over 24 words'),
    (step('then it changes the page.'), 'starts with an order word'),
    (step('it changes the notes/page file.'), 'names a file'),
    (changed(lambda d: d['plans'][0].update(seen='you will see the JSON.')), 'plain words: seen uses JSON'),
    (changed(lambda d: d['plans'][0]['risk'].__setitem__(0, 'The merge can fail.')), 'plain words: first risk uses merge'),
    (changed(lambda d: d['plans'][0]['questions'][0]['options'][0].update(say='the worker edits the schema.')), 'plain words: option say'),
]:
    build(data, expected)
build(changed(lambda d: d['plans'][0]['steps'][1].update(does='Run bin/worker.sh --verbose with task_id via queuePrompt')))
build(changed(lambda d: d['plans'][0]['risk'].__setitem__(1, 'One PR per review, checked in CI.')))
print('ok - the story, the glance and the first risk are held to plain words; details may be technical')


def directions(data):
    first = data['plans'][0]
    second = copy.deepcopy(first)
    first.update(key='overview', name='Overview first', story='Each review opens short. The rest is one tap away.',
                 cost='Old reviews keep the long form.', recommended=True,
                 why='The last five reviews ran to 640 words before the first choice.')
    second.update(key='rewrite', name='Rewrite every review', story='Every open review is written again in the new form.',
                  cost='The most work before you see anything.')
    second['steps'] = [{'say': 'the worker writes every open review again.', 'does': 'Regenerate each open review'}]
    second['questions'] = []
    second['risk'] = ['A review you already read can change under you.']
    data['plans'].append(second)


def same_shape(data):
    twin = copy.deepcopy(data['plans'][0])
    twin.update(key='same', name='The same again')
    del twin['recommended'], twin['why']
    data['plans'][1] = twin


build(changed(directions))
parsed = inspect()
ways = parsed.having('input', type='radio', name='direction')
assert [attrs['value'] for attrs in ways] == ['overview', 'rewrite'] and ['data-rec' in attrs for attrs in ways] == [True, False]
assert [attrs['data-lavish-question'] for attrs in parsed.having('fieldset')] == ['direction', 'review-length', 'rollout']
plans = parsed.having('section', **{'class': 'bd-part bd-plan'})
assert [(attrs['data-way'], 'hidden' in attrs) for attrs in plans] == [('overview', False), ('rewrite', True)]
assert 'the worker writes every open review again.' in parsed.unshown
assert 'Which direction?' in parsed.text and 'Why Overview first' in parsed.text
assert len(parsed.having('span', **{'class': 'bd-rec'})) == 3
run(['lint', board])
for mutate, expected in [
    (lambda d: d['plans'][1].update(recommended=True, why='It is also good.'), 'at most one direction is recommended'),
    (lambda d: d['plans'][0].pop('why'), 'says why'),
    (lambda d: d['plans'][1].update(why='It is good.'), 'says why'),
    (lambda d: d['plans'][1].pop('name'), 'missing or unexpected fields'),
    (lambda d: d['plans'][1].update(key='overview'), 'duplicate plan key'),
    (lambda d: d['plans'][1].update(cost='It needs one PR.'), 'plain words: plan cost uses PR'),
    (same_shape, 'differ in shape'),
    (lambda d: d['plans'].extend([d['plans'][1]] * 2), 'plans: 1 to 3'),
]:
    data = changed(directions)
    mutate(data)
    build(data, expected)
print('ok - two or three directions render side by side, swap whole plans, and refuse look-alikes and equal recommendations')

empty = changed(lambda d: d['plans'][0].update(questions=[], steps=[d['plans'][0]['steps'][1]]))
build(empty)
parsed = inspect()
assert 'Nothing to decide, say go.' in parsed.text and not parsed.having('fieldset')
assert len(parsed.having('div', data_lavish_question='go')) == 1
print('ok - a board with no questions says so and still sends an explicit go')

build(changed(lambda d: d['plans'][0]['questions'][0].update(picked='full')))
parsed = inspect()
checked = [attrs for attrs in parsed.having('input', type='radio') if 'checked' in attrs]
assert [(attrs['name'], attrs['value']) for attrs in checked] == [('review-length', 'full')]
assert plan['questions'][0]['options'][1]['say'] in parsed.text
assert plan['questions'][0]['options'][0]['say'] not in parsed.text
build(changed(lambda d: d['plans'][0]['questions'][0].update(picked='absent')), 'picked answer must match an option')
print('ok - a pick he already made opens picked and tells its step that way')

build(sample)
for content, expected in [
    (original.replace('<section id="tldr"', '<p>Read this first.</p><section id="tldr"'), 'TL;DR must be the first block'),
    (original.replace('<section id="tldr"', 'Read this first.<section id="tldr"'), 'TL;DR must be the first block'),
    (original.replace('id="tldr"', 'id="overview"'), 'TL;DR must be the first block'),
    (original.replace('<title>TOOL-1: ', '<title>'), 'page title must read TICKET: title'),
    (original.replace('<span class="bd-id">TOOL-1:</span>', '<span class="bd-id">TOOL-2:</span>'), 'heading must repeat the page title'),
    (original.replace('id="builder-detail"', 'id="builder-detail" open'), 'must start collapsed'),
    (original.replace(sample['tldr'], 'Review the JSON.'), 'code words above the fold'),
    (original.replace(sample['tldr'], '<code>value</code>'), 'code markup above the fold'),
    (original.replace('data-kind="comparison"', 'data-kind="poster"'), 'picture kind must be one of'),
    (original.replace('class="bd-frame"', 'class="bd-frame" style="height: 400px"'), 'no inline style'),
    (original.replace('.bd-frame { height: 216px;', '.bd-frame { height: 400px;'), 'keep its fixed size'),
    (original.replace('<figure class="bd-pic">', '<figure class="bd-pic"></figure><figure class="bd-pic">'), 'one picture at most'),
]:
    board.write_text(content)
    run(['lint', board], expected)
for phrase in ('Use --verbose.', 'Read bin/worker.sh.', 'Change the task_id.', 'Use queuePrompt.', 'Set `value`.', 'Use the backend.'):
    build(changed(lambda d: d['plans'][0]['questions'][0]['options'][0].update(detail=phrase)), 'code words above the fold')
print('ok - every pre-show lint rule refuses its bad case')

safe = copy.deepcopy(sample)
safe['builder_detail'] = '</div><script>alert("unsafe")</script>\n' + 'JSON schema task_id ' * 500
safe['title'] = 'a <b>bold</b> title'
build(safe)
parsed = inspect()
assert safe['builder_detail'] in parsed.text
assert len([tag for tag, _ in parsed.tags if tag == 'script']) == 2
assert 'TOOL-1: a <b>bold</b> title' in ''.join(parsed.text) and 'bold' not in parsed.text
print('ok - payload text stays escaped and builder detail stays outside the lint')
build(sample)
PY
if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/fm-plan-board-submit.test.js" "$TMP_ROOT/board.html" "$ROOT/bin/fm-procevent-lavish.sh"
else
  printf '%s\n' 'skip - generated board submission requires node'
fi
