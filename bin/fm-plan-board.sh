#!/usr/bin/env bash
# fm-plan-board.sh - render and lint a ticket board in the one fixed format (Python 3).
#
# Usage:
#   fm-plan-board.sh build <payload.json> <board.html>
#   fm-plan-board.sh lint <board.html>
#
# build validates fm-plan-board.v2, fills the shipped template, and lints before
# atomically replacing the destination. It neither opens Lavish nor arms answers.
# Run lint immediately before showing an existing board. Delivery and feedback
# remain with the existing crew-hosted Lavish review workflow.
# Every board is the same page: the layout, the look and the script come from
# the template, and the payload supplies words only, so boards cannot drift.
#
# The board, top to bottom on the left: "TICKET: title", the TL;DR, one line of
# what could go wrong, his words, one picture, "If you say go" as a story, what
# it touches and will not do, risk, undo, done-when and proof, what is already
# decided, and a closed builder detail. The questions and one send sit on the
# right and follow the reading; under 980 px the page is one column, questions last.
#
# Payload (text is plain, never HTML; fields marked optional may be left out):
#   {"schema":"fm-plan-board.v2", "ticket":"TOOL-112", "title":"cost per task",
#    "tldr":"The ticket at a glance: what it is and where it stands.",
#    "words":{"quote":"his own words", "from":"You, when you sent it"},   optional
#    "picture":{"kind":"comparison", "caption":"Cost per task",            optional
#      "bars":[{"label":"CarryRank", "note":"103 tasks", "value":"$12.00", "share":1},
#              {"label":"PC", "value":"not counted yet", "share":null}],
#      "facts":[{"big":"$3 to $9", "label":"one week apart"}]},
#    "plans":[{"steps":[{"question":"unit"},
#                       {"say":"it draws a chart every week.", "does":"Chart the median weekly"}],
#      "seen":"you will see a chart each week.",
#      "touches":["The cost record"], "wont":["Change what you are billed"],
#      "risk":["The numbers are a best guess."], "undo":["Each change can be taken back."],
#      "done":["A weekly chart exists"], "proof":"The chart, linked on the ticket.",
#      "questions":[{"key":"unit", "question":"What counts as one task?",
#        "options":[{"value":"change", "label":"One finished change", "detail":"Why and what it costs.",
#                    "say":"the worker counts one finished change as one task.",
#                    "does":"Count one merged change as one task"},
#                   {"value":"ticket", "label":"One closed ticket", "detail":"...", "say":"...", "does":"..."}],
#        "recommended":"change"}]}],
#    "defaults":[{"label":"Dollars", "value":"List price"}],                optional
#    "builder_detail":"Implementation notes and evidence belong here."}
#
# The picture. One per board, optional. What it shows is the worker's call; its
# form is fixed. "kind" names one of five preset slots that this script draws
# from payload data, so the worker writes data, never markup:
#   comparison    rows side by side: "bars", 2 to 4 of {"label","value","share"}
#                 with an optional "note"; share is 0 to 1, or null for a value
#                 nobody has measured. Drawn by this build.
#   before-after  two short states, or two images when the screen itself changes.
#   flow          the steps of the thing, in order.
#   timeline      dated points, in order.
#   screenshot    a real screenshot of today beside a mockup of the change. The
#                 one costly kind: only when the screen itself changes.
# before-after, flow, timeline and screenshot are the spec for the next pass:
# this build knows their names and refuses them with that message, so nobody
# hand-draws one. Every kind uses the board's own colours and type inside one
# frame of the same size on every board. The picture must explain the change
# without the text beside it. No decorative art, icons or stock-style
# illustration. When nothing honest can be drawn, leave the picture out.
# "facts" (at most 2 of {"big","label"}) may sit under any picture.
#
# The story. A step is either {"say","does"} or {"question": key}; a question step
# takes its words from the picked option. "say" is one plain sentence written to
# follow a lead word the board adds by position (First, Then, Next, After that,
# Last), so it starts lower-case and carries no order word. "does" is the
# technical wording, shown only behind that step's Details. "seen" follows "When
# it is done,". Every question belongs to exactly one step, and questions may be
# an empty list: the board then says there is nothing to decide and sends "go".
# Ask a question only for a fork that is a matter of taste or carries risk;
# obvious or reversible calls belong in defaults.
#
# Directions. One plan is the default. Give 2 or 3 plans only when they differ
# in shape (different steps, risks or done-when); each then also needs "key",
# "name", "story" (a short plain story), "cost" (one plain sentence), and
# optionally "recommended":true with a "why" that names the evidence. Question 1
# becomes "Which direction?", the cards sit side by side, a pick swaps the whole
# plan, and the later questions are that plan's own. At most one is recommended.
#
# Limits: 1-12 steps, 1-3 risks, 1-3 undo, 1-5 done, 1-5 touches, 1-4 wont, up to
# 8 defaults, 2-4 bars and up to 2 facts, at least two uniquely valued options.
# Keys and values are 1-128 ASCII letters, digits, dots, underscores or dashes;
# question keys direction, go and defaults and option value reconcile are
# reserved. ticket is an id such as TOOL-112. Every text field is nonblank.
#
# Plain words. tldr, every "say", "seen", the first risk, and a direction's
# story, cost and why are held to plain words: none of PR, PRs, CI, API, JSON,
# CLI, SDK, schema, payload, sudo, repo, repos, rebase, merge, merged, merges,
# telemetry, keepalive, dotfiles, kernel, median, drift, backend, frontend,
# worktree, metadata, lint, regex, refactor, endpoint, stdout, stderr; no file
# names; at most 24 words a sentence; "say", "seen", the first risk, cost and
# why are one sentence each; tldr is at most 60 words and never says "say go",
# because what happens on go is the story. A "say" may not start with an order word.
#
# Picks already made. A question may carry "picked": an option value he already
# chose. The board then opens with that option picked and its step told that way,
# so a rebuilt board never loses an answer.
#
# Answers. Each question is a keyed Lavish question, and one send delivers every
# answer in the fm-bearings-answer.v1 shape: the picked value, his own words, or
# both. A direction is answered under key direction, an empty board under go,
# and a change to a default under defaults. Lavish notes are on: a note can land
# on any words, option tiles included, because only the small pick control is a
# native input.
#
# Pre-show lint requires the page title and heading in "TICKET: title" form, the
# TL;DR section as the first block, exactly one closed builder-detail
# disclosure, and at most one picture, of a known kind, inside the fixed frame. It rejects, in text that is visible when the board opens, code/pre
# tags, backticks, flags, paths, snake_case, camelCase, and these
# case-insensitive code words: API, JSON, YAML, HTML, CSS, JavaScript,
# TypeScript, SQL, CLI, SDK, DOM, payload, schema, backend, frontend, worktree,
# metadata, function, variable, localhost, argv, stdout, stderr. Text behind
# Details, in a plan that is not shown, and in builder_detail is not checked.
# These heuristics supplement editorial review; they are not a natural-language
# classifier.
set -eu
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
  exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 - "$ROOT/.agents/skills/crewmate-briefs/assets/plan-board-template.html" "$@" <<'PY'
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

