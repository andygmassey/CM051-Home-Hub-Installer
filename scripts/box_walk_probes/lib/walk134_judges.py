#!/usr/bin/env python3
"""scripts/box_walk_probes/lib/walk134_judges.py

The pure judges behind four 134 thin-walk probes. Each probe shell script
fetches raw evidence from the box and hands it here; this file decides. Keeping
the decision in one place means --self-test drives the SAME functions the live
probe uses, over known-good and known-bad fixtures, with no box.

Verdicts: PASS, FAIL, CANNOT (CANNOT-RUN). A missing instrument is CANNOT,
never PASS. Synthetic fixtures only: no real names, addresses or numbers.

  judge enrich      <enrich.log>        enrichment_reaches_clients
  judge decline     <config/.env> <agent_loaded 0|1>   enrichment_decline_survives_upgrade
  judge themes      <raw curl -i output>               derived_themes_still_learning
  judge proxy       <control raw> <header raw> <query raw>   proxy_reads_are_owner_own_brief

Exit: 0 PASS, 1 FAIL, 78 CANNOT-RUN, 2 usage. --self-test exits 1 once every
negative control went red and every positive control held (the convention the
apple-music judges use: the CI step asserts rc 1 and the line
"negative controls behaved").
"""
from __future__ import annotations

import json
import re
import sys

PASS, FAIL, CANNOT = "PASS", "FAIL", "CANNOT"

# The seven clients the 134 must-check names. The enricher prints ONE counts-only
# line per batch (enricher.py enrich_batch, finally-block):
#   enrichment looked up per client: music=N books=N films=N podcasts=N places=N food=N interests=N
# Absent that line, every client is NOT MEASURED and the verdict is CANNOT-RUN.
CLIENTS = ["music", "books", "films", "podcasts", "places", "food", "interests"]

_LOOKED = re.compile(r"creators looked up: (\d+)\s*$")
_DROPPED = re.compile(r"creators dropped: contact store unreadable: (\d+)")
_PER_CLIENT = re.compile(r"enrichment looked up per client:((?: [a-z]+=\d+)+)\s*$")
_COMPLETED = re.compile(r"Completed ([A-Za-z_]+): (\d+) enriched")


def judge_enrich(log_text):
    """Last batch in the log. Returns (verdict, reason, examined, unmeasured)."""
    lines = log_text.splitlines()
    looked = [m.group(1) for ln in lines for m in [_LOOKED.search(ln)] if m]
    dropped = [m.group(1) for ln in lines for m in [_DROPPED.search(ln)] if m]
    if not looked:
        return (CANNOT, "no 'creators looked up' line in enrich.log: no enrich batch has run since the seed", 0, CLIENTS)
    if not dropped:
        return (FAIL, "the batch wrote 'creators looked up' but no contact-loader line ('creators dropped: contact store unreadable'): the loader's result is not on the record", len(looked), CLIENTS)
    m = int(looked[-1])
    if m <= 0:
        return (FAIL, "creators looked up: %d on the last batch: enrichment reached no creator" % m, len(looked), CLIENTS)
    # Per-category lines: a category the log names with 0 enriched is a FAIL.
    done = {}
    for ln in lines:
        mm = _COMPLETED.search(ln)
        if mm:
            done[mm.group(1).lower()] = int(mm.group(2))
    zero = [c for c, n in sorted(done.items()) if n == 0]
    if zero:
        return (FAIL, "categories completed with 0 enriched: %s" % ", ".join(zero), len(done), CLIENTS)
    # Per-client evidence: the LAST per-client line. PASS only when every client has
    # its own measured look-up count above zero; a zero or a missing client is a FAIL.
    perc = [m.group(1) for ln in lines for m in [_PER_CLIENT.search(ln)] if m]
    if not perc:
        return (CANNOT, "creators looked up: %d and the contact-loader line are present, but the log has no 'enrichment looked up per client' line: %s unmeasured" % (m, ", ".join(CLIENTS)), len(looked), CLIENTS)
    counts = {k: int(v) for k, v in (t.split("=") for t in perc[-1].split())}
    missing = [c for c in CLIENTS if c not in counts]
    if missing:
        return (FAIL, "the per-client line does not name: %s" % ", ".join(missing), len(CLIENTS) - len(missing), missing)
    zero = [c for c in CLIENTS if counts[c] == 0]
    if zero:
        return (FAIL, "clients with 0 look-ups on the last batch: %s" % ", ".join(zero), len(CLIENTS), [])
    return (PASS, "creators looked up: %d; every client reached (%s)" % (m, " ".join("%s=%d" % (c, counts[c]) for c in CLIENTS)), len(CLIENTS), [])


