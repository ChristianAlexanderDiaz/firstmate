#!/usr/bin/env bash
# fm-plan-board.sh - render and lint a ticket board in one of two fixed formats (Python 3).
#
# Usage:
#   fm-plan-board.sh build <payload.json> <board.html>
#   fm-plan-board.sh lint <board.html>
#
# build validates the payload, fills the shipped template, and lints before
# atomically replacing the destination. It neither opens Lavish nor arms answers.
# Run lint immediately before showing an existing board. Delivery and feedback
# remain with the existing crew-hosted Lavish review workflow.
# The layout, the look and the script come from the template, and the payload
# supplies words, so boards cannot drift. The one thing drawn by hand is the
# picture. "schema" picks the format:
#   fm-plan-board.v2      a decision board: a plan and the picks it waits on.
#   fm-research-brief.v1  a research brief: what a research run found.
#
# THE DECISION BOARD, top to bottom on the left: "TICKET: title", the TL;DR, one
# line of what could go wrong, his words, one picture, "If you say go" as a
# story, what it touches and will not do, risk, undo, done-when and proof, what
# is already decided, and a closed builder detail. The questions and one send
# sit on the right and follow the reading; under 980 px the page is one column,
# questions last.
#
# Payload (text is plain, never HTML; fields marked optional may be left out):
#   {"schema":"fm-plan-board.v2", "ticket":"TOOL-112", "title":"cost per task",
#    "tldr":"The ticket at a glance: what it is and where it stands.",
#    "words":{"quote":"his own words", "from":"You, when you sent it"},   optional
#    "picture":{"caption":"Cost per task", "file":"picture.svg",          optional
#      "alt":"One sentence that says what the picture shows.",
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
# THE RESEARCH BRIEF, top to bottom: "TICKET: title", the answer in one plain
# line, his question in his words, one picture of the key finding, what we
# found, what we expect, what we could not check and how sure we are, what to
# watch next, and closed notes and sources. There is no question column: his
# feedback is a note on any line and the board conversation. Each claim is its
# own row with its own id, so a note lands on the exact claim he doubts. The mark
# beside a row says how sure it is: a dot was seen, a dashed ring is a guess, an
# open ring was not checked. From 1160 px the answer sits beside the picture and
# each source beside its fact; narrower, the page is one column.
#
# Payload:
#   {"schema":"fm-research-brief.v1", "ticket":"LIFE-58", "title":"card price after the news",
#    "answer":"The one-line answer to his question.",
#    "words":{"quote":"his question, in his words", "from":"You, on Nov 26"},
#    "picture":{...},                                 optional, same as above
#    "found":[{"claim":"One fact, one sentence.", "source":"Who says so",
#              "detail":"More, if it needs it.",      optional
#              "link":"https://...",                  optional, opens the source
#              "topic":"The card"}],                  optional, groups facts in a row
#    "expect":[{"claim":"What we think happens next.", "because":"What that leans on.",
#               "sure":"Low"}],                       optional section
#    "sure":"How sure we are overall, in a sentence or two.",
#    "unverified":[{"gap":"What we could not check.", "why":"What stopped us"}],   why optional
#    "watch":[{"when":"Fri Nov 27, 9pm", "what":"What happens or could happen.",
#              "means":"What it would tell us."}],    optional section; means optional
#    "questions":[...],                               optional, see below
#    "builder_detail":"Every number, source and method belongs here."}
# "found" holds only what was seen, each with its source; anything reasoned goes
# in "expect", which the board labels a guess. "when" is a date or a trigger.
# "questions" is for a real decision the research leaves open, and most briefs
# have none. Each is {"key","question","options":[{"value","label","detail"}],
# "recommended"} with an optional "picked"; when there is one, the picks and the
# send take the right side exactly as on a decision board.
#
# THE PICTURE. One per board, optional, on either format. The worker draws it by
# hand for that ticket as its own svg file, named by "file" beside the payload:
# any shape that explains the thing (a flow, before and after, a map, a
# timeline, a comparison, a mockup). The shell around it stays builder-made. The
# rules are fixed, and build and lint both hold the picture to the ones a
# program can check:
#   - one svg, drawn to fit the one frame: viewBox="0 0 640 216", nothing else
#     on the root, plain numbers that stay inside it. Text is 12 or larger.
#   - the page's colours only: fill and stroke are none, currentColor or
#     var(--ink), var(--soft), var(--line), var(--wash), var(--ring),
#     var(--accent), var(--on-accent), var(--page). No style, no hex, no names.
#     Classes p-soft, p-strong, p-num and p-serif set the board's type on text.
#   - shapes and words only: g, path, rect, circle, ellipse, line, polyline,
#     polygon, text, tspan, title, desc, defs, marker, clipPath. No gradients,
#     filters, patterns, scripts, links or outside files. An image is refused
#     unless the picture says "screenshot":true and the image is a real
#     screenshot embedded as a data: PNG, JPEG or WebP.
#   - short labels: at most 6 words and 40 letters each, at most 20 in all, and
#     at least one, so the picture explains itself without the text beside it.
#   - ids start with "pic-". Give each meaningful mark an id and a <title> so
#     a note can land on it.
# Three rules only a person can check: one idea per figure, no decoration or
# stock-style art, and real numbers only. "alt" is one plain sentence that says
# what the picture shows. "facts" (at most 2 of {"big","label"}) may sit under
# it. When nothing honest can be drawn, leave the picture out. In a frame under
# 520 px wide the picture keeps its size and slides sideways.
#
# Limits: 1-12 steps, 1-3 risks, 1-3 undo, 1-5 done, 1-5 touches, 1-4 wont, up to
# 8 defaults, up to 2 facts, at least two uniquely valued options; 1-14 found,
# up to 6 expect, 1-8 unverified, up to 8 watch. Keys and values are 1-128 ASCII
# letters, digits, dots, underscores or dashes; question keys direction, go and
# defaults and option value reconcile are reserved. ticket is an id such as
# TOOL-112. Every text field is nonblank.
#
# Plain words. On a decision board tldr, every "say", "seen", the first risk,
# and a direction's story, cost and why; on a research brief answer, every
# claim, detail, because, gap, what and means, and sure; and the picture's alt
# on both, are held to plain words: none of PR, PRs, CI, API, JSON, CLI, SDK,
# schema, payload, sudo, repo, repos, rebase, merge, merged, merges, telemetry,
# keepalive, dotfiles, kernel, median, drift, backend, frontend, worktree,
# metadata, lint, regex, refactor, endpoint, stdout, stderr; no file names or
# slashes; at most 24 words a sentence. "say", "seen", the first risk, cost,
# why, answer, claim, gap, what, means and alt are one sentence each; tldr and
# detail are at most 60 words, because 60 and sure 40; tldr never says "say
# go", because what happens on go is the story. A "say" may not start with an
# order word.
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
# title section as the first block, exactly one closed detail disclosure, and
# at most one picture: one svg inside the fixed frame that passes every picture
# rule above, with no image or embed anywhere else on the page. It rejects, in
# text that is visible when the board opens, code/pre tags, backticks, flags,
# paths, snake_case, camelCase, and these case-insensitive code words: API,
# JSON, YAML, HTML, CSS, JavaScript, TypeScript, SQL, CLI, SDK, DOM, payload,
# schema, backend, frontend, worktree, metadata, function, variable, localhost,
# argv, stdout, stderr. The names eBay, iPhone, iPad, iMessage, iCloud, iOS and
# macOS are not code. Text behind Details, in a plan that is not shown, and in
# builder_detail is not checked. These heuristics supplement editorial review;
# they are not a natural-language classifier.
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
import xml.etree.ElementTree as ET

