#!/usr/bin/env bash
# fm-plan-board.sh - render and lint a reusable plan review board (Python 3).
#
# Usage:
#   fm-plan-board.sh build <payload.json> <board.html>
#   fm-plan-board.sh lint <board.html>
#
# build validates fm-plan-board.v1, fills the shipped template, and lints before
# atomically replacing the destination. It neither opens Lavish nor arms answers.
# Run lint immediately before showing an existing board. Delivery and feedback
# remain with the existing crew-hosted Lavish review workflow.
#
# Payload (all fields required, no extra fields; text is plain, never HTML):
#   {"schema":"fm-plan-board.v1", "title":"A shorter review",
#    "tldr":"Keep the choice clear and the explanation close.",
#    "decisions":[{"key":"review-size", "question":"How much to show?",
#      "options":[{"value":"short", "label":"A short overview",
#                  "detail":"Make the next choice easy to find."},
#                 {"value":"full", "label":"The full explanation",
#                  "detail":"Show everything together."}],
#      "recommended":"short"}],
#    "builder_detail":"Implementation notes and evidence belong here."}
# Decisions need unique keys, at least two uniquely valued options, and a
# recommended value belonging to those options. Keys/values are 1-128 ASCII
# letters, digits, dots, underscores or dashes. Every text field is nonblank.
# The template supplies a free-text answer box for every decision.
#
# Pre-show lint requires TL;DR as the first body/main content block and a closed
# builder-detail disclosure. It counts ALL initially expanded body text (labels,
# buttons, summary included), not viewport-dependent pixels: maximum 400 words.
# This conservative above-the-fold budget is stable across screen sizes.
# It rejects visible code/pre tags, backticks, flags, paths, snake_case,
# camelCase, and these case-insensitive code words: API, JSON, YAML, HTML, CSS,
# JavaScript, TypeScript, SQL, CLI, SDK, DOM, payload, schema, backend, frontend,
# worktree, metadata, function, variable, localhost, argv, stdout, stderr.
# These heuristics supplement editorial review; they are not a natural-language
# classifier. Technical words and unlimited detail belong in builder_detail.
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
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, expected, label):
    require(isinstance(value, dict) and set(value) == set(expected.split()),
            label + ': missing or unexpected fields')


def text(value, label):
    require(isinstance(value, str) and bool(value.strip()), label + ': nonblank text required')


def slug(value, label):
    text(value, label)
    require(re.fullmatch(r'[A-Za-z0-9._-]{1,128}', value), label + ': invalid identifier')


def validate(data):
    fields(data, 'schema title tldr decisions builder_detail', 'payload')
    require(data['schema'] == 'fm-plan-board.v1', 'unsupported schema')
    for key in ('title', 'tldr', 'builder_detail'):
        text(data[key], key)
    require(isinstance(data['decisions'], list) and data['decisions'], 'decisions must be a nonempty list')
    keys = set()
    for decision in data['decisions']:
        fields(decision, 'key question options recommended', 'decision')
        slug(decision['key'], 'decision key')
        require(decision['key'] not in keys, 'duplicate decision key')
        keys.add(decision['key'])
        text(decision['question'], 'question')
        slug(decision['recommended'], 'recommended')
        options = decision['options']
        require(isinstance(options, list) and len(options) >= 2, 'at least two options required')
        values = set()
        for option in options:
            fields(option, 'value label detail', 'option')
            slug(option['value'], 'option value')
            require(option['value'] not in values, 'duplicate option value')
            values.add(option['value'])
            text(option['label'], 'option label')
            text(option['detail'], 'option detail')
        require(decision['recommended'] in values, 'recommended pick must match an option')