def _decision(env_text):
    """Mirror of install.sh's ostler_public_lookups_flag reader: the LAST
    OSTLER_CONSENT_ENRICHMENT_DECISION= line, quotes stripped. None if absent."""
    val = None
    for ln in env_text.splitlines():
        if ln.startswith("OSTLER_CONSENT_ENRICHMENT_DECISION="):
            val = ln[len("OSTLER_CONSENT_ENRICHMENT_DECISION="):]
    if val is None:
        return None
    return val.strip('"')


def judge_decline(env_text, agent_loaded):
    """A prior install that declined must still be declined, with no agent."""
    if env_text is None:
        return (CANNOT, "config/.env is unreadable: the recorded decision is unmeasured", 0, [])
    dec = _decision(env_text)
    if dec is None:
        return (CANNOT, "config/.env has no OSTLER_CONSENT_ENRICHMENT_DECISION line: nothing recorded to test", 1, [])
    if dec != "declined":
        return (CANNOT, "recorded decision is '%s', not 'declined': this box is not in the declined state, so the decline survival is not under test" % dec, 1, [])
    flag = "agreed" if dec == "accepted" else "off"
    if flag != "off":
        return (FAIL, "recorded decline reads as public look-ups agreed", 2, [])
    if agent_loaded:
        return (FAIL, "the decision is declined but com.ostler.enrich is loaded: the agent outlived the decline", 2, [])
    return (PASS, "recorded decision is declined, public look-ups read off, com.ostler.enrich not loaded", 2, [])


def _split(raw):
    """Split curl -i output into (status, headers dict lower-cased, body)."""
    raw = raw or ""
    head, sep, body = raw.partition("\r\n\r\n")
    if not sep:
        head, sep, body = raw.partition("\n\n")
    status = None
    headers = {}
    for i, ln in enumerate(head.splitlines()):
        if i == 0 and ln.startswith("HTTP/"):
            parts = ln.split()
            if len(parts) > 1 and parts[1].isdigit():
                status = int(parts[1])
            continue
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers, body


def judge_themes(raw):
    status, _h, body = _split(raw)
    if status is None:
        return (CANNOT, "no HTTP status line from the Doctor: nothing measured", 0, [])
    if status != 200:
        return (FAIL, "GET /api/v1/preferences/derived answered HTTP %d, not 200" % status, 1, [])
    try:
        doc = json.loads(body)
    except ValueError:
        return (FAIL, "GET /api/v1/preferences/derived returned a body that is not JSON", 1, [])
    if not isinstance(doc, dict):
        return (FAIL, "derived response is not a JSON object", 1, [])
    if "error" in doc:
        return (FAIL, "derived response carries an error field: %r" % (doc.get("error"),), 1, [])
    items = doc.get("items")
    if items is None:
        return (FAIL, "derived response has no items key at all", 1, [])
    if items:
        # Served items are a STRONGER pass than "still learning": the surface is live and
        # answering with owner data. The still-learning state is for an empty box only.
        return (PASS, "derived response has no error and serves %d derived items (the surface is live; not the still-learning state)" % len(items), 1, [])
    sl = doc.get("still_learning")
    if not isinstance(sl, dict) or "Still learning" not in str(sl.get("text", "")):
        return (FAIL, "no levelled records and no 'Still learning' state in the response", 1, [])
    return (PASS, "items empty and still_learning reads: %s" % sl.get("text"), 1, [])


PRIVATE_LABEL = '"privacy_label": "private"'


def _arm(raw):
    status, headers, body = _split(raw)
    compact = body.replace(" ", "")
    private = '"privacy_label":"private"' in compact or PRIVATE_LABEL in body
    return status, headers.get("x-ostler-served-for"), private


