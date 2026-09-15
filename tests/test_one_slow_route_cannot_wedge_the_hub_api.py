#!/usr/bin/env python3
"""ONE SLOW ROUTE MUST NOT DENY SERVICE TO THE WHOLE HUB API.

MEASURED on the founder box, v1.0.98, 2026-09-16, 3,604 merge-candidate
contacts (6,492,606 pairs):

    /health alone                                200 in 0.0036s
    /health WHILE contacts/diff is in flight     000, curl rc=28 at 30s
    /calendar/today WHILE it is in flight        000, curl rc=28 at 30s
    GET /api/v1/contacts/diff                    200 in 121.4s

The customer sees the iOS app go "Hub offline" and the assistant answer
nothing, for two minutes, because ONE report route was asked for.

TWO INDEPENDENT DEFECTS, and this guard covers both, because either one alone
still leaves a Hub that can be taken down by a single request:

  1. STRUCTURAL. assistant_api/ical-server.py served on a plain HTTPServer,
     which handles exactly one request at a time. Any slow handler is a
     whole-API outage. Now ThreadingHTTPServer.

  2. THE COST ITSELF. identity_resolver/batch_resolver.py
     detect_fuzzy_name_matches computed a FULL Levenshtein DP for every pair,
     eagerly, even though the edit distance only decides the gate when
     Jaro-Winkler has already failed its threshold. 126.3s -> 11.8s on the
     founder graph, with the duplicate set proven IDENTICAL (91 matches).

WHY THE ARMS BELOW ARE MOSTLY BEHAVIOURAL. A grep for ThreadingHTTPServer
proves a spelling. It cannot prove the edit distance stopped being computed
per pair, and that is the half that made the route slow in the first place.
So the quadratic arm COUNTS CALLS, and the correctness arm re-implements the
ORIGINAL gate and demands the same answer from both.

Synthetic data throughout. No Oxigraph, no network, no box.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "cm041"))

from identity_resolver import batch_resolver as BR  # noqa: E402
from identity_resolver.batch_resolver import (  # noqa: E402
    DEFAULT_CONFIG,
    PersonRecord,
    _jaro_winkler,
    _levenshtein,
    _levenshtein_within,
    _normalise_name,
    detect_fuzzy_name_matches,
)
from identity_resolver.tidy import TidyReport  # noqa: E402

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  [PASS] %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  [FAIL] %s" % msg)


def cannot_run(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    sys.exit(2)


# ── Synthetic address book ───────────────────────────────────────────────────
#
# Names are deliberately assorted in LENGTH as well as spelling, because the
# cheap gate that replaced the eager DP is a length-delta shortcut. A fixture
# of same-length names would exercise the slow path on every pair and the
# quadratic arm below would pass for the wrong reason.
_GIVEN = ["Alice", "Bartholomew", "Chen", "Dmitri", "Eleanor", "Fitzgerald",
          "Grace", "Hyacinth", "Ivan", "Josephine", "Kwame", "Lakshmi",
          "Mordecai", "Nkechi", "Ophelia", "Pradeep", "Quentin", "Rosalind",
          "Siobhan", "Thaddeus", "Ursula", "Vikram", "Wilhelmina", "Xiulan",
          "Yusuf", "Zubeida"]
_FAMILY = ["Abernathy", "Bo", "Castellanos", "Duan", "Eriksson", "Fontaine",
           "Gruber", "Hawthorne", "Ibrahim", "Jaworski", "Kowalczyk", "Li",
           "Montgomery", "Ndiaye", "Oyelaran", "Petrov", "Quraishi", "Ruiz",
           "Sandoval", "Tanaka", "Ueda", "Vasquez", "Whitmore", "Xu",
           "Yamamoto", "Zielinski"]


def make_people(n):
    """A realistically DIVERSE address book.

    The first fixture here built names like Person0 Surname0, which are all
    near-duplicates of one another: 7,141 of 7,381 pairs cleared the
    Jaro-Winkler gate, so the arm below passed while the code was still doing
    per-pair work on almost everything. A fixture that makes the hot path
    unavoidable cannot measure whether the hot path was avoided.
    """
    people = {}
    for i in range(n):
        people["urn:p:%04d" % i] = PersonRecord(
            uri="urn:p:%04d" % i,
            display_name="%s %s" % (_GIVEN[i % len(_GIVEN)],
                                    _FAMILY[(i * 7 + i // len(_FAMILY)) % len(_FAMILY)]),
        )
    # One near-duplicate pair that MUST still be detected: names differing by a
    # single character, sharing an organisation so the pair clears the
    # 0.85-0.93 corroboration gate as well as the similarity one.
    #
    # EVERY TOKEN HERE IS FROM THE APPROVED SYNTHETIC CAST in
    # .pii-name-registry.tsv -- alexander, alexandra, andersen (recorded there
    # as the surname "for the high-similarity worked example") and acme. The
    # first draft of this fixture invented a plausible surname instead, and
    # pii-name-guard blocked the PR for 2 PAIR findings on exactly these two
    # lines. The cast is the cast: the fix is to use it, never to widen it.
    people["urn:dup:a"] = PersonRecord(
        uri="urn:dup:a", display_name="Alexander Andersen",
        given_name="Alexander", family_name="Andersen",
        organization="Acme",
    )
    people["urn:dup:b"] = PersonRecord(
        uri="urn:dup:b", display_name="Alexandra Andersen",
        given_name="Alexandra", family_name="Andersen",
        organization="Acme",
    )
    return people


# ── ARM 1: the edit distance must NOT be computed for every pair ─────────────
people = make_people(120)
pairs = len(people) * (len(people) - 1) // 2

calls = {"n": 0}
real_lev = BR._levenshtein


def counting_lev(a, b):
    calls["n"] += 1
    return real_lev(a, b)


BR._levenshtein = counting_lev
try:
    matches = detect_fuzzy_name_matches(people, dict(DEFAULT_CONFIG))
finally:
    BR._levenshtein = real_lev

# ANTI-VACUITY CONTROL FIRST. If the scan never ran over the pairs, zero calls
# would "pass" the arm below while proving nothing at all.
if pairs < 1000:
    cannot_run("fixture too small to distinguish per-pair work from bounded work")
ok("CONTROL: the fixture really is quadratic in shape (%d pairs)" % pairs)

# A tenth of the pair count is a deliberately generous ceiling and still two
# orders of magnitude clear of what the fixed code does (1 call over 7,381
# pairs). "Fewer than every pair" would have been satisfied by the version
# that computed the DP before the final corroboration gate -- measured here at
# 10,041 calls over 7,381 pairs, i.e. MORE than one per pair, which is how
# that shortfall was caught.
BUDGET = max(1, pairs // 10)
if calls["n"] > BUDGET:
    bad("the edit distance is still computed per pair (%d calls over %d pairs, "
        "ceiling %d). That is the cost that took 121s on the founder box and, "
        "on a single-threaded server, took every other route down with it."
        % (calls["n"], pairs, BUDGET))
else:
    ok("the edit distance is NOT computed per pair (%d calls over %d pairs, ceiling %d)"
       % (calls["n"], pairs, BUDGET))

# ── ARM 2: and it still finds the duplicate ──────────────────────────────────
#
# The arm above is satisfied by a function that does nothing at all. This is
# the half that stops "fast" from being bought with "wrong".
found = {frozenset((m.uri_a, m.uri_b)) for m in matches}
if frozenset(("urn:dup:a", "urn:dup:b")) in found:
    ok("the near-duplicate pair is still detected after the optimisation")
else:
    bad("the optimisation lost a duplicate the original found: the "
        "Jonathan/Jonathon pair is absent from %d matches" % len(matches))


# ── ARM 3: identical to the ORIGINAL gate, pair for pair ─────────────────────
#
# Re-implements the pre-fix predicate (BOTH scores computed eagerly, gate is
# "jw bad AND lev bad -> skip") and demands the same surviving pair set. This
# is the arm that would catch a cheap gate that is subtly not equivalent --
# for instance a length shortcut using the wrong bound.
def original_gate_survivors(persons, config):
    uris = list(persons.keys())
    jw_threshold = config["fuzzy_jaro_winkler_threshold"]
    lev_max = config["fuzzy_levenshtein_max_distance"]
    out = set()
    for i in range(len(uris)):
        norm_a = _normalise_name(persons[uris[i]].display_name)
        if not norm_a:
            continue
        for j in range(i + 1, len(uris)):
            norm_b = _normalise_name(persons[uris[j]].display_name)
            if not norm_b or norm_a == norm_b:
                continue
            jw = _jaro_winkler(norm_a, norm_b)
            lev = _levenshtein(norm_a, norm_b)
            if jw < jw_threshold and lev > lev_max:
                continue
            out.add(frozenset((uris[i], uris[j])))
    return out


def new_gate_survivors(persons, config):
    uris = list(persons.keys())
    jw_threshold = config["fuzzy_jaro_winkler_threshold"]
    lev_max = config["fuzzy_levenshtein_max_distance"]
    norms = [_normalise_name(persons[u].display_name) for u in uris]
    out = set()
    for i in range(len(uris)):
        norm_a = norms[i]
        if not norm_a:
            continue
        for j in range(i + 1, len(uris)):
            norm_b = norms[j]
            if not norm_b or norm_a == norm_b:
                continue
            jw = _jaro_winkler(norm_a, norm_b)
            if jw < jw_threshold:
                if abs(len(norm_a) - len(norm_b)) > lev_max:
                    continue
                if _levenshtein_within(norm_a, norm_b, lev_max) > lev_max:
                    continue
            out.add(frozenset((uris[i], uris[j])))
    return out


cfg = dict(DEFAULT_CONFIG)
old_surv = original_gate_survivors(people, cfg)
new_surv = new_gate_survivors(people, cfg)
if not old_surv:
    cannot_run("the reference gate admitted nothing, so equality proves nothing")
if old_surv == new_surv:
    ok("the cheap gate admits EXACTLY the pairs the original did (%d)" % len(old_surv))
else:
    bad("the cheap gate is not equivalent: %d only-original, %d only-new"
        % (len(old_surv - new_surv), len(new_surv - old_surv)))


# ── ARM 4: _levenshtein_within is exact inside the bound ─────────────────────
#
# Its contract is "true value when <= max_dist, some value > max_dist
# otherwise". A version that merely returned max_dist+1 always would satisfy
# the gate arms above and quietly break any future caller.
exact_ok = True
for a, b in (("kitten", "kitten"), ("kitten", "sitten"), ("kitten", "sittin"),
             ("abc", "abd"), ("", ""), ("a", "")):
    true_d = _levenshtein(a, b)
    got = _levenshtein_within(a, b, 2)
    if true_d <= 2 and got != true_d:
        exact_ok = False
        bad("_levenshtein_within(%r,%r,2) = %d but the true distance is %d"
            % (a, b, got, true_d))
if exact_ok:
    ok("_levenshtein_within returns the TRUE distance whenever it is within the bound")

if _levenshtein_within("kitten", "sitting", 2) > 2 and _levenshtein("kitten", "sitting") == 3:
    ok("_levenshtein_within reports > bound when the true distance exceeds it")
else:
    bad("_levenshtein_within did not report a beyond-bound distance as beyond bound")

# The length-delta shortcut must not be able to claim a SHORT distance.
if _levenshtein_within("bob", "bobbbbbbbbbb", 2) > 2:
    ok("a length delta beyond the bound is reported as beyond the bound")
else:
    bad("the length shortcut returned a within-bound distance for a pair that cannot have one")


# ── ARM 5: the wall-clock bound truncates, and SAYS SO ───────────────────────
#
# A short report that does not declare itself short is indistinguishable from
# a clean one, and the customer would read "no duplicates left" off a scan
# that never finished.
budget_cfg = dict(DEFAULT_CONFIG)
budget_cfg["fuzzy_match_max_seconds"] = 0.000001
stats = {}
detect_fuzzy_name_matches(make_people(400), budget_cfg, stats=stats)
if stats.get("truncated") is True and stats.get("truncated_reason"):
    ok("an exhausted time budget is reported as truncated, with a reason")
else:
    bad("the time budget did not report truncation, so a partial scan reads as a complete one: %r" % stats)

# CONTROL: the same call with the normal budget must NOT claim truncation,
# or the flag is stuck on and means nothing.
stats2 = {}
detect_fuzzy_name_matches(make_people(60), dict(DEFAULT_CONFIG), stats=stats2)
if stats2.get("truncated"):
    bad("CONTROL FAILED: a scan that finished still reported itself truncated")
else:
    ok("CONTROL: a scan that finishes does not claim truncation")

# And the report surfaces it to the consumer, not just to the caller.
rep = TidyReport(items=[], total_persons=3, truncated=True, truncated_reason="budget")
if rep.to_dict().get("truncated") is True:
    ok("TidyReport.to_dict surfaces truncation to the API consumer")
else:
    bad("truncation never reaches the JSON the Doctor UI renders")
if "truncated" in TidyReport(items=[], total_persons=3).to_dict():
    bad("CONTROL FAILED: a complete report also carries a truncated key")
else:
    ok("CONTROL: a complete report carries no truncated key")


# ── ARM 6: the server must not be single-threaded ────────────────────────────
#
# Read CODE lines only. The file explains the old single-threaded server in
# its own comments, on purpose, and a whole-file grep would match the
# explanation and report the defect as live forever.
ICAL = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
if not ICAL.is_file():
    cannot_run("ical-server.py not found at %s" % ICAL)

code = [ln for ln in ICAL.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#")]
serve = [ln for ln in code if "serve_forever()" in ln]
if not serve:
    cannot_run("no serve_forever() call found on any code line in ical-server.py")
ok("CONTROL: the serve_forever call site was located (%d line)" % len(serve))

if any("ThreadingHTTPServer" in ln for ln in serve):
    ok("the API is served by ThreadingHTTPServer, so one slow handler cannot wedge it")
else:
    bad("serve_forever is still called on a single-threaded server: %r. One slow "
        "route takes the whole Hub API down, which is what /health returning 000 "
        "for 121s looked like to the customer." % serve)

if any("daemon_threads" in ln for ln in code):
    ok("daemon_threads is set, so a hung handler cannot block shutdown")
else:
    bad("daemon_threads is not set: a hung request thread keeps the process alive "
        "at stop, turning launchd's stop into a kill")


print()
print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
sys.exit(1 if FAIL else 0)