TICKET = r'[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}'
FRAME_RULE = '.bd-frame { height: 216px;'
WIDE, TALL = 640, 216
VIEWBOX = '0 0 %d %d' % (WIDE, TALL)
PAINTS = ['none', 'currentColor'] + ['var(--%s)' % name for name in 'ink soft line wash ring accent on-accent page'.split()]
ART_TAGS = set('g path rect circle ellipse line polyline polygon text tspan title desc defs marker clipPath'.split())
ART_ATTRS = set('''id class x y x1 y1 x2 y2 cx cy r rx ry width height d points dx dy transform fill stroke stroke-width
stroke-linecap stroke-linejoin stroke-dasharray stroke-dashoffset fill-opacity stroke-opacity opacity fill-rule clip-rule
text-anchor dominant-baseline font-size font-weight font-style letter-spacing marker-start marker-mid marker-end
markerWidth markerHeight markerUnits refX refY orient clip-path clipPathUnits preserveAspectRatio vector-effect
paint-order'''.split())
ART_CLASSES = {'p-soft', 'p-strong', 'p-num', 'p-serif'}
BRANDS = r'\b(?:eBay|iPhone|iPad|iMessage|iCloud|iOS|macOS)\b'
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


def validate_question(question, story=True):
    fields(question, 'key question options recommended', 'question', 'picked')
    slug(question['key'], 'question key')
    require(question['key'] not in RESERVED_KEYS, 'question key ' + question['key'] + ' is reserved')
    text(question['question'], 'question')
    slug(question['recommended'], 'recommended')
    options = question['options']
    require(isinstance(options, list) and len(options) >= 2, 'at least two options required')
    values = set()
    for option in options:
        fields(option, 'value label detail say does' if story else 'value label detail', 'option')
        slug(option['value'], 'option value')
        require(option['value'] != 'reconcile', 'option value reconcile is reserved')
        require(option['value'] not in values, 'duplicate option value')
        values.add(option['value'])
        text(option['label'], 'option label')
        text(option['detail'], 'option detail')
        if story:
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