def judge_proxy(control_raw, header_raw, query_raw):
    """control: direct ical-server from the box loopback, owner_local claim.
    header/query: the Doctor proxy with the claim. Both proxy arms must be
    served_for owner_own_brief with no private-labelled row in the body."""
    cs, cserved, cprivate = _arm(control_raw)
    if cs is None:
        return (CANNOT, "control arm: no HTTP status: nothing measured", 0, [])
    if cs != 200:
        return (CANNOT, "control arm answered HTTP %s, not 200: the owner_local control is not readable" % cs, 1, [])
    if cserved != "owner_local":
        return (CANNOT, "control arm served_for=%r, not owner_local: the loopback claim is not honoured here, so the proxy arms prove nothing" % cserved, 1, [])
    if not cprivate:
        return (CANNOT, "control arm (owner_local) shows no private-labelled row: no L3 seed row is visible, so its absence is not provable", 1, [])
    problems = []
    for name, raw in (("header", header_raw), ("query", query_raw)):
        st, served, private = _arm(raw)
        if st is None or st != 200:
            return (CANNOT, "%s arm answered HTTP %s, not 200: nothing measured" % (name, st), 2, [])
        if served != "owner_own_brief":
            problems.append("%s arm served_for=%r, not owner_own_brief" % (name, served))
        if private:
            problems.append("%s arm body carries a private-labelled row (the L3 seed)" % name)
    if problems:
        return (FAIL, "; ".join(problems), 3, [])
    return (PASS, "header and query claims through the Doctor proxy are served owner_own_brief; the L3 seed row (private-labelled in the owner_local control) is absent", 3, [])


# ---------------------------------------------------------------- self-test

_ENRICH_GOOD = """\
2026-11-18 INFO creators dropped: contact store unreadable: 0
2026-11-18 INFO creators looked up: 12
[PARALLEL] Completed music: 4 enriched
[PARALLEL] Completed books: 3 enriched
"""


def _cases():
    """(name, want_verdict, actual_verdict) built by running the judges."""
    out = []
    # enrich
    out.append(("enrich: no batch line -> CANNOT", CANNOT, judge_enrich("nothing here\n")[0]))
    out.append(("enrich: looked up 0 -> FAIL", FAIL,
                judge_enrich(_ENRICH_GOOD.replace("looked up: 12", "looked up: 0"))[0]))
    out.append(("enrich: loader line missing -> FAIL", FAIL,
                judge_enrich("creators looked up: 5\n")[0]))
    out.append(("enrich: a completed category with 0 -> FAIL", FAIL,
                judge_enrich(_ENRICH_GOOD + "[PARALLEL] Completed food: 0 enriched\n")[0]))
    out.append(("enrich: good log, no per-client counts -> CANNOT", CANNOT, judge_enrich(_ENRICH_GOOD)[0]))
    out.append(("enrich: Completed lines alone are not per-client evidence -> CANNOT", CANNOT,
                judge_enrich(_ENRICH_GOOD + "".join("[PARALLEL] Completed %s: 2 enriched\n" % c for c in CLIENTS))[0]))
    line = "enrichment looked up per client: music=3 books=2 films=2 podcasts=1 places=2 food=1 interests=2\n"
    out.append(("enrich: per-client line, every client > 0 -> PASS", PASS, judge_enrich(_ENRICH_GOOD + line)[0]))
    out.append(("enrich: per-client line, one client 0 -> FAIL", FAIL,
                judge_enrich(_ENRICH_GOOD + line.replace("podcasts=1", "podcasts=0"))[0]))
    out.append(("enrich: per-client line missing a client -> FAIL", FAIL,
                judge_enrich(_ENRICH_GOOD + line.replace(" food=1", ""))[0]))
    # decline
    dec = 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n'
    out.append(("decline: declined, no agent -> PASS", PASS, judge_decline(dec, 0)[0]))
    out.append(("decline: declined but agent loaded -> FAIL", FAIL, judge_decline(dec, 1)[0]))
    out.append(("decline: accepted -> CANNOT (not the declined state)", CANNOT,
                judge_decline('OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n', 0)[0]))
    out.append(("decline: no config file -> CANNOT", CANNOT, judge_decline(None, 0)[0]))
    out.append(("decline: stale accepted line overridden by later declined -> PASS", PASS,
                judge_decline('OSTLER_CONSENT_ENRICHMENT_DECISION=accepted\nOSTLER_CONSENT_ENRICHMENT_DECISION=declined\n', 0)[0]))
    # themes
    still = '{"items": [], "still_learning": {"interests_so_far": 5, "text": "Still learning: 5 interests found so far"}}'
    out.append(("themes: still learning -> PASS", PASS,
                judge_themes("HTTP/1.1 200 OK\nContent-Type: application/json\n\n" + still)[0]))
    out.append(("themes: 500 -> FAIL", FAIL, judge_themes("HTTP/1.1 500 Internal\n\n{}")[0]))
    out.append(("themes: error field with empty items -> FAIL", FAIL,
                judge_themes("HTTP/1.1 200 OK\n\n" + '{"items": [], "error": "store down"}')[0]))
    out.append(("themes: empty items, no still_learning -> FAIL", FAIL,
                judge_themes("HTTP/1.1 200 OK\n\n" + '{"items": []}')[0]))
    out.append(("themes: items present, no error -> PASS (served items)", PASS,
                judge_themes("HTTP/1.1 200 OK\n\n" + '{"items": [{"name": "x"}], "still_learning": null}')[0]))
    out.append(("themes: items present WITH an error field -> FAIL", FAIL,
                judge_themes("HTTP/1.1 200 OK\n\n" + '{"items": [{"name": "x"}], "error": "partial"}')[0]))
    # proxy
    def raw(served, body):
        h = "HTTP/1.1 200 OK\r\nX-Ostler-Served-For: %s\r\nContent-Type: application/json\r\n\r\n" % served
        return h + body
    priv_body = '{"events": [{"title": "synthetic", "privacy_label": "private"}]}'
    clean_body = '{"events": [{"title": "synthetic"}]}'
    ctrl = raw("owner_local", priv_body)
    out.append(("proxy: good arms -> PASS", PASS,
                judge_proxy(ctrl, raw("owner_own_brief", clean_body), raw("owner_own_brief", clean_body))[0]))
    out.append(("proxy: header arm served owner_local -> FAIL", FAIL,
                judge_proxy(ctrl, raw("owner_local", clean_body), raw("owner_own_brief", clean_body))[0]))
    out.append(("proxy: query arm leaks a private row -> FAIL", FAIL,
                judge_proxy(ctrl, raw("owner_own_brief", clean_body), raw("owner_own_brief", priv_body))[0]))
    out.append(("proxy: control not owner_local -> CANNOT", CANNOT,
                judge_proxy(raw("owner_own_brief", priv_body), raw("owner_own_brief", clean_body), raw("owner_own_brief", clean_body))[0]))
    out.append(("proxy: control has no private row -> CANNOT", CANNOT,
                judge_proxy(raw("owner_local", clean_body), raw("owner_own_brief", clean_body), raw("owner_own_brief", clean_body))[0]))
    out.append(("proxy: arm 503 -> CANNOT, not PASS", CANNOT,
                judge_proxy(ctrl, "HTTP/1.1 503 Service Unavailable\r\n\r\n", raw("owner_own_brief", clean_body))[0]))
    return out


