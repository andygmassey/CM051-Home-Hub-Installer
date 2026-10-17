"""followup_keys_match_chat_threads: can "mark a reminder done when the owner
follows up" ever fire on this box?

ostler-assistant #509 completes a pushed reminder when the owner messages the
reminder's own thread. It matches CM048's `thread_key` (CM051 #2802,
`reminders_push.thread_key_for`: a hash of the conversation's counterpart
identities) against the same hash of each chat.db chat's handles. If CM048
built its keys from display names instead of handles, nothing ever matches and
the feature is silently dead. This probe measures exactly that.

READ-ONLY, and never seeds. It reads one thing: the daemon's own measurement in
`GET /api/status` -> `followup` (the daemon has Full Disk Access to chat.db;
the ssh user usually does not, so the daemon does the matching and publishes
counts only: never a key, handle or name).

Two halves, as every probe here:
  BOX side (`box`) runs ON the box over loopback and prints ONE JSON line of
  counts and booleans.
  JUDGE side (`judge FILE`) prints ok/FAIL/CANNOT/ADVISORY lines and exits
  0 pass, 1 fail, 78 cannot-run.

Verdicts:
  PASS        at least one keyed map row matches a chat.db chat (denominator
              printed).
  FAIL        3 or more keyed rows and none match (the handle-versus-display-
              name case), or the sweep is not enabled in the running daemon.
  CANNOT-RUN  no keyed rows, fewer than 3 with none matching, the daemon has
              no Full Disk Access to chat.db, the daemon does not publish
              `followup` (build without #509), or the daemon did not answer.
  ADVISORY    rows Ostler completed on a follow-up, from real activity only.

`--self-test` drives the judge over a good capture and one mutant per verdict;
every mutant must land on its own verdict.

Python 3.9 compatible (the box's /usr/bin/python3).
"""
import json
import os
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HOME = os.path.expanduser("~")
SECRETS = os.environ.get("OSTLER_SECRETS_DIR", os.path.join(HOME, ".ostler", "secrets"))
GATEWAY = os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000").rstrip("/")
CHAT_DB = os.path.join(HOME, "Library", "Messages", "chat.db")
FAIL_FLOOR = 3

COUNT_FIELDS = ("keyed_rows", "keys_matching_one_to_one", "keys_matching_group",
                "completed_by_followup", "reopened")
BOOL_FIELDS = ("available", "measured", "enabled", "chat_db_readable")


def _secret(name):
    try:
        with open(os.path.join(SECRETS, name), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _ssh_user_can_read_chat_db():
    """Informational only: can THIS (ssh) user read chat.db? A plain open of
    the header, never sqlite, so nothing (no -shm, no -wal) is ever written."""
    try:
        with open(CHAT_DB, "rb") as fh:
            return "yes" if fh.read(16).startswith(b"SQLite format 3") else "no (not a SQLite file)"
    except OSError as e:
        return "no (%s)" % (e.strerror or e.__class__.__name__)


def box():
    """Read GET /api/status.followup. Counts and booleans only."""
    import urllib.request
    import urllib.error
    out = {"ssh_user_reads_chat_db": _ssh_user_can_read_chat_db()}
    tok = _secret("zeroclaw_admin_token")
    if not tok:
        out["cannot"] = "no admin token at ~/.ostler/secrets/zeroclaw_admin_token; the daemon's status was not read"
        return out
    req = urllib.request.Request(GATEWAY + "/api/status", headers={"Authorization": "Bearer " + tok})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=20) as r:
            body = json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        out["cannot"] = "the daemon refused GET /api/status (HTTP %d)" % e.code
        return out
    except (OSError, ValueError) as e:
        out["cannot"] = "the daemon did not answer GET /api/status (%s)" % e.__class__.__name__
        return out
    fu = (body or {}).get("followup") if isinstance(body, dict) else None
    if not isinstance(fu, dict):
        out["cannot"] = "GET /api/status has no `followup` block: this daemon predates ostler-assistant #509"
        return out
    for k in BOOL_FIELDS:
        if k in fu:
            out[k] = bool(fu[k])
    for k in COUNT_FIELDS:
        if isinstance(fu.get(k), int):
            out[k] = fu[k]
    return out


