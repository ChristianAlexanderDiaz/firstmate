#!/usr/bin/env bash
# Cross-home GitHub reuse, batch sharing, expiry and quota waiting via public commands.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-read)
export FM_TEST_GITHUB_ROOT="$TMP_ROOT" FM_TEST_GITHUB_REPO="$ROOT"
python3 - <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ['FM_TEST_GITHUB_ROOT'])
repo = Path(os.environ['FM_TEST_GITHUB_REPO'])
fake = root / 'fakebin'
fake.mkdir()
script = fake / 'gh'
script.write_text('''#!/usr/bin/env python3
import json, os, re, sys, time
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('REFUSED') or (os.environ.get('REFUSED_PAGE2') and 'page=2' in sys.argv[2]):
    print('< HTTP/2.0 403 Forbidden', file=sys.stderr)
    if os.environ.get('RESET'): print('< X-Ratelimit-Reset: ' + os.environ['RESET'], file=sys.stderr)
    if os.environ.get('RETRY'): print('< Retry-After: ' + os.environ['RETRY'], file=sys.stderr)
    if 'REMAINING' in os.environ: print('< X-Ratelimit-Remaining: ' + os.environ['REMAINING'], file=sys.stderr)
    print('gh: API rate limit exceeded', file=sys.stderr)
    sys.exit(1)
if os.environ.get('BROKEN'): sys.exit(1)
if os.environ.get('SLOW'): time.sleep(0.15)
if sys.argv[1:3] == ['api', 'graphql']:
    q = next(x[6:] for x in sys.argv if x.startswith('query='))
    for alias, owner, name, number in re.findall(r'(w[0-9]+): repository\\(owner: "([^"]+)", name: "([^"]+)"\\) \\{ pullRequest\\(number: ([0-9]+)', q):
        print(f'{alias}\\thttps://github.com/{owner}/{name}/pull/{number}\\tOPEN\\tfalse\\t' + 'a'*40)
elif sys.argv[1:3] == ['pr', 'view']:
    print(json.dumps(dict(url=sys.argv[3], state=os.environ.get('FORGE_STATE', 'OPEN'), isDraft=False, headRefOid='a'*40)))
elif '--include' in sys.argv:
    second = 'page=2' in sys.argv[2]
    tag = os.environ.get('REST_TAG2' if second else 'REST_TAG', '')
    modified = os.environ.get('REST_MODIFIED', '')
    same = (tag and 'If-None-Match: ' + tag in sys.argv) or (not tag and modified and 'If-Modified-Since: ' + modified in sys.argv)
    print('HTTP/2.0 304 Not Modified' if same else 'HTTP/2.0 200 OK')
    if tag: print('ETag: ' + tag)
    if modified: print('Last-Modified: ' + modified)
    if same:
        print('X-Ratelimit-Remaining: 0')
        print()
        sys.exit(int(os.environ.get('REST_304_EXIT', '0')))
    if os.environ.get('REST_PAGES') and not second:
        print('Link: <https://api.github.com/repos/example/sample/items?page=2>; rel="next"')
    print()
    print(os.environ.get('REST_BODY2' if second else 'REST_BODY', '{}'))
else:
    print(os.environ.get('REST_BODY', '{}'))
''')
script.chmod(0o755)
parent = root / 'parent'
child = root / 'child'
for home in (parent, child):
    home.mkdir()
(child / '.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=' + str(parent) + '\n')
env = dict(os.environ, PATH=str(fake)+os.pathsep+os.environ['PATH'], CALLS=str(root/'calls'),
           FM_HOME=str(parent), FM_ROOT_OVERRIDE=str(repo), FM_GITHUB_CACHE_TTL='300',
           FM_TEST_GITHUB_NOW='10000', GH_TOKEN='fixture-token')
for key in ('FM_STATE_OVERRIDE', 'FM_GITHUB_CACHE_DIR', 'GH_DEBUG'):
    env.pop(key, None)
url = 'https://github.com/example/sample/pull/1'

def run(*args, extra=None, command=None):
    e = dict(env)
    if extra: e.update(extra)
    return subprocess.run([str(command or repo/'bin/fm-github-read.sh'), *args], env=e, text=True, capture_output=True)

def count():
    return len((root/'calls').read_text().splitlines())