def art(markup, shot, built=False):
    """Hold a hand-drawn picture to the fixed rules a program can check. Returns its root element."""
    require(not re.search(r'<!(?!--)|<\?', markup), 'picture: plain svg only, no doctype, entity or processing instruction')
    try:
        root = ET.fromstring(markup)
    except ET.ParseError as error:
        raise ValueError(f'picture: the svg is not well formed ({error})')
    for node in root.iter():
        node.tag = node.tag.replace('{http://www.w3.org/2000/svg}', '')
        require('{' not in node.tag and not any('{' in name for name in node.attrib),
                'picture: plain svg elements and attributes only; write href, not xlink:href')
    require(root.tag == 'svg', 'picture: one svg is required')
    extra = {'class': 'bd-art', 'role': 'img'} if built else {}
    require(set(root.attrib) == {'viewBox'} | set(extra) | ({'aria-label'} if built else set())
            and all(root.get(name) == value for name, value in extra.items()),
            'picture: the svg root carries viewBox only; the frame sets its size')
    require(' '.join(root.get('viewBox').split()) == VIEWBOX, f'picture: draw it to fit the frame, viewBox="{VIEWBOX}"')
    labels, ids, images = [], set(), []

    def number(node, name):
        try:
            return float(node.get(name, '0'))
        except ValueError:
            raise ValueError(f'picture: {name}="{node.get(name)}" must be a plain number')

    def inside(node, xs, ys):
        require(all(-0.5 <= x <= WIDE + 0.5 for x in xs) and all(-0.5 <= y <= TALL + 0.5 for y in ys),
                f'picture: a <{node.tag}> reaches outside the {WIDE} by {TALL} frame')

    def bounds(node, size, anchor):
        tag = node.tag
        if tag in ('rect', 'image'):
            x, y = number(node, 'x'), number(node, 'y')
            inside(node, (x, x + number(node, 'width')), (y, y + number(node, 'height')))
        elif tag in ('circle', 'ellipse'):
            x, y = number(node, 'cx'), number(node, 'cy')
            rx, ry = (number(node, 'r'),) * 2 if tag == 'circle' else (number(node, 'rx'), number(node, 'ry'))
            inside(node, (x - rx, x + rx), (y - ry, y + ry))
        elif tag == 'line':
            inside(node, (number(node, 'x1'), number(node, 'x2')), (number(node, 'y1'), number(node, 'y2')))
        elif tag in ('polyline', 'polygon'):
            points = re.split(r'[\s,]+', node.get('points', '').strip())
            require(len(points) % 2 == 0 and all(re.fullmatch(r'-?\d+(?:\.\d+)?', point) for point in points),
                    'picture: points must be plain number pairs')
            inside(node, map(float, points[0::2]), map(float, points[1::2]))
        elif tag == 'text' and not any('x' in child.attrib or 'y' in child.attrib for child in node.iter('tspan')):
            # Half the type size a letter is a low estimate, so only a label that surely overflows is refused.
            x, wide = number(node, 'x'), len(' '.join(''.join(node.itertext()).split())) * size * 0.5
            left = {'start': x, 'middle': x - wide / 2, 'end': x - wide}.get(anchor, x)
            inside(node, (left, left + wide), (number(node, 'y'),))

    def walk(node, moved, size, anchor):
        tag = node.tag
        allowed = ART_ATTRS
        if node is not root:
            require(tag != 'svg', 'picture: one svg, not one inside another')
            if tag == 'image':
                require(shot, 'picture: no images; only a real screenshot may carry one ("screenshot": true)')
                images.append(node)
                allowed = {'id', 'x', 'y', 'width', 'height', 'href', 'preserveAspectRatio'}
                require(re.fullmatch(r'data:image/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=\s]+', node.get('href', '')),
                        'picture: a screenshot is embedded as a data: PNG, JPEG or WebP, never linked')
            else:
                require(tag in ART_TAGS, f'picture: <{tag}> is not allowed; shapes and words only')
            for name, value in node.attrib.items():
                require(name in allowed or (name == 'viewBox' and tag == 'marker'),
                        f'picture: {name} is not allowed on <{tag}>' + ('; colour comes from fill and stroke' if name == 'style' else ''))
                if name in ('fill', 'stroke'):
                    require(value.strip() in PAINTS, f'picture: {name}="{value}" is not a page colour; use ' + ', '.join(PAINTS))
                elif name in ('marker-start', 'marker-mid', 'marker-end', 'clip-path'):
                    require(re.fullmatch(r'url\(#pic-[A-Za-z0-9_-]+\)', value.strip()), f'picture: {name} points at a pic- id in this picture')
                elif name == 'id':
                    require(re.fullmatch(r'pic-[A-Za-z0-9_-]{1,60}', value) and value not in ids, 'picture: ids are unique and start with pic-')
                    ids.add(value)
                elif name == 'class':
                    require(set(value.split()) <= ART_CLASSES, 'picture: classes are ' + ', '.join(sorted(ART_CLASSES)))
                elif name == 'font-size':
                    require(re.fullmatch(r'\d+(?:\.\d+)?', value) and float(value) >= 12, 'picture: text under 12 is too small to read')
                elif name != 'href':
                    require('url(' not in value and '<' not in value, f'picture: {name} holds a plain value')
        size = float(node.get('font-size', size))
        anchor = node.get('text-anchor', anchor)
        moved = moved or 'transform' in node.attrib or tag in ('defs', 'marker', 'clipPath')
        if tag == 'text':
            label = ' '.join(''.join(node.itertext()).split())
            require(label, 'picture: an empty text label')
            require(len(label.split()) <= 6 and len(label) <= 40, f'picture: a label is a few words; "{label}" is too long')
            labels.append(label)
        elif tag in ('title', 'desc'):
            require(''.join(node.itertext()).strip() and not len(node), f'picture: a <{tag}> holds words only')
        if not moved:
            bounds(node, size, anchor)
        for child in node:
            walk(child, moved, size, anchor)

    walk(root, False, 13.0, 'start')
    require(len(labels) <= 20, 'picture: one idea per figure; over 20 labels is too many')
    require(labels or images, 'picture: label what it shows, so it explains itself')
    require(len(images) <= 1, 'picture: one screenshot at most')
    return root