def judge(c):
    """-> (lines, rc)."""
    lines = []
    if "ssh_user_reads_chat_db" in c:
        lines.append("  note  the ssh user can read chat.db: %s (not needed: the daemon reads it)"
                     % c["ssh_user_reads_chat_db"])
    if c.get("cannot"):
        lines.append("  CANNOT %s" % c["cannot"])
        return lines, EX_CANNOT
    if c.get("available") is False:
        lines.append("  CANNOT this daemon build has no Reminders push (followup.available=false)")
        return lines, EX_CANNOT
    if not c.get("measured"):
        lines.append("  CANNOT the reminders watcher has not measured yet (followup.measured=false): "
                     "not running, or no tick since start")
        return lines, EX_CANNOT
    if not c.get("enabled"):
        lines.append("  FAIL  the running daemon has the follow-up sweep switched off (followup.enabled=false)")
        return lines, EX_FAIL
    if not c.get("chat_db_readable"):
        lines.append("  CANNOT the daemon cannot read chat.db (no Full Disk Access), so no follow-up can be seen; "
                     "grant it at the console")
        return lines, EX_CANNOT
    missing = [k for k in ("keyed_rows", "keys_matching_one_to_one", "keys_matching_group") if k not in c]
    if missing:
        lines.append("  CANNOT followup block is missing %s" % ", ".join(missing))
        return lines, EX_CANNOT
    n = c["keyed_rows"]
    one, grp = c["keys_matching_one_to_one"], c["keys_matching_group"]
    matched = one + grp
    lines.append("  note  denominator: %d pushed map row(s) with a thread_key; %d match a 1:1 chat, %d a group chat"
                 % (n, one, grp))
    if "completed_by_followup" in c:
        lines.append("  ADVISORY %d reminder(s) completed on a follow-up so far, %d reopened by the owner "
                     "(real activity only; never seeded)"
                     % (c["completed_by_followup"], c.get("reopened", 0)))
    if matched > n or n < 0:
        lines.append("  FAIL  impossible census: %d matches out of %d rows" % (matched, n))
        return lines, EX_FAIL
    if n == 0:
        lines.append("  CANNOT no pushed reminder carries a thread_key yet (denominator 0)")
        return lines, EX_CANNOT
    if matched >= 1:
        lines.append("  ok    %d of %d keyed row(s) match a chat.db thread" % (matched, n))
        return lines, EX_PASS
    if n >= FAIL_FLOOR:
        lines.append("  FAIL  0 of %d keyed rows match any chat.db thread: CM048's thread keys are not built "
                     "from the chat handles, so no reminder can ever complete on a follow-up" % n)
        return lines, EX_FAIL
    lines.append("  CANNOT 0 of %d keyed row(s) match, below the %d needed to call it" % (n, FAIL_FLOOR))
    return lines, EX_CANNOT


def self_test():
    good = {"ssh_user_reads_chat_db": "no (Operation not permitted)", "available": True, "measured": True,
            "enabled": True, "chat_db_readable": True, "keyed_rows": 5, "keys_matching_one_to_one": 2,
            "keys_matching_group": 1, "completed_by_followup": 0, "reopened": 0}
    cases = [
        ("a matching row passes", good, EX_PASS),
        ("only a group match still passes", dict(good, keys_matching_one_to_one=0), EX_PASS),
        ("display-name keys: 5 rows, 0 match", dict(good, keys_matching_one_to_one=0, keys_matching_group=0), EX_FAIL),
        ("exactly 3 rows, 0 match", dict(good, keyed_rows=3, keys_matching_one_to_one=0, keys_matching_group=0),
         EX_FAIL),
        ("sweep switched off in the daemon", dict(good, enabled=False), EX_FAIL),
        ("more matches than rows", dict(good, keyed_rows=1), EX_FAIL),
        ("denominator 0", dict(good, keyed_rows=0, keys_matching_one_to_one=0, keys_matching_group=0), EX_CANNOT),
        ("2 rows, 0 match: below the floor", dict(good, keyed_rows=2, keys_matching_one_to_one=0,
                                                  keys_matching_group=0), EX_CANNOT),
        ("daemon has no FDA to chat.db", dict(good, chat_db_readable=False), EX_CANNOT),
        ("watcher never measured", dict(good, measured=False), EX_CANNOT),
        ("build without reminders push", dict(good, available=False), EX_CANNOT),
        ("daemon predates #509", {"cannot": "no followup block"}, EX_CANNOT),
        ("counts missing", {k: v for k, v in good.items() if k != "keyed_rows"}, EX_CANNOT),
    ]
    ok = True
    names = {EX_PASS: "PASS", EX_FAIL: "FAIL", EX_CANNOT: "CANNOT-RUN"}
    for name, cap, want in cases:
        _, rc = judge(cap)
        good_rc = rc == want
        ok &= good_rc
        print("  %s  %s -> %s (want %s)" % ("ok   " if good_rc else "FAIL ", name, names.get(rc, rc), names[want]))
    print("every case landed on its own verdict" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "box":
        print(json.dumps(box()))
        return 0
    if len(argv) >= 3 and argv[1] == "judge":
        with open(argv[2], encoding="utf-8") as fh:
            lines, rc = judge(json.load(fh))
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
