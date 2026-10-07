#!/usr/bin/env python3
"""Does the installed database key actually reach every service, and is the
store it unlocks genuinely encrypted? (v1.0.107, FLOW_CENSUS gap #1)

install.sh mints a DEK at Phase 3.6 and writes it to
${OSTLER_DIR}/security/db_key (0600). Two services resolve it independently,
each via its own call to ostler_security.db_key.resolve_db_key(): ical-server
(reader, GET /api/v1/coach/recent) and the CM048 ingest pipeline (writer, the
coach-observations sink). PR #1956 fixed the key never being set at all;
nothing in this suite has measured the fix on a live box since.

"Reaches the service" is graded on four separate things, never assumed from
one another:

  (a) each service's own security-posture self-attestation
      (~/.ostler/security-posture/<service>.json) says encryption=enabled,
      backend=sqlcipher;
  (b) a synthetic row, written with the SAME resolver + SQLCipher helper the
      real writer uses, actually increases the row count in the real
      database file at the real path;
  (c) a DIFFERENT process -- ical-server, over its own authenticated HTTP
      API, with its OWN independently-resolved key -- can read that row
      back. This is the only arm that proves the key the installer wrote is
      the SAME key both services end up using, not two keys that each
      happen to "work" in isolation;
  (d) the database file is NOT openable as plain SQLite without a key. A
      posture marker can say "enabled" after a code path that never
      actually calls SQLCipher; this arm is the one that would catch that.

Two halves, kept apart so the judge can be mutation-tested without a box:
  box  -- runs ON the box. Prints ONE JSON line of counts and booleans.
          Never prints key material, row contents or service output.
  judge(facts) -> rows    pure.
"""
import json
import os
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

SERVICES = ("ical-server", "cm048-ingest")

DECLARED = [
    "posture: ical-server self-attests encryption enabled via sqlcipher",
    "posture: cm048-ingest self-attests encryption enabled via sqlcipher",
    "seed: a synthetic row written with the resolved key increases the real coach-db row count",
    "cross-process read-back: ical-server's own independently-resolved key reads the row back",
    "encryption is real: the coach database cannot be opened as plain SQLite without a key",
]


def _posture_row(name, facts):
    marker = (facts.get("posture") or {}).get(name)
    if marker is None:
        return (None, "no posture marker found for {}; it may not have started since this box was installed".format(name))
    if not isinstance(marker, dict):
        return (None, "posture marker for {} is not readable JSON".format(name))
    enc = marker.get("encryption")
    backend = marker.get("backend")
    if enc == "enabled" and backend == "sqlcipher":
        return (True, "{}: encryption=enabled backend=sqlcipher key_source={}".format(name, marker.get("key_source")))
    return (False, "{}: encryption={} backend={} reason={}".format(name, enc, backend, marker.get("reason")))


def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    ok, detail = _posture_row("ical-server", f)
    add(DECLARED[0], ok, detail)
    ok, detail = _posture_row("cm048-ingest", f)
    add(DECLARED[1], ok, detail)

    seed = f.get("seed") or {}
    if not seed.get("attempted"):
        add(DECLARED[2], None, "NOT MEASURED: could not resolve the key or open the coach database on the box ({})".format(seed.get("error", "no detail")))
    elif seed.get("pre_count") is None or seed.get("post_count") is None:
        add(DECLARED[2], None, "NOT MEASURED: could not count rows before/after seeding")
    elif seed.get("post_count", 0) <= seed.get("pre_count", 0):
        add(DECLARED[2], False, "seeding did not increase the row count (pre={} post={})".format(seed.get("pre_count"), seed.get("post_count")))
    else:
        add(DECLARED[2], True, "pre={} post={}, +{} synthetic row".format(seed.get("pre_count"), seed.get("post_count"), seed.get("post_count") - seed.get("pre_count")))

    rb = f.get("readback") or {}
    if not seed.get("attempted") or seed.get("post_count") is None or seed.get("post_count", 0) <= (seed.get("pre_count") or 0):
        add(DECLARED[3], None, "NOT MEASURED: no synthetic row was confirmed seeded to read back")
    elif not rb.get("attempted"):
        add(DECLARED[3], None, "NOT MEASURED: could not reach ical-server's coach endpoint ({})".format(rb.get("error", "no detail")))
    elif rb.get("found") is None:
        add(DECLARED[3], None, "NOT MEASURED: ical-server responded but gave no parseable observation count")
    elif rb.get("found") is False:
        add(DECLARED[3], False, "ical-server's own key could not read back the row this process wrote with the installed key (http_status={})".format(rb.get("http_status")))
    else:
        add(DECLARED[3], True, "ical-server (a different process, its own resolved key) read the synthetic row back")

    raw = f.get("raw_open") or {}
    if not raw.get("attempted"):
        add(DECLARED[4], None, "NOT MEASURED: could not attempt an unkeyed open of the database file")
    elif raw.get("opened_as_sqlite") is None:
        add(DECLARED[4], None, "NOT MEASURED: the unkeyed open gave no clear answer")
    elif raw.get("opened_as_sqlite") is True:
        add(DECLARED[4], False, "the coach database opened and read as plain SQLite WITHOUT any key -- it is not actually encrypted")
    else:
        add(DECLARED[4], True, "the coach database file is not valid SQLite without the key")

    names = [n for n, _, _ in out]
    missing = [x for x in DECLARED if x not in names]
    add("db-key probe: every declared assertion produced a row", not missing, ", ".join(missing))
    return out