TICKET = r'[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}'
PICTURE_KINDS = ('before-after', 'flow', 'comparison', 'timeline', 'screenshot')
FRAME_RULE = '.bd-frame { height: 216px;'
RESERVED_KEYS = {'direction', 'go', 'defaults'}
JARGON = set('''pr prs ci api json cli sdk schema payload sudo repo repos rebase merge merged merges telemetry
keepalive dotfiles kernel median drift backend frontend worktree metadata lint regex refactor endpoint stdout
stderr'''.split())
ORDER_WORDS = r'(?:first|then|next|after that|last|finally)\b'
WORD = r"[A-Za-z0-9$][A-Za-z0-9$.'-]*"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, required, label, optional=''):
    require(isinstance(value, dict), label + ': missing or unexpected fields')
    names = set(value)
    require(set(required.split()) <= names <= set(required.split()) | set(optional.split()),
            label + ': missing or unexpected fields')


def text(value, label):
    require(isinstance(value, str) and bool(value.strip()), label + ': nonblank text required')


def slug(value, label):
    text(value, label)
    require(re.fullmatch(r'[A-Za-z0-9._-]{1,128}', value), label + ': invalid identifier')


def texts(value, label, low, high):
    require(isinstance(value, list) and low <= len(value) <= high, f'{label}: {low} to {high} items required')
    for item in value:
        text(item, label)


