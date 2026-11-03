#!/usr/bin/env python3
"""walk_fixture_122b2.py -- synthetic seed + judges for two v1.0.122 walk probes.

  meetings_index_lists_meetings_not_holidays   (#2525)
  birthday_listed_once_per_person              (duplicate birthdays in the brief)

BOX SIDE (run with ~/.ostler/import-pipeline/.venv/bin/python, which carries the
store-auth shim; no credential is handled here):

  meetings seed|forget|count     a synthetic public holiday (no time, no attendee) and
                                 a synthetic meeting (timed, with an attendee)
  bday seed|forget|count|raw|served|brief
                                 one Person that lives on TWO nodes (a survivor and a
                                 merged-in second card), each carrying the birthday, the
                                 survivor with two display names: the shape that listed a
                                 person four times before people_birthdays kept one row
                                 per live person URI. `brief` runs an undelivered copy of the
                                 morning-brief job and counts the person in its birthday lines.

  count prints the number of triples whose subject OR object is in the fixture
  namespace. forget must take it back to 0; the probe pastes before and after.

PURE JUDGES (no box, no network; what the self-test drives):

  judge_meetings(index_text, expect_holiday=False)
  judge_birthday(served_rows, raw_rows)

Everything is synthetic: example.com IRIs, invented names.
"""
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

PWG = "https://schema.ostler.ai/ontology#"
NS = "https://example.com/walkfixture122b2/"
SOURCE = "walkfixture122b2"

HOLIDAY_TITLE = "Walkfixture Bank Holiday"
MEETING_TITLE = "Walkfixture Planning Review"
SURNAME = "Quillfeather"
NAMES = ("Walkfixture " + SURNAME, "Wally " + SURNAME)

# One calendar day long ago enough to be PAST in every walk, so both land in the
# month groups and neither is "upcoming".
DAY = "2026-09-28"


def _lit(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


# ---------------------------------------------------------------------------
# pure judges
# ---------------------------------------------------------------------------

def judge_meetings(index_text, expect_holiday=False):
    """-> (state, detail). state in ok|FAIL|CANNOT.

    CANNOT when the index is empty or has no meetings heading: an unreadable
    index must not read as "the holiday is absent". The default expectation is
    the product ruling (meeting present, holiday absent); expect_holiday=True is
    the NEGATIVE CONTROL and must FAIL on a correct compile."""
    if not (index_text or "").strip():
        return "CANNOT", "Meetings/index.md is empty or unreadable"
    if "title: Meetings" not in index_text:
        return "CANNOT", "Meetings/index.md has no 'title: Meetings' front matter, not the index this probe reads"
    has_m = MEETING_TITLE in index_text
    has_h = HOLIDAY_TITLE in index_text
    want_h = bool(expect_holiday)
    if has_m and has_h == want_h:
        return "ok", "meeting present, holiday %s" % ("present (as expected by the control)" if want_h else "absent")
    bits = []
    if not has_m:
        bits.append("the timed meeting with an attendee is MISSING from the index")
    if has_h != want_h:
        bits.append("the holiday is %s (expected %s)" % ("PRESENT" if has_h else "absent",
                                                         "present" if want_h else "absent"))
    return "FAIL", "; ".join(bits)


def judge_birthday(served_rows, raw_rows):
    """-> (state, detail). served_rows = the fixture person's entries in the served
    birthdays list; raw_rows = how many rows the store gives BEFORE any dedupe.

    A served count of 1 over raw_rows < 2 is a VACUOUS pass (nothing was there to
    dedupe), so it is CANNOT, not ok."""
    if served_rows is None or raw_rows is None:
        return "CANNOT", "served or raw birthday rows could not be read"
    if raw_rows < 2:
        return "CANNOT", ("only %d raw row(s) for the fixture person: the seed offers the dedupe "
                          "nothing to do, so a served count of %d proves nothing" % (raw_rows, served_rows))
    if served_rows == 1:
        return "ok", "%d raw rows served as exactly 1 birthday" % raw_rows
    if served_rows == 0:
        return "FAIL", "the fixture person is served 0 times: %d raw rows, none listed" % raw_rows
    return "FAIL", "the fixture person is served %d times from %d raw rows (must be exactly 1)" % (served_rows, raw_rows)


def count_name(text, token=SURNAME):
    """How many times the person is named in a block of brief text."""
    return len(re.findall(r"(?<!\w)" + re.escape(token) + r"(?!\w)", text or ""))


def birthday_section(text):
    """The lines of a brief that talk about birthdays (the headline renders them as ONE
    line, 'Birthdays: A, B and C today'; a longer brief may use a bullet list)."""
    return "\n".join(l for l in (text or "").splitlines() if re.search(r"birthday", l, re.I))


def judge_brief_birthday(text):
    """-> (state, detail). The person must be named exactly once in the birthday section.
    Not named at all is CANNOT: a model that left the birthday out has not listed it twice,
    and has not listed it once either."""
    if not (text or "").strip():
        return "CANNOT", "the brief came back empty"
    n = count_name(birthday_section(text))
    if n == 1:
        return "ok", "named exactly once in the birthday section"
    if n == 0:
        return "CANNOT", "the fixture person is not named in the brief's birthday section (%d chars of brief read); nothing to count" % len(text)
    return "FAIL", "named %d times in the birthday section (must be exactly 1)" % n


# ---------------------------------------------------------------------------
# box side
# ---------------------------------------------------------------------------

def _syncer():
    sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".ostler", "import-pipeline"))
    from contact_syncer.syncer import ContactSyncer
    return ContactSyncer()