def good(result):
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    return result.stdout

assert good(run('core', url, 'state')).strip() == 'OPEN'
assert good(run('core', url, 'head', extra={'FM_HOME':str(child)})).strip() == 'a'*40
assert count() == 1, 'local homes did not share read'
good(run('core', url.replace('example/sample', 'Example/Sample')))
assert count() == 1, 'case aliases duplicated a GitHub PR read'
# Concurrent cold readers share one fetch as well.
url2 = url[:-1] + '2'
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(lambda _: run('core', url2, extra={'SLOW':'1'}), range(4)))
for result in results: good(result)
assert count() == 2, 'concurrent requests duplicated fetch'
query = 'query { w0: repository(owner: "example", name: "sample") { pullRequest(number: 1) { url state isDraft headRefOid } } w1: repository(owner: "example", name: "sample") { pullRequest(number: 3) { url state isDraft headRefOid } } }'
assert len(good(run('batch', query)).splitlines()) == 2
assert count() == 3
assert 'number: 1)' not in json.loads((root/'calls').read_text().splitlines()[-1])[3]
good(run('core', url[:-1]+'3', extra={'FM_HOME':str(child)}))
assert count() == 3, 'batch result not reused by single reader'
good(run('core', url, extra={'FM_TEST_GITHUB_NOW':'10300'}))
assert count() == 4, 'TTL did not expire'
# Refusal blocks different PRs AND cached successes across homes until reset.
result = run('core', url[:-1]+'4', extra={'REFUSED':'1', 'RESET':'11000', 'REMAINING':'0'})
assert result.returncode == 75 and not result.stdout and 'waiting:' in result.stderr
assert count() == 5
result = run('core', url, extra={'FM_HOME':str(child), 'FM_TEST_GITHUB_NOW':'10999'})
assert result.returncode == 75 and not result.stdout
assert count() == 5
poll = run('--validated', 'github', url, 'github.com', 'example/sample', '1',
           command=repo/'bin/fm-pr-poll.sh')
assert poll.returncode == 0 and poll.stdout.startswith('waiting:') and 'merged' not in poll.stdout
assert count() == 5, 'rate-limited poll retried'
meta = parent/'state/sample.meta'
meta.write_text('kind=ship\nworktree=' + str(parent) + '\n')
registration = run('sample', url, command=repo/'bin/fm-pr-check.sh')
assert registration.returncode == 75 and 'waiting:' in registration.stderr
assert not (parent/'state/sample.check.sh').exists()
assert count() == 5, 'registration retried a quota refusal'
good(run('core', url, extra={'FM_TEST_GITHUB_NOW':'11000'}))
assert count() == 6
# Retry-After wins if later than reset; proven hourly exhaustion waits an hour.
result = run('core', url[:-1]+'5', extra={'FM_TEST_GITHUB_NOW':'11000', 'REFUSED':'1', 'RESET':'11100', 'RETRY':'200', 'REMAINING':'0'})
assert result.returncode == 75
assert run('core', url, extra={'FM_TEST_GITHUB_NOW':'11199'}).returncode == 75
good(run('core', url, extra={'FM_TEST_GITHUB_NOW':'11200'}))
result = run('core', url[:-1]+'6', extra={'FM_TEST_GITHUB_NOW':'12000', 'REFUSED':'1', 'REMAINING':'0'})
assert result.returncode == 75
before = count()
assert run('core', url, extra={'FM_TEST_GITHUB_NOW':'15599'}).returncode == 75
assert count() == before
good(run('core', url, extra={'FM_TEST_GITHUB_NOW':'15600'}))
# Ordinary read errors never return an expired green/terminal observation.
result = run('core', url, extra={'FM_TEST_GITHUB_NOW':'16000', 'BROKEN':'1'})
assert result.returncode != 0 and not result.stdout
# Credential changes cannot reuse private observations.
good(run('core', url, extra={'FM_TEST_GITHUB_NOW':'16000', 'GH_TOKEN':'another-fixture-token'}))
assert count() == before+3
# A secondary refusal must ignore the unrelated primary quota reset.
for retry, delay in ((None, 60), ('120', 120)):
    secondary = {'FM_GITHUB_CACHE_DIR':str(root/('secondary-'+str(retry))),
                 'FM_TEST_GITHUB_NOW':'16000', 'REFUSED':'1',
                 'REMAINING':'3309', 'RESET':'19500'}
    if retry is not None: secondary['RETRY'] = retry
    assert run('core', url, extra=secondary).returncode == 75
    assert run('core', url, extra=dict(secondary, FM_TEST_GITHUB_NOW=str(16000+delay-1), REFUSED='')).returncode == 75
    good(run('core', url, extra=dict(secondary, FM_TEST_GITHUB_NOW=str(16000+delay), REFUSED='')))