def validate_picture(picture, base):
    require(isinstance(picture, dict), 'picture: missing or unexpected fields')
    require(not {'bars', 'kind'} & set(picture),
            'picture: the builder no longer draws bars or preset kinds; draw the picture by hand and name its svg in "file"')
    fields(picture, 'caption alt file', 'picture', 'facts screenshot')
    text(picture['caption'], 'picture caption')
    plain(picture['alt'], 'picture alt')
    require(picture.get('screenshot', False) in (True, False), 'picture screenshot must be true or false')
    text(picture['file'], 'picture file')
    source = Path(picture['file'])
    require(source.suffix == '.svg', 'picture file: an svg file is required')
    facts = picture.get('facts', [])
    require(isinstance(facts, list) and len(facts) <= 2, 'facts: at most 2 items')
    for fact in facts:
        fields(fact, 'big label', 'fact')
        text(fact['big'], 'fact big')
        text(fact['label'], 'fact label')
    return art((source if source.is_absolute() else base / source).read_text(encoding='utf-8'), picture.get('screenshot', False))


def validate_plan_board(data, base):
    fields(data, 'schema ticket title tldr plans builder_detail', 'payload', 'words picture defaults')
    plain(data['tldr'], 'tldr', one_sentence=False, most=60)
    require('say go' not in data['tldr'].lower(), 'plain words: tldr is the ticket at a glance, not the plan')
    if 'words' in data:
        validate_words(data['words'])
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