def _prefix():
    return "PREFIX pwg: <%s>\n" % PWG


def _scalar(s, q):
    b = s._sparql_query(q)["results"]["bindings"]
    return int(b[0]["n"]["value"]) if b else 0


def count_q():
    return (_prefix() + "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o\n"
            "  FILTER(STRSTARTS(STR(?s), %s) || (isIRI(?o) && STRSTARTS(STR(?o), %s))) }" % (_lit(NS), _lit(NS)))


def count_named_q():
    """Same count, but inside NAMED graphs (a bare triple pattern does not reach them on every store setup)."""
    return (_prefix() + "SELECT (COUNT(*) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o\n"
            "  FILTER(STRSTARTS(STR(?s), %s) || (isIRI(?o) && STRSTARTS(STR(?o), %s))) } }" % (_lit(NS), _lit(NS)))


def total_q():
    return "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }"


def meetings_seed_update():
    h, m, a = NS + "holiday", NS + "meeting", NS + "attendee"
    t = lambda x: "<%s>" % x
    return (_prefix() + "INSERT DATA {\n"
            "  %s a pwg:Meeting ; pwg:meetingSummary %s ; pwg:meetingDate %s ; pwg:meetingAllDay true ; pwg:source %s ; pwg:privacyLevel \"L2\" .\n"
            "  %s a pwg:Meeting ; pwg:meetingSummary %s ; pwg:meetingDate %s ; pwg:meetingStart %s ; pwg:meetingEnd %s ;\n"
            "      pwg:meetingAttendee %s ; pwg:source %s ; pwg:privacyLevel \"L2\" .\n}"
            % (t(h), _lit(HOLIDAY_TITLE), _lit(DAY + " 00:00:00+00:00"), _lit(SOURCE),
               t(m), _lit(MEETING_TITLE), _lit(DAY + " 09:00:00+00:00"),
               _lit(DAY + "T09:00:00+00:00"), _lit(DAY + "T10:00:00+00:00"), t(a), _lit(SOURCE)))


def delete_update():
    """Every triple whose subject is in the fixture namespace, and every triple pointing at it."""
    return ("DELETE { ?s ?p ?o } WHERE { ?s ?p ?o\n"
            "  FILTER(STRSTARTS(STR(?s), %s) || (isIRI(?o) && STRSTARTS(STR(?o), %s))) }" % (_lit(NS), _lit(NS)))


def bday_seed_update(today=None):
    # TOMORROW, not today: the brief lists the coming birthdays, and a birthday dated today was not named (b3: named 0).
    today = today or (datetime.date.today() + datetime.timedelta(days=1))
    mmdd = "%02d-%02d" % (today.month, today.day)
    a, b = NS + "person-survivor", NS + "person-card2"
    t = lambda x: "<%s>" % x
    return (_prefix() + "INSERT DATA {\n"
            "  %s a pwg:Person ; pwg:displayName %s , %s ; pwg:birthday %s .\n"
            "  %s a pwg:Person ; pwg:displayName %s ; pwg:birthday %s ; pwg:mergedInto %s .\n}"
            % (t(a), _lit(NAMES[0]), _lit(NAMES[1]), _lit(mmdd),
               t(b), _lit(NAMES[0]), _lit(mmdd), t(a)))


def raw_rows_q():
    """The rows people_birthdays' own SPARQL gives for the fixture, before its per-URI dedupe."""
    return (_prefix() + "SELECT DISTINCT ?p ?name ?bday ?bnode WHERE {\n"
            "  ?bnode pwg:birthday ?bday .\n  ?bnode pwg:mergedInto* ?p .\n"
            "  ?p a pwg:Person ; pwg:displayName ?name .\n"
            "  FILTER NOT EXISTS { ?p a pwg:RetiredPerson }\n"
            "  FILTER NOT EXISTS { ?p pwg:mergedInto ?further }\n"
            "  FILTER(STRSTARTS(STR(?p), %s)) }" % _lit(NS))