class BoardLint(HTMLParser):
    voids = {'meta', 'link', 'input', 'br', 'hr', 'img', 'wbr', 'source', 'area', 'base', 'embed', 'param', 'track', 'col'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.visible = []
        self.first = None
        self.builder = 0
        self.tldr = 0

    def hidden(self):
        return any(tag in ('script', 'style') for tag, _ in self.stack) or (
            any(tag == 'details' for tag, _ in self.stack)
            and not any(tag == 'summary' for tag, _ in self.stack))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        in_body = any(t == 'body' for t, _ in self.stack)
        if in_body and tag not in ('main', 'script', 'style') and self.first is None:
            self.first = (tag, attrs.get('id'))
        if tag == 'details':
            require('open' not in attrs, 'builder detail must start collapsed')
            require(attrs.get('id') == 'builder-detail', 'unexpected disclosure')
            self.builder += 1
        if attrs.get('id') == 'tldr':
            self.tldr += 1
        if in_body and not self.hidden():
            require(tag not in ('code', 'pre'), 'code markup above the fold')
            for name in ('placeholder', 'aria-label'):
                if attrs.get(name):
                    self.visible.append(attrs[name])
        if tag not in self.voids:
            self.stack.append((tag, attrs))

    def handle_endtag(self, tag):
        require(self.stack and self.stack[-1][0] == tag, 'malformed board HTML')
        self.stack.pop()

    def handle_data(self, value):
        if any(t == 'body' for t, _ in self.stack) and not self.hidden() and value.strip():
            if self.first is None:
                self.first = ('text', None)
            self.visible.append(value)


def lint(board):
    parser = BoardLint()
    parser.feed(board)
    parser.close()
    require(not parser.stack, 'unclosed board HTML')
    require(parser.first == ('section', 'tldr') and parser.tldr == 1, 'TL;DR must be the first block')
    require(parser.visible and parser.visible[0].strip() == 'TL;DR', 'TL;DR must be the first text')
    require(parser.builder == 1, 'one collapsed builder detail is required')
    visible = ' '.join(parser.visible)
    words = len(visible.split())
    require(words <= 400, f'above-the-fold text is {words} words; maximum is 400')
    terms = r'\b(?:API|JSON|YAML|HTML|CSS|JavaScript|TypeScript|SQL|CLI|SDK|DOM|payload|schema|backend|frontend|worktree|metadata|function|variable|localhost|argv|stdout|stderr)\b'
    code = re.search(terms, visible, re.I) or re.search(
        r'`|(?<!\w)--[a-zA-Z]|\b\w+_\w+\b|\b[a-z]+[A-Z][a-zA-Z]*\b|(?:[/\\][\w.-]+){2,}|\b[\w.-]+\.(?:sh|py|js|ts|json|yaml|html|css)\b', visible)
    require(code is None, 'code words above the fold' + (f': {code.group()}' if code else ''))
    return words


def render(data, template):
    esc = html.escape
    cards = []
    for index, decision in enumerate(data['decisions'], 1):
        key = esc(decision['key'])
        options = []
        for option in decision['options']:
            recommended = option['value'] == decision['recommended']
            badge = '<span class="recommended">Recommended</span>' if recommended else ''
            options.append(
                '<label class="option"><input type="radio" name="answer" value="' + esc(option['value']) + '">'
                '<span><strong>' + esc(option['label']) + '</strong><span class="option-detail">' + esc(option['detail']) + '</span></span>' + badge + '</label>')
        cards.append(
            '<form data-lavish-question="' + key + '"><fieldset><legend><span class="number">' + str(index) + '</span> '
            + esc(decision['question']) + '</legend>' + ''.join(options)
            + '<label class="words" for="note-' + key + '">Say it in your words</label>'
            + '<textarea id="note-' + key + '" name="note" rows="2"></textarea></fieldset>'
            + '<div class="actions"><button type="submit">Queue answer</button><span role="status"></span></div></form>')
    replacements = {'TITLE': esc(data['title']), 'TLDR': esc(data['tldr']),
                    'DECISIONS': '\n'.join(cards), 'BUILDER_DETAIL': esc(data['builder_detail'])}
    for key in replacements:
        require(template.count('__FM_PLAN_' + key + '__') == 1, 'invalid template slot: ' + key)
    return re.sub(r'__FM_PLAN_(TITLE|TLDR|DECISIONS|BUILDER_DETAIL)__',
                  lambda match: replacements[match.group(1)], template)


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
            os.replace(temporary, target)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
        print(f'board: {target}\nlint: passed ({words} visible words)')
except (OSError, ValueError) as error:
    sys.exit('fm-plan-board: ' + str(error))
PY