def validate_words(words):
    fields(words, 'quote from', 'words')
    text(words['quote'], 'words quote')
    text(words['from'], 'words from')


def listed(data, key, low, high, label=None):
    value = data.get(key, [])
    require(isinstance(value, list) and low <= len(value) <= high, f'{label or key}: {low} to {high} items required')
    return value


def validate_research(data, base):
    fields(data, 'schema ticket title answer words found sure unverified builder_detail', 'payload',
           'picture expect watch questions')
    plain(data['answer'], 'answer')
    validate_words(data['words'])
    for fact in listed(data, 'found', 1, 14):
        fields(fact, 'claim source', 'found', 'detail link topic')
        plain(fact['claim'], 'found claim')
        text(fact['source'], 'found source')
        if 'detail' in fact:
            plain(fact['detail'], 'found detail', one_sentence=False, most=60)
        if 'link' in fact:
            require(isinstance(fact['link'], str) and re.fullmatch(r'https?://[^\s"<>]+', fact['link']), 'found link: a web address is required')
        if 'topic' in fact:
            text(fact['topic'], 'found topic')
    for guess in listed(data, 'expect', 0, 6):
        fields(guess, 'claim because sure', 'expect')
        plain(guess['claim'], 'expect claim')
        plain(guess['because'], 'expect because', one_sentence=False, most=60)
        text(guess['sure'], 'expect sure')
    plain(data['sure'], 'sure', one_sentence=False, most=40)
    for gap in listed(data, 'unverified', 1, 8):
        fields(gap, 'gap', 'unverified', 'why')
        plain(gap['gap'], 'unverified gap')
        if 'why' in gap:
            text(gap['why'], 'unverified why')
    for watch in listed(data, 'watch', 0, 8):
        fields(watch, 'when what', 'watch', 'means')
        text(watch['when'], 'watch when')
        plain(watch['what'], 'watch what')
        if 'means' in watch:
            plain(watch['means'], 'watch means')
    keys = []
    for question in listed(data, 'questions', 0, 12):
        validate_question(question, story=False)
        require(question['key'] not in keys, 'duplicate question key')
        keys.append(question['key'])


