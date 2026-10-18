#!/usr/bin/env python3
"""Branch hygiene gate. FAILS if, on the remote:
  (a) a branch is the head of a MERGED PR, has no open PR, and its tip is older than 24h
  (b) a branch has NO PR in any state, and its tip is older than 7 days
Exempt: main, cut/*, bom/*, release/*, integration/*, graveyard/*, and any branch with an open PR.
Compares epoch seconds (committedDate parsed to UTC), never ISO strings.
Usage: branch_hygiene_gate.py [--repo owner/name] | --self-test
"""
import datetime, json, re, subprocess, sys

EXEMPT = re.compile(r'^(main|cut/|bom/|release/|integration/|graveyard/|archive/)')
H24, D7 = 86400, 7 * 86400


def epoch(s):
    return int(datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp())


def classify(name, tip_epoch, now, open_n, merged_n, any_n):
    """Return None if fine, else a violation string. Counts are ints, never fields."""
    if EXEMPT.match(name) or open_n > 0:
        return None
    age = now - tip_epoch
    if merged_n > 0 and age > H24:
        return 'merged-PR head older than 24h'
    if any_n == 0 and age > D7:
        return 'no PR and older than 7 days'
    return None


def gh(*a):
    p = subprocess.run(['gh'] + list(a), capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit('CANNOT-RUN: gh %s: %s' % (' '.join(a[:3]), p.stderr.strip()[:200]))
    return p.stdout


def branches(repo):
    o, n = repo.split('/')
    q = ('query($o:String!,$n:String!,$c:String){repository(owner:$o,name:$n){refs(refPrefix:"refs/heads/",'
         'first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{name target{... on Commit{committedDate}}}}}}')
    out, c = [], None
    while True:
        a = ['api', 'graphql', '-f', 'query=' + q, '-f', 'o=' + o, '-f', 'n=' + n]
        if c:
            a += ['-f', 'c=' + c]
        d = json.loads(gh(*a))['data']['repository']['refs']
        out += [(x['name'], epoch(x['target']['committedDate'])) for x in d['nodes']]
        if not d['pageInfo']['hasNextPage']:
            return out
        c = d['pageInfo']['endCursor']


def count(repo, branch, state):
    return int(gh('pr', 'list', '-R', repo, '--head', branch, '--state', state, '--limit', '5',
                  '--json', 'number', '-q', 'length').strip())


def self_test():
    now = 10_000_000
    cases = [
        ('feat/x', now - 2 * 86400, 0, 1, 1, 'merged-PR head older than 24h'),
        ('feat/x', now - 3600, 0, 1, 1, None),
        ('feat/y', now - 8 * 86400, 0, 0, 0, 'no PR and older than 7 days'),
        ('feat/y', now - 6 * 86400, 0, 0, 0, None),
        ('feat/z', now - 90 * 86400, 1, 1, 2, None),
        ('cut/v1.0.1', now - 90 * 86400, 0, 0, 0, None),
        ('feat/closed', now - 30 * 86400, 0, 0, 1, None),
    ]
    bad = [c for c in cases if classify(c[0], c[1], now, c[2], c[3], c[4]) != c[5]]
    print('self-test', 'FAIL %r' % bad if bad else 'ok (%d cases, both directions)' % len(cases))
    return 1 if bad else 0


def main():
    if '--self-test' in sys.argv:
        sys.exit(self_test())
    repo = sys.argv[sys.argv.index('--repo') + 1] if '--repo' in sys.argv else \
        gh('repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner').strip()
    if self_test():
        sys.exit(1)
    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    bl = branches(repo)
    bad = []
    for name, tip in bl:
        if EXEMPT.match(name):
            continue
        o = count(repo, name, 'open')
        m = count(repo, name, 'merged') if o == 0 else 0
        a = count(repo, name, 'all') if o == 0 else 1
        v = classify(name, tip, now, o, m, a)
        if v:
            bad.append((name, v, (now - tip) // 86400))
    print('examined %d branches in %s' % (len(bl), repo))
    for n, v, d in sorted(bad):
        print('VIOLATION %-60s %s (%dd)' % (n, v, d))
    print('%d violation(s)' % len(bad))
    sys.exit(1 if bad else 0)


main()