# Secondary limits without a deadline back off briefly, doubling to 15 minutes.
# Missing quota headers are not evidence of hourly exhaustion either.
for remaining in ('3309', None):
    burst = {'FM_GITHUB_CACHE_DIR':str(root/('burst-'+str(remaining)))}
    if remaining is not None: burst['REMAINING'] = remaining
    tick = 16000
    for delay in (60, 120, 240, 480, 900, 900):
        result = run('core', url, extra=dict(burst, FM_TEST_GITHUB_NOW=str(tick), REFUSED='1'))
        assert result.returncode == 75 and not result.stdout and 'waiting:' in result.stderr
        calls = count()
        result = run('core', url2, extra=dict(burst, FM_HOME=str(child), FM_TEST_GITHUB_NOW=str(tick+delay-1)))
        assert result.returncode == 75 and not result.stdout
        assert count() == calls, 'burst cooldown retried early'
        tick += delay
    good(run('core', url, extra=dict(burst, FM_TEST_GITHUB_NOW=str(tick))))
    # A successful request resets the exponential sequence.
    result = run('core', url2, extra=dict(burst, FM_TEST_GITHUB_NOW=str(tick), REFUSED='1'))
    assert result.returncode == 75
    good(run('core', url2, extra=dict(burst, FM_TEST_GITHUB_NOW=str(tick+60))))
# Generic REST observations share results, while coherence reads stay live.
start = count()
for home in (parent, child):
    good(run('read', 'api', 'repos/example/sample/pulls/9', extra={'FM_HOME':str(home), 'FM_TEST_GITHUB_NOW':'17000'}))
assert count() == start+1
for home in (parent, child):
    good(run('fresh', 'api', 'repos/example/sample/pulls/9', extra={'FM_HOME':str(home), 'FM_TEST_GITHUB_NOW':'17000'}))
assert count() == start+3
for option in ('--method=POST', '-XPOST', '--field', '--raw-field', '--input=data.json'):
    assert run('read', 'api', 'repos/example/sample/issues', option, 'title=x').returncode != 0
assert count() == start+3, 'read wrapper admitted a mutation'
# Expiry revalidates representations; a 304 can be a nonzero gh exit, carries
# no body, and is not exhaustion even when the remaining-quota header is zero.
rest_args = ('read', 'api', 'repos/example/sample/items')
conditional = {'FM_GITHUB_CACHE_DIR':str(root/'conditional'), 'FM_TEST_GITHUB_NOW':'50000',
               'REST_TAG':'"v1"', 'REST_BODY':'{"version":1}', 'REST_MODIFIED':'Wed, 21 Oct 2015 07:28:00 GMT'}