def validate(data, base):
    """Check a payload of either format. Returns its format name and the picture's root element, if it has one."""
    require(isinstance(data, dict) and 'schema' in data, 'payload: missing or unexpected fields')
    require(data['schema'] in FORMATS, 'unsupported schema')
    FORMATS[data['schema']][0](data, base)
    text(data['ticket'], 'ticket')
    require(re.fullmatch(TICKET, data['ticket']), 'ticket: an id such as TOOL-112 is required')
    for key in ('title', 'builder_detail'):
        text(data[key], key)
    return validate_picture(data['picture'], base) if 'picture' in data else None


class BoardLint(HTMLParser):
    voids = {'meta', 'link', 'input', 'br', 'hr', 'img', 'wbr', 'source', 'area', 'base', 'embed', 'param', 'track',
             'col', 'rect', 'line', 'circle', 'path', 'ellipse', 'polyline', 'polygon', 'image'}

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
        self.arts = 0
        self.shot = False
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
            self.frames += 1
            self.shot = 'data-shot' in attrs
        if tag == 'svg' and self.inside('figure'):
            require(any('bd-frame' in (held.get('class') or '').split() for _, held in self.stack),
                    'the picture sits inside the fixed frame')
            self.arts += 1
        require(tag not in ('img', 'picture', 'iframe', 'object', 'embed', 'video', 'audio', 'canvas'),
                'no images or embeds outside the hand-drawn picture')
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
        if self.inside('title') and not self.inside('body'):
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
    require(parser.first == ('section', 'tldr') and parser.tldr == 1, 'the title section must be the first block')
    titled = re.fullmatch(TICKET + r': \S.*', parser.title.strip())
    require(titled, 'page title must read TICKET: title')
    require(' '.join(''.join(parser.heading).split()) == ' '.join(parser.title.split()),
            'the heading must repeat the page title')
    require(parser.builder == 1, 'one collapsed builder detail is required')
    require(parser.figures <= 1 and parser.frames == parser.figures == parser.arts,
            'one picture at most: one svg inside the fixed frame')
    require(FRAME_RULE in ''.join(parser.style), 'the picture frame must keep its fixed size')
    if parser.figures:
        art(re.search(r'<figure\b[\s\S]*?(<svg\b[\s\S]*?</svg>)', board).group(1), parser.shot, built=True)
    visible = re.sub(BRANDS, ' ', ' '.join(parser.visible))
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


def picture_html(picture, root):
    """The one frame, with the hand-drawn picture written back out from its checked tree."""
    def squash(value):
        return esc(re.sub(r'\s+', ' ', value or ''), quote=False)

    def out(node, words):
        words = words or node.tag in ('text', 'title', 'desc')
        attrs = ''.join(' %s="%s"' % (name, esc(value)) for name, value in node.attrib.items())
        inner = (squash(node.text) if words else '') + ''.join(
            out(child, words) + (squash(child.tail) if words else '') for child in node)
        return '<%s%s>%s</%s>' % (node.tag, attrs, inner, node.tag) if inner else '<%s%s/>' % (node.tag, attrs)

    facts = ''.join('<li><strong>%s</strong><span>%s</span></li>' % (esc(fact['big']), esc(fact['label']))
                    for fact in picture.get('facts', []))
    return ('<figure class="bd-pic"><figcaption>%s</figcaption><div class="bd-frame"%s>'
            '<svg class="bd-art" viewBox="%s" role="img" aria-label="%s">%s</svg></div>'
            '<p class="bd-pan">Slide the picture sideways to see all of it.</p>%s</figure>'
            % (esc(picture['caption']), ' data-shot' if picture.get('screenshot') else '', VIEWBOX, esc(picture['alt']),
               ''.join(out(child, False) for child in root), '<ul class="bd-facts">' + facts + '</ul>' if facts else ''))


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
                       % (pick(name, option['value'], option.get('say', ''), option.get('does', ''), recommended, option['label'],
                               option['value'] == question.get('picked')),
                          esc(option['label']), esc(option['detail']),
                          '<span class="bd-rec">Recommended</span>' if recommended else ''))
        step = ('<button type="button" class="bd-q-step" data-q="%d" title="Show the step this changes">Step %d</button>'
                % (offset + number, step_of[key]) if key in step_of else '')
        out.append('</div>%s%s</fieldset>' % (step, WRITE % ('Write it instead', 'Your words: ' + esc(question['question']))))
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