def _secret(name):
    try:
        with open(os.path.join(os.path.expanduser("~"), ".ostler", "secrets", name)) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def served_birthdays(days=14):
    """-> (http status, list of fixture-person entries or None). The full list, not
    /api/v1/suggestions' top five, so the fixture cannot be cropped away."""
    hub = os.environ.get("OSTLER_HUB_URL", "http://127.0.0.1:8090").rstrip("/")
    tok = _secret("service_token")
    req = urllib.request.Request("%s/api/v1/people/birthdays?days=%d" % (hub, days),
                                 headers={"Authorization": "Bearer " + tok} if tok else {})
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=30) as r:
            code, body = r.status, json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:  # noqa: BLE001 -- the caller says CANNOT
        return 0, None
    rows = body.get("people") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        return code, None
    return code, [r for r in rows if isinstance(r, dict) and SURNAME in str(r.get("name", ""))]


def delivery_is_silent(stored):
    """True only when the stored cron job can never send. Null or absent delivery is treated
    EXACTLY like mode 'none': ostler-assistant PR #659 (test null_or_none_delivery_never_announces;
    scheduler.rs:1181 only 'announce' sends). 'announce', '' and ANY unknown string stay refused,
    as does a job that could not be read back at all."""
    if not isinstance(stored, dict):
        return False
    d = stored.get("delivery")
    mode = d.get("mode") if isinstance(d, dict) else d
    return mode is None or mode == "none"


def brief_text():
    """Run an UNDELIVERED copy of the morning-brief job and return (status, text-or-None).
    Same safeguards as smart_prefs.box_brief_main: the stored job is read back and the run
    is refused unless delivery mode is 'none'; the job is deleted in every exit. Needs
    wow_moments.py beside this file (the probe stages it)."""
    import time
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import wow_moments as wm
    prompt = wm._morning_prompt()
    if not prompt:
        return "no morning-brief job in config.toml", None
    admin = wm._secret("zeroclaw_admin_token")
    auth = {"Authorization": "Bearer " + admin} if admin else {}
    t = time.localtime(time.time() + 150)
    code, body = wm._http("POST", wm.GATEWAY + "/api/cron", body={
        "name": "walkfixture122b2-brief", "schedule": "%d %d %d %d *" % (t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon),
        "job_type": "agent", "prompt": prompt, "session_target": "isolated", "delete_after_run": False,
        "delivery": {"mode": "none"}}, headers=auth)
    job = ((body or {}).get("job") or {}).get("id")
    if code != 200 or not job:
        return "could not add the undelivered brief job (HTTP %s)" % code, None
    def delete():
        return wm._http("DELETE", wm.GATEWAY + "/api/cron/%s" % job, headers=auth)[0]
    try:
        c, b = wm._http("GET", wm.GATEWAY + "/api/cron/%s" % job, headers=auth)
        stored = (b.get("job") if isinstance(b, dict) and isinstance(b.get("job"), dict) else b) if c == 200 and isinstance(b, dict) else None
        if stored is None:  # same fallback as smart_prefs._read_job: the list route
            c, b = wm._http("GET", wm.GATEWAY + "/api/cron", headers=auth)
            rows = b if isinstance(b, list) else (b or {}).get("jobs") or []
            stored = next((r for r in rows if isinstance(r, dict) and r.get("id") == job), None)
        if not delivery_is_silent(stored):
            d = stored.get("delivery") if isinstance(stored, dict) else None
            mode = d.get("mode") if isinstance(d, dict) else d
            return "REFUSED: gateway stored delivery mode %r, not null/'none'; job deleted before it could fire" % (mode,), None
        deadline = time.time() + float(os.environ.get("OSTLER_WF122B2_BRIEF_WAIT_S", "600"))
        while time.time() < deadline:
            time.sleep(10)
            c, runs = wm._http("GET", wm.GATEWAY + "/api/cron/%s/runs" % job, headers=auth)
            rows = runs if isinstance(runs, list) else (runs or {}).get("runs") or []
            if rows:
                return "ran", rows[0].get("output") or ""
        return "the brief did not run in time", None
    finally:
        delete()


def main(argv):
    if len(argv) < 2:
        print("usage: walk_fixture_122b2.py meetings|bday seed|forget|count|raw|served", file=sys.stderr)
        return 2
    kind, cmd = argv[0], argv[1]
    if cmd == "served":
        code, rows = served_birthdays()
        print(json.dumps({"http": code, "served": None if rows is None else len(rows)}))
        return 0
    if cmd == "brief":
        st, text = brief_text()
        v = judge_brief_birthday(text) if text is not None else ("CANNOT", st)
        print(json.dumps({"run": st, "state": v[0], "detail": v[1],
                          "named": count_name(birthday_section(text)) if text else None,
                          "brief_chars": len(text or "")}))
        return 0
    s = _syncer()
    if cmd == "count":
        print(json.dumps({"fixture": _scalar(s, count_q()) + _scalar(s, count_named_q()), "total": _scalar(s, total_q())}))
    elif cmd == "raw":
        print(len(s._sparql_query(raw_rows_q())["results"]["bindings"]))
    elif cmd == "seed":
        s._sparql_update(meetings_seed_update() if kind == "meetings" else bday_seed_update())
        print("seeded")
    elif cmd == "forget":
        s._sparql_update(delete_update())
        print("removed")
    else:
        print("unknown command %r" % cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