# ---------------------------------------------------------------------------
# box half: runs under the box's own venv (needs sqlcipher3 + ostler_security
# as the real services see them). Prints counts and booleans only.
# ---------------------------------------------------------------------------

def measure_posture():
    out = {}
    base = os.path.join(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")), "security-posture")
    for name in SERVICES:
        try:
            with open(os.path.join(base, name + ".json")) as fh:
                out[name] = json.load(fh)
        except (IOError, ValueError):
            out[name] = None
    return out


def _user_id():
    try:
        for line in open(os.path.expanduser("~/.ostler/config/.env")):
            if line.startswith("USER_ID="):
                return line.split("=", 1)[1].strip().strip('"')
    except IOError:
        pass
    return ""


def seed_and_readback(token, service_token):
    import sqlite3
    import time
    from pathlib import Path

    out_seed = {"attempted": False}
    out_rb = {"attempted": False}
    out_raw = {"attempted": False}
    user_id = _user_id()

    try:
        from ostler_security.db_key import resolve_db_key
        from ostler_security.database import get_db_connection, HAS_SQLCIPHER
    except ImportError as exc:
        out_seed["error"] = "ostler_security not importable under this interpreter ({})".format(exc)
        return out_seed, out_rb, out_raw

    if not HAS_SQLCIPHER:
        out_seed["error"] = "sqlcipher3 not installed under this interpreter"
        return out_seed, out_rb, out_raw

    resolved = resolve_db_key()
    if not resolved.key:
        out_seed["error"] = "resolve_db_key() returned no key (reason={})".format(resolved.reason)
        return out_seed, out_rb, out_raw

    db_path = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg"))) / "coach" / "observations.db"
    db_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        conn = get_db_connection(str(db_path), resolved.key)
        # The probe does not own this schema: it reads the INSTALLED table's
        # columns and fills only what a NOT NULL constraint demands, so the
        # probe never restates (or drifts from) the coach-db DDL. No table is
        # a fact about the box, reported, never papered over by creating one.
        cols = conn.execute("PRAGMA table_info(observations)").fetchall()
        if not cols:
            conn.close()
            out_seed["error"] = "the installed coach db has no observations table"
            return out_seed, out_rb, out_raw
        pre = conn.execute("SELECT COUNT(*) FROM observations WHERE conversation_id = ?", (token,)).fetchone()[0]
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        values = {
            "observation_id": token, "conversation_id": token, "observed_at": now,
            "conversation_type": "walk_probe", "user_id": user_id or "walk-probe",
            "visibility": "private", "created_at": now,
            "tip_json": json.dumps(["SYNTHETIC WALK PROBE -- db_key_reaches_every_service, safe to delete"]),
        }
        for _cid, name, ctype, notnull, dflt, _pk in cols:
            if name in values or not notnull or dflt is not None:
                continue
            t = (ctype or "").upper()
            values[name] = 0 if "INT" in t else (0.0 if ("REAL" in t or "FLOA" in t) else "walk_probe")
        names = [c[1] for c in cols if c[1] in values]
        conn.execute(
            "INSERT OR REPLACE INTO observations ({}) VALUES ({})".format(
                ", ".join(names), ",".join("?" * len(names))),
            tuple(values[n] for n in names),
        )
        conn.commit()
        post = conn.execute("SELECT COUNT(*) FROM observations WHERE conversation_id = ?", (token,)).fetchone()[0]
        conn.close()
        out_seed.update(attempted=True, pre_count=pre, post_count=post)
    except Exception as exc:
        out_seed["error"] = "seed write failed: {}".format(exc)[:200]
        return out_seed, out_rb, out_raw

    # (c) cross-process read-back through ical-server's own HTTP API.
    if user_id and service_token:
        try:
            import urllib.request
            url = "http://127.0.0.1:8089/api/v1/coach/recent?user_id={}&hours=1&limit=50".format(user_id)
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + service_token})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=15) as r:
                status = r.getcode()
                body = json.loads(r.read().decode() or "null")
            found = any((o.get("conversation_id") == token) for o in (body.get("observations") or []))
            out_rb.update(attempted=True, found=found, http_status=status)
        except Exception as exc:
            out_rb["error"] = str(exc)[:160]
    else:
        out_rb["error"] = "no USER_ID or service token available on this box"

    # (d) negative control: the same file, opened with no key at all.
    try:
        raw = sqlite3.connect(str(db_path))
        raw.execute("SELECT count(*) FROM sqlite_master")
        raw.close()
        out_raw.update(attempted=True, opened_as_sqlite=True)
    except Exception:
        out_raw.update(attempted=True, opened_as_sqlite=False)

    return out_seed, out_rb, out_raw