def plain(value, label, one_sentence=True, most=24):
    """Hold one text to plain words: no jargon, no file names, short sentences."""
    text(value, label)
    used = sorted({word for word in re.findall(r"[A-Za-z][A-Za-z'-]*", value) if word.lower() in JARGON})
    require(not used, f'plain words: {label} uses {", ".join(used)}')
    require(not re.search(r'[/\\_`]|\.(?:sh|py|js|ts|json|yaml|html|css|md)\b', value),
            f'plain words: {label} names a file or uses code marks')
    sentences = [part for part in re.split(r'(?<=[.?!])\s+', value.strip()) if part]
    if one_sentence:
        require(len(sentences) == 1 and value.rstrip()[-1] in '.?', f'plain words: {label} must be one sentence')
    for sentence in sentences:
        require(len(re.findall(WORD, sentence)) <= 24, f'plain words: {label} has a sentence over 24 words')
    require(len(re.findall(WORD, value)) <= most or one_sentence, f'plain words: {label} is over {most} words')


def say(value, label):
    plain(value, label)
    require(not re.match(ORDER_WORDS, value.lstrip(), re.I),
            f'plain words: {label} starts with an order word; the board adds it')


def validate_question(question):
    fields(question, 'key question options recommended', 'question', 'picked')
    slug(question['key'], 'question key')
    require(question['key'] not in RESERVED_KEYS, 'question key ' + question['key'] + ' is reserved')
    text(question['question'], 'question')
    slug(question['recommended'], 'recommended')
    options = question['options']
    require(isinstance(options, list) and len(options) >= 2, 'at least two options required')
    values = set()
    for option in options:
        fields(option, 'value label detail say does', 'option')
        slug(option['value'], 'option value')
        require(option['value'] != 'reconcile', 'option value reconcile is reserved')
        require(option['value'] not in values, 'duplicate option value')
        values.add(option['value'])
        text(option['label'], 'option label')
        text(option['detail'], 'option detail')
        say(option['say'], 'option say')
        text(option['does'], 'option does')
    require(question['recommended'] in values, 'recommended pick must match an option')
    if 'picked' in question:
        slug(question['picked'], 'picked')
        require(question['picked'] in values, 'picked answer must match an option')


def validate_plan(plan, several):
    direction = 'key name story cost' if several else ''
    fields(plan, ('steps seen touches wont risk undo done proof questions ' + direction).strip(), 'plan',
           'recommended why' if several else '')
    if several:
        slug(plan['key'], 'plan key')
        require(plan['key'] != 'reconcile', 'plan key reconcile is reserved')
        text(plan['name'], 'plan name')
        plain(plan['story'], 'plan story', one_sentence=False, most=30)
        plain(plan['cost'], 'plan cost')
        recommended = plan.get('recommended', False)
        require(isinstance(recommended, bool), 'plan recommended must be true or false')
        require(('why' in plan) == recommended, 'a recommended direction says why, and only a recommended one')
        if recommended:
            plain(plan['why'], 'plan why')
    require(isinstance(plan['questions'], list), 'questions must be a list')
    keys = []
    for question in plan['questions']:
        validate_question(question)
        require(question['key'] not in keys, 'duplicate question key')
        keys.append(question['key'])
    steps = plan['steps']
    require(isinstance(steps, list) and 1 <= len(steps) <= 12, 'steps: 1 to 12 items required')
    asked = []
    for step in steps:
        if isinstance(step, dict) and 'question' in step:
            fields(step, 'question', 'step')
            require(step['question'] in keys, 'step names an unknown question')
            asked.append(step['question'])
        else:
            fields(step, 'say does', 'step')
            say(step['say'], 'step say')
            text(step['does'], 'step does')
    require(sorted(asked) == sorted(keys), 'every question belongs to exactly one step')
    plain(plan['seen'], 'seen')
    texts(plan['touches'], 'touches', 1, 5)
    texts(plan['wont'], 'wont', 1, 4)
    texts(plan['risk'], 'risk', 1, 3)
    plain(plan['risk'][0], 'first risk')
    texts(plan['undo'], 'undo', 1, 3)
    texts(plan['done'], 'done', 1, 5)
    text(plan['proof'], 'proof')


def shape(plan):
    steps = tuple(step.get('question') or step['does'] for step in plan['steps'])
    return steps, tuple(plan['risk']), tuple(plan['done'])