assert json.loads(good(run(*rest_args, extra=conditional))) == {'version':1}
unchanged = dict(conditional, FM_TEST_GITHUB_NOW='50300', REST_304_EXIT='1', REST_BODY='unusable')
assert json.loads(good(run(*rest_args, extra=unchanged))) == {'version':1}
last = json.loads((root/'calls').read_text().splitlines()[-1])
assert 'If-None-Match: "v1"' in last and not any('If-Modified-Since' in x for x in last)
before = count()
good(run(*rest_args, extra=dict(unchanged, FM_TEST_GITHUB_NOW='50599')))
assert count() == before, '304 did not refresh freshness'
replacement = dict(conditional, FM_TEST_GITHUB_NOW='50600', REST_TAG='"v2"', REST_BODY='{"version":2}')
assert json.loads(good(run(*rest_args, extra=replacement))) == {'version':2}
assert json.loads(good(run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='50900', REST_BODY='unusable')))) == {'version':2}
assert 'If-None-Match: "v2"' in json.loads((root/'calls').read_text().splitlines()[-1])
# Fresh reads neither send validators nor return a stored body.
assert json.loads(good(run('fresh', *rest_args[1:], extra=dict(replacement, FM_TEST_GITHUB_NOW='50900', REST_BODY='{"version":3}')))) == {'version':3}
assert not any('If-None-Match' in x for x in json.loads((root/'calls').read_text().splitlines()[-1]))
# Credential partitions do not send another credential's validator.
good(run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='50900', GH_TOKEN='separate-fixture-token')))
assert not any('If-None-Match' in x for x in json.loads((root/'calls').read_text().splitlines()[-1]))
# Last-Modified works when ETag is absent, and no validators means ordinary 200s.
for name, fields, expected in (('modified', {'REST_MODIFIED':'Wed, 21 Oct 2015 07:28:00 GMT'}, 'If-Modified-Since:'),
                               ('unconditional', {}, None)):
    sample = dict(fields, FM_GITHUB_CACHE_DIR=str(root/name), FM_TEST_GITHUB_NOW='50000', REST_BODY='{"version":1}')
    good(run(*rest_args, extra=sample))
    result = good(run(*rest_args, extra=dict(sample, FM_TEST_GITHUB_NOW='50300', REST_BODY='{"version":2}')))
    assert json.loads(result)['version'] == (1 if expected else 2)
    sent = json.loads((root/'calls').read_text().splitlines()[-1])
    assert any(x.startswith(expected) for x in sent) if expected else not any(x.startswith('If-') for x in sent)
# A replacement without validators must discard the old ETag.
good(run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='51200', REST_TAG='', REST_MODIFIED='')))
good(run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='51500')))
assert not any(x.startswith('If-') for x in json.loads((root/'calls').read_text().splitlines()[-1]))
# Refusals/errors during revalidation never return the expired representation.
refusal = dict(replacement, FM_TEST_GITHUB_NOW='51800', REFUSED='1', REMAINING='0', RESET='53000')
result = run(*rest_args, extra=refusal)
assert result.returncode == 75 and not result.stdout and 'waiting:' in result.stderr
assert 'If-None-Match: "v2"' in json.loads((root/'calls').read_text().splitlines()[-1])
assert run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='53000', BROKEN='1')).returncode != 0
# Validators expire in a day even if the entry has not otherwise been evicted.
good(run(*rest_args, extra=dict(replacement, FM_TEST_GITHUB_NOW='140000')))
assert not any(x.startswith('If-') for x in json.loads((root/'calls').read_text().splitlines()[-1]))
# Every page is revalidated separately. A 304 missing Link metadata cannot
# establish pagination topology, so the linked page gets an unconditional read.
paged = dict(conditional, FM_GITHUB_CACHE_DIR=str(root/'paged'), REST_PAGES='1',
             REST_BODY='[1]', REST_BODY2='[2]', REST_TAG2='"page2-v1"')
page_args = (*rest_args, '--paginate', '--slurp')
assert json.loads(good(run(*page_args, extra=paged))) == [[1], [2]]
paged.update(FM_TEST_GITHUB_NOW='50300', REST_TAG2='"page2-v2"', REST_BODY2='[3]')
assert json.loads(good(run(*page_args, extra=paged))) == [[1], [3]]
sent = [json.loads(x) for x in (root/'calls').read_text().splitlines()[-3:]]
assert 'If-None-Match: "v1"' in sent[0] and 'If-None-Match: "page2-v1"' in sent[2]
assert not any(x.startswith('If-') for x in sent[1])
assert json.loads(good(run(*page_args, extra=dict(paged, FM_TEST_GITHUB_NOW='50600', REST_BODY2='unusable')))) == [[1], [3]]
# A 200 with no next link removes the former second page.
paged.update(FM_TEST_GITHUB_NOW='50900', REST_TAG='"shorter"', REST_PAGES='', REST_BODY='[4]')
assert json.loads(good(run(*page_args, extra=paged))) == [[4]]
# Page projections retain raw-string output; unsupported slurp combinations
# remain refused as in gh rather than acquiring new output semantics.
assert good(run(*rest_args, '--jq', '.version', extra=dict(replacement, FM_GITHUB_CACHE_DIR=str(root/'jq')))).strip() == '2'
assert good(run(*rest_args, '--paginate', '--jq', '.[]', extra=dict(paged, REST_BODY='["sample"]'))).strip() == 'sample'
before = count()
assert run(*page_args, '--jq', '.[][]', extra=paged).returncode != 0
assert run(*rest_args, '--slurp', extra=paged).returncode != 0
assert count() == before, 'unsupported slurp combination issued a request'
# A later-page refusal wins over an earlier-page 304 and publishes no partial
# body. After cooldown, the old complete representation can be revalidated.
paged.update(FM_GITHUB_CACHE_DIR=str(root/'paged-refusal'), FM_TEST_GITHUB_NOW='60000',
             REST_PAGES='1', REST_BODY='[1]', REST_BODY2='[2]', REST_TAG='"page1"')