def self_test():
    cases = _cases()
    bad = [c for c in cases if c[1] != c[2]]
    for name, want, got in cases:
        mark = "held  " if want == got else "WRONG "
        print("  %s %-62s want=%-6s got=%s" % (mark, name, want, got))
    if bad:
        print("self-test: %d of %d cases gave the wrong verdict" % (len(bad), len(cases)))
        return 2
    neg = sum(1 for c in cases if c[1] != PASS)
    print("self-test: %d cases, %d negative controls (non-PASS) all went red as wanted" % (len(cases), neg))
    print("negative controls behaved")
    return 1


_EXIT = {PASS: 0, FAIL: 1, CANNOT: 78}


def _emit(res):
    verdict, reason, examined, unmeasured = res
    print("EXAMINED: %s" % examined)
    if unmeasured:
        print("NOT MEASURED: %s" % ", ".join(unmeasured))
    print("JUDGE: %s -- %s" % (verdict, reason))
    return _EXIT[verdict]


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if len(argv) >= 2 and argv[0] == "enrich":
        return _emit(judge_enrich(open(argv[1], encoding="utf-8", errors="replace").read()))
    if len(argv) == 3 and argv[0] == "decline":
        env = None if argv[1] == "-" else open(argv[1], encoding="utf-8", errors="replace").read()
        return _emit(judge_decline(env, argv[2] == "1"))
    if len(argv) == 2 and argv[0] == "themes":
        return _emit(judge_themes(open(argv[1], encoding="utf-8", errors="replace").read()))
    if len(argv) == 4 and argv[0] == "proxy":
        rd = lambda p: open(p, encoding="utf-8", errors="replace").read()
        return _emit(judge_proxy(rd(argv[1]), rd(argv[2]), rd(argv[3])))
    print("usage: walk134_judges.py --self-test | enrich <log> | decline <env|-> <0|1> | themes <raw> | proxy <control> <header> <query>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