def box_main(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    token = a.get("--token", "ostler-walk-dbkey-{}".format(os.getpid()))
    service_token = a.get("--service-token", "")
    facts = {"posture": measure_posture()}
    seed, rb, raw = seed_and_readback(token, service_token)
    facts["seed"] = seed
    facts["readback"] = rb
    facts["raw_open"] = raw
    print(json.dumps(facts))
    return 0


def box_forget(argv):
    """Delete the synthetic row this probe wrote. Prints count before/after;
    a delete that matched nothing is visible, never silent."""
    a = dict(zip(argv[0::2], argv[1::2]))
    token = a.get("--token", "")
    if not token:
        print(json.dumps({"deleted": False, "error": "no token given"}))
        return 0
    try:
        from ostler_security.db_key import resolve_db_key
        from ostler_security.database import get_db_connection
        from pathlib import Path
        resolved = resolve_db_key()
        if not resolved.key:
            print(json.dumps({"deleted": False, "error": "no key"}))
            return 0
        db_path = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg"))) / "coach" / "observations.db"
        conn = get_db_connection(str(db_path), resolved.key)
        before = conn.execute("SELECT COUNT(*) FROM observations WHERE conversation_id = ?", (token,)).fetchone()[0]
        conn.execute("DELETE FROM observations WHERE conversation_id = ?", (token,))
        conn.commit()
        after = conn.execute("SELECT COUNT(*) FROM observations WHERE conversation_id = ?", (token,)).fetchone()[0]
        conn.close()
        print(json.dumps({"deleted": True, "before": before, "after": after}))
    except Exception as exc:
        print(json.dumps({"deleted": False, "error": str(exc)[:160]}))
    return 0


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

def _good():
    return {
        "posture": {
            "ical-server": {"encryption": "enabled", "backend": "sqlcipher", "key_source": "OSTLER_DB_KEY_FILE"},
            "cm048-ingest": {"encryption": "enabled", "backend": "sqlcipher", "key_source": "OSTLER_DB_KEY_FILE"},
        },
        "seed": {"attempted": True, "pre_count": 0, "post_count": 1},
        "readback": {"attempted": True, "found": True, "http_status": 200},
        "raw_open": {"attempted": True, "opened_as_sqlite": False},
    }


def self_test():
    import copy
    fails = []

    def row(f, i):
        return [ok for n, ok, _ in judge(f) if n == DECLARED[i]]

    g = _good()
    if any(ok is not True for _, ok, _ in judge(g)):
        print("SELF-TEST BROKEN: the good fixture fails: {}".format([(n, d) for n, ok, d in judge(g) if ok is not True]))
        return EX_FAIL
    print("  ok    good fixture: every assertion passes")

    mutants = [
        ("cm048-ingest posture says disabled", 1, False, lambda f: f["posture"]["cm048-ingest"].update(encryption="disabled", backend=None, reason="no_key")),
        ("seed count did not increase", 2, False, lambda f: f["seed"].update(post_count=0)),
        ("cross-process read-back did not find the row", 3, False, lambda f: f["readback"].update(found=False)),
        ("the database opened as plain SQLite with no key", 4, False, lambda f: f["raw_open"].update(opened_as_sqlite=True)),
        ("ical-server posture marker missing", 0, None, lambda f: f["posture"].update(**{"ical-server": None})),
    ]
    for name, i, want, mutate in mutants:
        f = copy.deepcopy(g)
        mutate(f)
        if row(f, i) != [want]:
            fails.append("{} not caught by its own assertion (want {}, got {})".format(name, [want], row(f, i)))
        else:
            print("  ok    mutant caught: {}".format(name))

    # Honest gaps: nothing ever attempted reads CANNOT-RUN, never a pass.
    dry = copy.deepcopy(g); dry["seed"] = {"attempted": False, "error": "no key"}
    if row(dry, 2) != [None] or row(dry, 3) != [None]:
        fails.append("an unattempted seed is not CANNOT-RUN for seed/readback: {} {}".format(row(dry, 2), row(dry, 3)))
    else:
        print("  ok    an unattempted seed is CANNOT-RUN, not a pass, for both seed and read-back")

    if [ok for n, ok, _ in judge({}) if n in DECLARED and ok is True]:
        fails.append("an empty collection reads as a pass")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, {} mutants caught by their own assertion".format(len(mutants)))
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} db-key assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    if argv[:1] == ["forget"]:
        return box_forget(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