def head_html(data):
    return '<h1 class="bd-title"><span class="bd-id">%s:</span> %s</h1>' % (esc(data['ticket']), esc(data['title']))


def words_html(words):
    return '<blockquote class="bd-words"><p>“%s”</p><footer>%s</footer></blockquote>' % (esc(words['quote']), esc(words['from']))


def call_html(total, picks):
    """The questions and the one send, or the plain statement that there is nothing to decide."""
    out = ['<div class="bd-part bd-answer"><section class="bd-call"><h2 class="bd-h">Your call%s</h2>'
           % ('<span class="bd-h-n">%d question%s</span>' % (total, '' if total == 1 else 's') if total else '')]
    if total:
        out.append('<div class="bd-picks">' + picks + '</div></section>'
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
    return ''.join(out)


def detail_html(data, label):
    return ('<details class="bd-more" id="builder-detail"><summary>%s</summary>'
            '<div class="bd-more-body">%s</div></details></section>' % (label, esc(data['builder_detail'])))


def render_plan_board(data, picture):
    plans = data['plans']
    several = len(plans) > 1
    opening = next((plan for plan in plans if plan.get('recommended')), plans[0])
    total = len(opening['questions']) + (1 if several else 0)
    out = ['<section id="tldr" class="bd-part bd-ask"><div class="bd-lead"><header class="bd-head">'
           '%s<p class="bd-gist">%s</p>' % (head_html(data), esc(data['tldr']))]
    for plan in plans:
        out.append('<p class="bd-warn"%s><b>Could go wrong</b><span>%s</span>'
                   '<button type="button" class="bd-warn-more">See all %d</button></p>'
                   % (way_attrs(plan, plan is opening), esc(plan['risk'][0]), len(plan['risk'])))
    out.append('</header>' + (words_html(data['words']) if 'words' in data else '') + '</div>' + picture + '</section>')

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
    out.append(detail_html(data, 'Builder detail'))
    out.append(call_html(total, (directions_html(plans) if several else '') + ''.join(picks)))
    return 'plan', ''.join(out)


def row_html(kind, name, claim, detail, side_label, side):
    """One claim he can leave a note on: the claim, anything more, and beside it where it comes from or how sure it is."""
    return ('<li class="rb-row %s" id="%s"><div class="rb-main"><p class="rb-claim">%s</p>%s</div>%s</li>'
            % (kind, name, esc(claim), '<p class="rb-detail">%s</p>' % esc(detail) if detail else '',
               '<p class="rb-side"><b>%s</b>%s</p>' % (side_label, side) if side else ''))


def render_research(data, picture):
    out = ['<section id="tldr" class="bd-part bd-ask rb-top"><header class="bd-head">%s</header>'
           '<div class="rb-lead"><p class="rb-answer">%s</p>%s</div>%s</section>'
           % (head_html(data), esc(data['answer']), words_html(data['words']), picture),
           '<section class="bd-part rb-found"><h2 class="bd-h">What we found</h2>'
           '<p class="bd-note">One fact to a line, each with where it comes from. Leave a note on any line you doubt.</p>']
    topic = None
    for number, fact in enumerate(data['found']):
        if number == 0 or fact.get('topic') != topic:
            topic = fact.get('topic')
            out.append(('</ul>' if number else '') + ('<h3 class="rb-topic">%s</h3>' % esc(topic) if topic else '')
                       + '<ul class="rb-rows">')
        source = esc(fact['source'])
        if 'link' in fact:
            source = '<a href="%s" target="_blank" rel="noopener">%s</a>' % (esc(fact['link']), source)
        out.append(row_html('rb-fact', 'found-%d' % (number + 1), fact['claim'], fact.get('detail'), 'Source', source))
    out.append('</ul></section>')
    if data.get('expect'):
        out.append('<section class="bd-part rb-expect"><h2 class="bd-h">What we expect<span class="rb-tag">A guess, not a fact</span></h2>'
                   '<ul class="rb-rows">'
                   + ''.join(row_html('rb-guess', 'expect-%d' % number, guess['claim'], guess['because'], 'How sure', esc(guess['sure']))
                             for number, guess in enumerate(data['expect'], 1)) + '</ul></section>')
    out.append('<section class="bd-part rb-open"><h2 class="bd-h">What we could not check</h2>'
               '<p class="rb-sure" id="sure"><b>How sure we are</b>%s</p><ul class="rb-rows">%s</ul></section>'
               % (esc(data['sure']), ''.join(row_html('rb-gap', 'open-%d' % number, gap['gap'], None, 'Why not', esc(gap.get('why', '')))
                                             for number, gap in enumerate(data['unverified'], 1))))
    if data.get('watch'):
        out.append('<section class="bd-part rb-watch"><h2 class="bd-h">What to watch next</h2><ol class="rb-rows">'
                   + ''.join('<li class="rb-row rb-date" id="watch-%d"><p class="rb-when">%s</p><div class="rb-main">'
                             '<p class="rb-claim">%s</p>%s</div></li>'
                             % (number, esc(watch['when']), esc(watch['what']),
                                '<p class="rb-detail">%s</p>' % esc(watch['means']) if 'means' in watch else '')
                             for number, watch in enumerate(data['watch'], 1)) + '</ol></section>')
    out.append('<section class="bd-part bd-extra">' + detail_html(data, 'Full notes and sources'))
    questions = data.get('questions', [])
    if questions:
        out.append(call_html(len(questions), questions_html({'questions': questions, 'steps': []}, 0, 1, True)))
    return ('research-pick' if questions else 'research'), ''.join(out)


FORMATS = {'fm-plan-board.v2': (validate_plan_board, render_plan_board),
           'fm-research-brief.v1': (validate_research, render_research)}


def render(data, root, template):
    picture = picture_html(data['picture'], root) if 'picture' in data else ''
    kind, board = FORMATS[data['schema']][1](data, picture)
    replacements = {'TITLE': esc(data['ticket'] + ': ' + data['title']), 'BOARD': board, 'KIND': kind}
    for key in replacements:
        require(template.count('__FM_PLAN_' + key + '__') == 1, 'invalid template slot: ' + key)
    return re.sub(r'__FM_PLAN_(TITLE|BOARD|KIND)__', lambda match: replacements[match.group(1)], template)


try:
    template, *args = sys.argv[1:]
    require(args and ((args[0] == 'build' and len(args) == 3) or (args[0] == 'lint' and len(args) == 2)),
            'usage: fm-plan-board.sh build <payload.json> <board.html> | lint <board.html>')
    if args[0] == 'lint':
        print(f'lint: passed ({lint(Path(args[1]).read_text(encoding="utf-8"))} visible words)')
    else:
        data = json.loads(Path(args[1]).read_text(encoding='utf-8'))
        board = render(data, validate(data, Path(args[1]).resolve().parent), Path(template).read_text(encoding='utf-8'))
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