def validate(data):
    fields(data, 'schema ticket title tldr plans builder_detail', 'payload', 'words picture defaults')
    require(data['schema'] == 'fm-plan-board.v2', 'unsupported schema')
    text(data['ticket'], 'ticket')
    require(re.fullmatch(TICKET, data['ticket']), 'ticket: an id such as TOOL-112 is required')
    for key in ('title', 'builder_detail'):
        text(data[key], key)
    plain(data['tldr'], 'tldr', one_sentence=False, most=60)
    require('say go' not in data['tldr'].lower(), 'plain words: tldr is the ticket at a glance, not the plan')
    if 'words' in data:
        fields(data['words'], 'quote from', 'words')
        text(data['words']['quote'], 'words quote')
        text(data['words']['from'], 'words from')
    if 'picture' in data:
        picture = data['picture']
        require(isinstance(picture, dict) and picture.get('kind') in PICTURE_KINDS,
                'picture kind must be one of: ' + ', '.join(PICTURE_KINDS))
        require(picture['kind'] == 'comparison', 'picture kind ' + picture['kind']
                + ' is in the spec but not drawn yet; use comparison or leave the picture out')
        fields(picture, 'kind caption bars', 'picture', 'facts')
        text(picture['caption'], 'picture caption')
        require(isinstance(picture['bars'], list) and 2 <= len(picture['bars']) <= 4, 'bars: 2 to 4 items required')
        for bar in picture['bars']:
            fields(bar, 'label value share', 'bar', 'note')
            text(bar['label'], 'bar label')
            text(bar['value'], 'bar value')
            if 'note' in bar:
                text(bar['note'], 'bar note')
            share = bar['share']
            require(share is None or (isinstance(share, (int, float)) and not isinstance(share, bool) and 0 < share <= 1),
                    'bar share must be null or a number above 0 and at most 1')
        facts = picture.get('facts', [])
        require(isinstance(facts, list) and len(facts) <= 2, 'facts: at most 2 items')
        for fact in facts:
            fields(fact, 'big label', 'fact')
            text(fact['big'], 'fact big')
            text(fact['label'], 'fact label')
    defaults = data.get('defaults', [])
    require(isinstance(defaults, list) and len(defaults) <= 8, 'defaults: at most 8 items')
    for default in defaults:
        fields(default, 'label value', 'default')
        text(default['label'], 'default label')
        text(default['value'], 'default value')
    plans = data['plans']
    require(isinstance(plans, list) and 1 <= len(plans) <= 3, 'plans: 1 to 3 items required')
    for plan in plans:
        validate_plan(plan, len(plans) > 1)
    if len(plans) > 1:
        keys = [plan['key'] for plan in plans]
        require(len(set(keys)) == len(keys), 'duplicate plan key')
        require(sum(1 for plan in plans if plan.get('recommended')) <= 1, 'at most one direction is recommended')
        require(len({shape(plan) for plan in plans}) == len(plans),
                'directions must differ in shape; a detail fork is a question')