assert json.loads(good(run(*page_args, extra=paged))) == [[1], [2]]
result = run(*page_args, extra=dict(paged, FM_TEST_GITHUB_NOW='60300', REFUSED_PAGE2='1',
                                   RESET='61000', REMAINING='0'))
assert result.returncode == 75 and not result.stdout and 'waiting:' in result.stderr
assert json.loads(good(run(*page_args, extra=dict(paged, FM_TEST_GITHUB_NOW='61000')))) == [[1], [2]]
# A formerly terminal full page can acquire a successor with the same ETag.
# Re-reading missing Link metadata must discover it rather than trust the old
# absence of a next page.
growing = dict(conditional, FM_GITHUB_CACHE_DIR=str(root/'growing'), REST_BODY='[1]', REST_BODY2='[2]')
growing_args = ('read', 'api', 'repos/example/sample/items?per_page=1', '--paginate', '--slurp')
assert json.loads(good(run(*growing_args, extra=growing))) == [[1]]
assert json.loads(good(run(*growing_args, extra=dict(growing, FM_TEST_GITHUB_NOW='50300', REST_PAGES='1')))) == [[1], [2]]
print('PASS: REST 304 reuse/freshness, 200 replacement, validator fallback/expiry, credential partition, fresh bypass, quota refusal and per-page pagination')
# Scripted hour: 8 PRs, two observing homes, two reads each per sweep.
# Baseline individual poll: 8 * 2 * 2 * 12 = 384; cache: 8 * 12 = 96.
fleet_start = count()
for tick in range(12):
    for home in (parent, child):
        for number in range(10, 18):
            for reader in ('state', 'head'):
                good(run('core', f'https://github.com/example/sample/pull/{number}', reader,
                         extra={'FM_HOME':str(home), 'FM_TEST_GITHUB_NOW':str(20000+tick*300)}))
after = count()-fleet_start
assert after == 96, after
print(f'PASS: scripted hour N=8, homes=2, readers=2: before=384, after={after} CLI reads; M=4 external review runs unchanged')
batch_start = count()
query = 'query { ' + ' '.join(f'w{n}: repository(owner: "example", name: "sample") {{ pullRequest(number: {n+20}) {{ url state isDraft headRefOid }} }}' for n in range(8)) + ' }'
for tick in range(12):
    for home in (parent, child):
        assert len(good(run('batch', query, extra={'FM_HOME':str(home), 'FM_TEST_GITHUB_NOW':str(30000+tick*300)})).splitlines()) == 8
assert count()-batch_start == 12
print('PASS: scripted batched hour N=8, homes=2: before=24, after=12 GraphQL requests')
# A quota refusal must suppress even a still-fresh cached terminal success.
terminal = {'FM_GITHUB_CACHE_DIR':str(root/'terminal'), 'FM_TEST_GITHUB_NOW':'40000', 'FORGE_STATE':'MERGED'}
assert good(run('core', url, 'state', extra=terminal)).strip() == 'MERGED'
refusal = dict(terminal, REFUSED='1', RESET='41000', REMAINING='0')
assert run('core', url[:-1]+'9', extra=refusal).returncode == 75
poll = run('--validated', 'github', url, 'github.com', 'example/sample', '1', extra=terminal,
           command=repo/'bin/fm-pr-poll.sh')
assert poll.returncode == 0 and poll.stdout.startswith('waiting:') and 'merged' not in poll.stdout
print('PASS: cross-home and concurrent reuse, batch sharing, expiry, reset, Retry-After, fallback, credential isolation and waiting semantics')
PY