class BoardLint(HTMLParser):
    voids = {'meta', 'link', 'input', 'br', 'hr', 'img', 'wbr', 'source', 'area', 'base', 'embed', 'param', 'track',
             'col', 'rect', 'line', 'circle', 'path'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.visible = []
        self.first = None
        self.builder = 0
        self.tldr = 0
        self.title = ''
        self.heading = []
        self.figures = 0
        self.frames = 0
        self.style = []

    def inside(self, name):
        return any(tag == name for tag, _ in self.stack)

    def hidden(self):
        return self.inside('script') or self.inside('style') or any('hidden' in attrs for _, attrs in self.stack) or (
            self.inside('details') and not self.inside('summary'))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        in_body = self.inside('body')
        if in_body and tag not in ('main', 'div', 'script', 'style') and self.first is None:
            self.first = (tag, attrs.get('id'))
        if tag == 'details':
            require('open' not in attrs, 'builder detail must start collapsed')
            require(attrs.get('id') == 'builder-detail', 'unexpected disclosure')
            self.builder += 1
        if attrs.get('id') == 'tldr':
            self.tldr += 1
        if tag == 'figure':
            self.figures += 1
            require('style' not in attrs, 'the picture frame is fixed; no inline style')
        if 'bd-frame' in (attrs.get('class') or '').split():
            require(self.inside('figure') and 'style' not in attrs, 'the picture frame is fixed; no inline style')
            require(attrs.get('data-kind') in PICTURE_KINDS, 'picture kind must be one of: ' + ', '.join(PICTURE_KINDS))
            self.frames += 1
        if tag not in self.voids:
            self.stack.append((tag, attrs))
        if in_body and not self.hidden():
            require(tag not in ('code', 'pre'), 'code markup above the fold')
            for name in ('placeholder', 'aria-label'):
                if attrs.get(name):
                    self.visible.append(attrs[name])

    def handle_endtag(self, tag):
        if tag in self.voids:
            return
        require(self.stack and self.stack[-1][0] == tag, 'malformed board HTML')
        self.stack.pop()

    def handle_data(self, value):
        if self.inside('title'):
            self.title += value
        if self.inside('style'):
            self.style.append(value)
        if self.inside('h1'):
            self.heading.append(value)
        if self.inside('body') and not self.hidden() and value.strip():
            if self.first is None:
                self.first = ('text', None)
            self.visible.append(value)


def lint(board):
    parser = BoardLint()
    parser.feed(board)
    parser.close()
    require(not parser.stack, 'unclosed board HTML')
    require(parser.first == ('section', 'tldr') and parser.tldr == 1, 'TL;DR must be the first block')
    titled = re.fullmatch(TICKET + r': \S.*', parser.title.strip())
    require(titled, 'page title must read TICKET: title')
    require(' '.join(''.join(parser.heading).split()) == ' '.join(parser.title.split()),
            'the heading must repeat the page title')
    require(parser.builder == 1, 'one collapsed builder detail is required')
    require(parser.figures <= 1 and parser.frames == parser.figures, 'one picture at most, inside the fixed frame')
    require(FRAME_RULE in ''.join(parser.style), 'the picture frame must keep its fixed size')
    visible = ' '.join(parser.visible)
    words = len(visible.split())
    terms = r'\b(?:API|JSON|YAML|HTML|CSS|JavaScript|TypeScript|SQL|CLI|SDK|DOM|payload|schema|backend|frontend|worktree|metadata|function|variable|localhost|argv|stdout|stderr)\b'
    code = re.search(terms, visible, re.I) or re.search(
        r'`|(?<!\w)--[a-zA-Z]|\b\w+_\w+\b|\b[a-z]+[A-Z][a-zA-Z]*\b|(?:[/\\][\w.-]+){2,}|\b[\w.-]+\.(?:sh|py|js|ts|json|yaml|html|css)\b', visible)
    require(code is None, 'code words above the fold' + (f': {code.group()}' if code else ''))
    return words


esc = html.escape
TICK = ('<svg class="bd-tick" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.2 6.4l2.5 2.5 5.1-5.6" fill="none" '
        'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>')
CHEVRON = ('<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3.2 1.6L6.8 5 3.2 8.4" fill="none" stroke="currentColor" '
           'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>')
END_ICON = ('<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8.25" fill="none" stroke="currentColor" '
            'stroke-width="1.5"/><path d="M6.4 10.4l2.5 2.5 4.8-5.3" fill="none" stroke="currentColor" stroke-width="1.7" '
            'stroke-linecap="round" stroke-linejoin="round"/></svg>')
WRITE = ('<button type="button" class="bd-write" aria-expanded="false">%s</button>'
         '<textarea class="bd-write-box" rows="2" hidden aria-label="%s"></textarea>')


def lead(position, total):
    """The story word for a step, so no payload text carries an order word."""
    if position == 0:
        return 'First,'
    if position == total - 1:
        return 'Last,'
    return ('Then,', 'Next,', 'After that,')[(position - 1) % 3]


def items(values):
    return '<ul>' + ''.join('<li>' + esc(value) + '</li>' for value in values) + '</ul>'


def way_attrs(plan, shown):
    return (' data-way="' + esc(plan['key']) + '"' if 'key' in plan else '') + ('' if shown else ' hidden')


def pick(name, value, option_say, option_does, recommended, label, picked=False):
    data = ' data-say="%s" data-does="%s"' % (esc(option_say), esc(option_does)) if option_say else ''
    return ('<label class="bd-pick"><input type="radio" name="%s" value="%s"%s%s%s><span class="bd-dot"></span>'
            '<span class="sr">Pick: %s</span></label>'
            % (esc(name), esc(value), data, ' data-rec' if recommended else '', ' checked' if picked else '', esc(label)))


def picture_html(picture):
    bars = picture['bars']
    said, rows = [picture['caption'] + '.'], []
    for index, bar in enumerate(bars):
        top = 54 * index
        note = '<tspan class="c-note" dx="8">%s</tspan>' % esc(bar['note']) if 'note' in bar else ''
        said.append('%s: %s.' % (bar['label'], bar['value']))
        rows.append('<text class="c-label" x="0" y="%d">%s%s</text>' % (top + 15, esc(bar['label']), note))
        if bar['share'] is None:
            rows.append('<text class="c-value c-value-missing" x="100%%" y="%d" text-anchor="end">%s</text>'
                        '<line class="c-empty" x1="0.5%%" y1="%d" x2="99.5%%" y2="%d"/>'
                        % (top + 15, esc(bar['value']), top + 30, top + 30))
        else:
            rows.append('<text class="c-value" x="100%%" y="%d" text-anchor="end">%s</text>'
                        '<rect class="c-track" x="0" y="%d" width="100%%" height="8" rx="4"/>'
                        '<rect class="c-bar" x="0" y="%d" width="%s%%" height="8" rx="4"/>'
                        % (top + 15, esc(bar['value']), top + 26, top + 26, ('%.1f' % (100 * bar['share'])).rstrip('0').rstrip('.')))
    facts = ''.join('<li><strong>%s</strong><span>%s</span></li>' % (esc(fact['big']), esc(fact['label']))
                    for fact in picture.get('facts', []))
    return ('<figure class="bd-pic"><figcaption>%s</figcaption><div class="bd-frame" data-kind="%s">'
            '<svg class="bd-chart" width="100%%" height="%d" role="img" aria-label="%s">%s</svg></div>%s</figure>'
            % (esc(picture['caption']), esc(picture['kind']), 54 * len(bars) - 16, esc(' '.join(said)), ''.join(rows),
               '<ul class="bd-facts">' + facts + '</ul>' if facts else ''))


def plan_html(plan, note, offset, first, shown):
    """What the worker will do, told start to finish. offset is the board-wide index of this plan's
    first question; first is the number that question shows."""
    index = {question['key']: number for number, question in enumerate(plan['questions'])}
    by_key = {question['key']: question for question in plan['questions']}
    out = ['<section class="bd-part bd-plan"%s><div class="bd-plan-main"><h2 class="bd-h">If you say go</h2>'
           '<p class="bd-note">%s</p><ol class="bd-steps">' % (way_attrs(plan, shown), note)]
    for position, step in enumerate(plan['steps']):
        if 'question' in step:
            question = by_key[step['question']]
            option = next(o for o in question['options'] if o['value'] == question['recommended'])
            shown_option = next(o for o in question['options'] if o['value'] == question.get('picked', question['recommended']))
            number = offset + index[question['key']]
            attrs = ' data-q="%d" data-say="%s" data-does="%s"' % (number, esc(option['say']), esc(option['does']))
            tag = ('<button type="button" class="bd-step-q" data-q="%d">%s<span>Question %d</span></button>'
                   % (number, TICK, first + index[question['key']]))
            said, does = shown_option['say'], shown_option['does']
        else:
            attrs, tag, said, does = '', '', step['say'], step['does']
        out.append('<li%s><p class="bd-step-say"><b class="bd-step-lead">%s</b> <span class="bd-step-text">%s</span></p>'
                   '<button type="button" class="bd-step-more" aria-expanded="false">%s<span>Details</span></button>%s'
                   '<p class="bd-step-detail" hidden>%s</p></li>'
                   % (attrs, lead(position, len(plan['steps'])), esc(said), CHEVRON, tag, esc(does)))
    out.append('</ol><p class="bd-end">%s<span><b>When it is done,</b> %s</span></p></div>'
               '<div class="bd-scope"><div class="bd-list bd-does"><h3>Touches</h3>%s</div>'
               '<div class="bd-list bd-wont"><h3>Will not</h3>%s</div></div></section>'
               % (END_ICON, esc(plan['seen']), items(plan['touches']), items(plan['wont'])))
    return ''.join(out)


def safe_html(plan, shown):
    return ('<section class="bd-part bd-safe"%s>'
            '<div class="bd-tile bd-list bd-risk"><h3>Could go wrong</h3>%s</div>'
            '<div class="bd-tile bd-list bd-undo"><h3>Undo</h3>%s</div>'
            '<div class="bd-tile bd-list bd-done"><h3>Done when</h3>%s'
            '<p class="bd-proof"><b>Proof you will see</b>%s</p></div></section>'
            % (way_attrs(plan, shown), items(plan['risk']), items(plan['undo']), items(plan['done']), esc(plan['proof'])))


def questions_html(plan, offset, first, shown):
    step_of = {step['question']: number + 1 for number, step in enumerate(plan['steps']) if 'question' in step}
    out = []
    for number, question in enumerate(plan['questions']):
        key = question['key']
        name = plan['key'] + ':' + key if 'key' in plan else key
        out.append('<fieldset class="bd-q" data-lavish-question="%s" data-i="%d"%s><legend><span class="bd-n">%d</span>'
                   '<span class="bd-qt">%s</span></legend><div class="bd-opts">'
                   % (esc(key), offset + number, way_attrs(plan, shown), first + number, esc(question['question'])))
        for option in question['options']:
            recommended = option['value'] == question['recommended']
            out.append('<div class="bd-opt">%s<div class="bd-opt-body"><span class="bd-opt-label">%s</span>'
                       '<span class="bd-opt-detail">%s</span>%s</div></div>'
                       % (pick(name, option['value'], option['say'], option['does'], recommended, option['label'],
                               option['value'] == question.get('picked')),
                          esc(option['label']), esc(option['detail']),
                          '<span class="bd-rec">Recommended</span>' if recommended else ''))
        out.append('</div><button type="button" class="bd-q-step" data-q="%d" title="Show the step this changes">Step %d</button>%s'
                   '</fieldset>' % (offset + number, step_of[key],
                                    WRITE % ('Write it instead', 'Your words: ' + esc(question['question']))))
    return ''.join(out)


def directions_html(plans):
    """Question 1 on a board whose plans differ in shape: one card per direction, rows lined up."""
    out = ['<fieldset class="bd-q bd-q-way" data-lavish-question="direction" data-i="0"><legend><span class="bd-n">1</span>'
           '<span class="bd-qt">Which direction?</span></legend><div class="bd-opts bd-ways" style="--ways: %d">' % len(plans)]
    for plan in plans:
        recommended = plan.get('recommended', False)
        out.append('<div class="bd-opt bd-way"><div class="bd-way-top">%s%s</div><span class="bd-way-name">%s</span>'
                   '<span class="bd-way-story">%s</span><span class="bd-way-row"><b>Risk</b>%s</span>'
                   '<span class="bd-way-row"><b>Cost</b>%s</span></div>'
                   % (pick('direction', plan['key'], '', '', recommended, plan['name']),
                      '<span class="bd-rec">Recommended</span>' if recommended else '',
                      esc(plan['name']), esc(plan['story']), esc(plan['risk'][0]), esc(plan['cost'])))
    out.append('</div>')
    for plan in plans:
        if plan.get('recommended'):
            out.append('<p class="bd-way-why"><b>Why %s</b>%s</p>' % (esc(plan['name']), esc(plan['why'])))
    out.append('<button type="button" class="bd-q-plan" title="Show the plan this changes">The plan</button>%s</fieldset>'
               % (WRITE % ('Write it instead', 'Your words: Which direction?')))
    return ''.join(out)


def render(data, template):
    plans = data['plans']
    several = len(plans) > 1
    opening = next((plan for plan in plans if plan.get('recommended')), plans[0])
    total = len(opening['questions']) + (1 if several else 0)
    title = data['ticket'] + ': ' + data['title']
    out = ['<section id="tldr" class="bd-part bd-ask"><div class="bd-lead"><header class="bd-head">'
           '<h1 class="bd-title"><span class="bd-id">%s:</span> %s</h1><p class="bd-gist">%s</p>'
           % (esc(data['ticket']), esc(data['title']), esc(data['tldr']))]
    for plan in plans:
        out.append('<p class="bd-warn"%s><b>Could go wrong</b><span>%s</span>'
                   '<button type="button" class="bd-warn-more">See all %d</button></p>'
                   % (way_attrs(plan, plan is opening), esc(plan['risk'][0]), len(plan['risk'])))
    out.append('</header>')
    if 'words' in data:
        out.append('<blockquote class="bd-words"><p>“%s”</p><footer>%s</footer></blockquote>'
                   % (esc(data['words']['quote']), esc(data['words']['from'])))
    out.append('</div>' + (picture_html(data['picture']) if 'picture' in data else '') + '</section>')

    picks, offset = [], 1 if several else 0
    for plan in plans:
        if several:
            note = 'The story for <b>%s</b>. Pick another direction and the whole story changes.' % esc(plan['name'])
        elif plan['questions']:
            note = 'The story with the recommended picks. Pick differently and that line changes.'
        else:
            note = 'The whole story. No line waits on a pick.'
        first = 2 if several else 1
        out.append(plan_html(plan, note, offset, first, plan is opening))
        picks.append(questions_html(plan, offset, first, plan is opening))
        offset += len(plan['questions'])
    for plan in plans:
        out.append(safe_html(plan, plan is opening))

    out.append('<section class="bd-part bd-extra">')
    if data.get('defaults'):
        out.append('<div class="bd-defaults" data-lavish-question="defaults"><h3>Already decided</h3><dl>'
                   + ''.join('<div><dt>%s</dt><dd>%s</dd></div>' % (esc(d['label']), esc(d['value'])) for d in data['defaults'])
                   + '</dl>' + WRITE % ('Change one', 'Which default to change, in your words') + '</div>')
    out.append('<details class="bd-more" id="builder-detail"><summary>Builder detail</summary>'
               '<div class="bd-more-body">%s</div></details></section>' % esc(data['builder_detail']))

    out.append('<div class="bd-part bd-answer"><section class="bd-call"><h2 class="bd-h">Your call%s</h2>'
               % ('<span class="bd-h-n">%d question%s</span>' % (total, '' if total == 1 else 's') if total else ''))
    if total:
        out.append('<div class="bd-picks">' + (directions_html(plans) if several else '') + ''.join(picks) + '</div></section>'
                   '<div class="bd-send"><span class="bd-count" role="status">0 of %d picked</span>'
                   '<button type="button" class="bd-jump">See the question%s</button>'
                   '<button type="button" class="bd-all">%s</button>'
                   '<button type="button" class="bd-send-btn">Send pick%s</button></div></div>'
                   % (total, '' if total == 1 else 's', 'Pick the recommended' if total == 1 else 'Pick all recommended',
                      '' if total == 1 else 's'))
    else:
        out.append('<div class="bd-none" data-lavish-question="go"><p class="bd-none-t">Nothing to decide, say go.</p>'
                   '<p class="bd-none-d">Every call on this ticket has a default.</p>'
                   '<button type="button" class="bd-none-more">See what is already decided</button></div></section>'
                   '<div class="bd-send"><span class="bd-count" role="status">Nothing to decide</span>'
                   '<button type="button" class="bd-send-btn">Say go</button></div></div>')
    replacements = {'TITLE': esc(title), 'BOARD': ''.join(out)}
    for key in replacements:
        require(template.count('__FM_PLAN_' + key + '__') == 1, 'invalid template slot: ' + key)
    return re.sub(r'__FM_PLAN_(TITLE|BOARD)__', lambda match: replacements[match.group(1)], template)


try:
    template, *args = sys.argv[1:]
    require(args and ((args[0] == 'build' and len(args) == 3) or (args[0] == 'lint' and len(args) == 2)),
            'usage: fm-plan-board.sh build <payload.json> <board.html> | lint <board.html>')
    if args[0] == 'lint':
        print(f'lint: passed ({lint(Path(args[1]).read_text(encoding="utf-8"))} visible words)')
    else:
        data = json.loads(Path(args[1]).read_text(encoding='utf-8'))
        validate(data)
        board = render(data, Path(template).read_text(encoding='utf-8'))
        words = lint(board)
        target = Path(args[2])
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, delete=False) as output:
                temporary = output.name
                output.write(board)
            if target.exists():
                os.chmod(temporary, stat.S_IMODE(target.stat().st_mode))
            os.replace(temporary, target)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
        print(f'board: {target}\nlint: passed ({words} visible words)')
except (OSError, ValueError) as error:
    sys.exit('fm-plan-board: ' + str(error))
PY
