#!/usr/bin/env python3
"""Front Page "Not me": POST it the way the Hub app does, reload, read it back.

CM051 #2470. v1.0.105 walk: a card marked Not me came back on the next visit,
and interest_corrections.json / card_states.json never existed. The fix is in
(the Hub posts every tap; the route accepts the app origin) but nothing on the
walk ever exercised it, so a regression would ship silently. This does.

  drive <doctor_url> <editor_dir>   runs ON THE BOX, prints one JSON object
  judge                             reads that JSON on stdin, prints one line:
                                    PASS|FAIL|CANNOT_RUN <detail>

The tap is the one the app sends: POST /api/v1/editor/feedback with
Origin: tauri://localhost, {card_id, action: "drop", interest_id}. The RELOAD is
a fresh read of both stores from disk after the POST has returned, in a new
process, not the response body. A second POST from a foreign web origin is the
control for the route's origin gate: it must be refused and write nothing.

Synthetic ids only; both are removed from the stores before the driver exits.
Whether each store existed is recorded BEFORE the tap: a file the tap created is
deleted again, a pre-existing file is only scrubbed of the synthetic ids (the
owner's own entries are never touched). A cleanup that cannot finish, or that
leaves a synthetic id behind, is a FAIL, not a quiet pass.

Verdicts for the tap itself: only connection-refused is CANNOT-RUN (nothing is
listening, so nothing was measured). A Doctor that is there but hangs up, sends
a malformed reply or times out is FAIL: it is up and it is not saving Not me.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

APP_ORIGIN = "tauri://localhost"
FOREIGN_ORIGIN = "https://evil.example"
# Files the tap's own write path creates (the feedback route re-emits the Front
# Page, which writes the feed, its html and the ledger). Only these are ever removed, and only when they
# did not exist before the probe ran.
STORE_NAMES = ("interest_corrections.json", "card_states.json", "card_ledger.json",
               "front_page.json", "front_page.html")
_SCRUBBED = ("interest_corrections.json", "card_states.json")
TIMEOUT_S = float(os.environ.get("OSTLER_NOT_ME_TIMEOUT") or 15)
# The Doctor is on loopback: never route it through an env proxy (a local
# Privoxy answered every probe with a 503 on the walk box).
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _is_refused(e):
    return isinstance(e, ConnectionRefusedError) or (
        isinstance(e, urllib.error.URLError) and isinstance(e.reason, ConnectionRefusedError))


def _post(url, origin, body):
    req = urllib.request.Request(
        url.rstrip("/") + "/api/v1/editor/feedback",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Origin": origin},
        method="POST",
    )
    try:
        with _OPENER.open(req, timeout=TIMEOUT_S) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        if _is_refused(e):  # nothing is listening: nothing was measured
            return 0, "{}: {}".format(type(e).__name__, e)
        # present but disconnecting, malformed or timing out: it is up and broken
        return -1, "{}: {}".format(type(e).__name__, e)


def _read(path):
    """(state, parsed). state: absent | unreadable | ok. Never collapses the three."""
    if not os.path.exists(path):
        return "absent", None
    try:
        with open(path, encoding="utf-8") as fh:
            return "ok", json.load(fh)
    except Exception as e:
        return "unreadable", "{}: {}".format(type(e).__name__, e)


def _scrub(path, drop_ids, card_ids):
    """Remove the synthetic ids from a store that held owner data before the tap."""
    st, data = _read(path)
    if st == "absent":
        return
    if st != "ok" or not isinstance(data, dict):
        raise RuntimeError("{} is {} and cannot be scrubbed".format(os.path.basename(path), st))
    if isinstance(data.get("drop"), list):
        data["drop"] = [k for k in data["drop"] if k not in drop_ids]
    for k in card_ids:
        data.pop(k, None)
    tmp = path + ".walkprobe.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def _cleanup(editor_dir, pre, dir_pre, drop_ids, card_ids):
    """Undo the tap. Returns a list of problems; empty means the box is as found."""
    problems = []
    for name in STORE_NAMES:
        path = os.path.join(editor_dir, name)
        try:
            if os.path.exists(path + ".walkprobe.tmp"):
                os.remove(path + ".walkprobe.tmp")
            if not pre[name]:
                if os.path.exists(path):
                    os.remove(path)  # the tap created it
            elif name in _SCRUBBED:
                _scrub(path, drop_ids, card_ids)
        except Exception as e:
            problems.append("{}: {}: {}".format(name, type(e).__name__, e))
    if not dir_pre:
        try:
            os.rmdir(editor_dir)
        except FileNotFoundError:
            pass
        except OSError as e:
            problems.append("editor dir: {}: {}".format(type(e).__name__, e))
    # verify by reading back, not by trusting the calls above
    for name in STORE_NAMES:
        path = os.path.join(editor_dir, name)
        if not pre[name] and os.path.exists(path):
            problems.append("{} still exists but did not before the probe".format(name))
    for name in ("interest_corrections.json", "card_states.json"):
        st, val = _read(os.path.join(editor_dir, name))
        if st == "ok" and isinstance(val, dict) and (
                set(val.get("drop") or []) & drop_ids or set(val) & card_ids):
            problems.append("{} still holds a synthetic id".format(name))
    return problems


def drive(url, editor_dir):
    stamp = str(int(time.time()))
    ok_card, ok_int = "walkprobe-notme-" + stamp, "walkprobe-interest-" + stamp
    bad_card, bad_int = "walkprobe-foreign-" + stamp, "walkprobe-foreign-interest-" + stamp
    editor_dir = os.path.expanduser(editor_dir)
    corr = os.path.join(editor_dir, "interest_corrections.json")
    states = os.path.join(editor_dir, "card_states.json")
    dir_pre = os.path.isdir(editor_dir)
    pre = {n: os.path.exists(os.path.join(editor_dir, n)) for n in STORE_NAMES}

    code, body = _post(url, APP_ORIGIN,
                       {"card_id": ok_card, "action": "drop", "interest_id": ok_int})
    f_code, _ = _post(url, FOREIGN_ORIGIN,
                      {"card_id": bad_card, "action": "drop", "interest_id": bad_int})
    # the reload: read the stores fresh, after the POST returned
    c_state, c_val = _read(corr)
    s_state, s_val = _read(states)
    out = {
        "post_status": code, "post_body": body[:300],
        "foreign_status": f_code,
        "corrections_state": c_state, "states_state": s_state,
        "corrections_has_interest": bool(c_state == "ok" and isinstance(c_val, dict)
                                         and ok_int in (c_val.get("drop") or [])),
        "card_state": (s_val.get(ok_card) if s_state == "ok" and isinstance(s_val, dict) else None),
        "foreign_leaked": bool(
            (c_state == "ok" and isinstance(c_val, dict) and bad_int in (c_val.get("drop") or []))
            or (s_state == "ok" and isinstance(s_val, dict) and bad_card in s_val)),
        "editor_dir": editor_dir,
    }
    problems = _cleanup(editor_dir, pre, dir_pre, {ok_int, bad_int}, {ok_card, bad_card})
    out["cleaned"] = not problems
    out["cleanup_problems"] = problems
    return out


def judge(r):
    if not isinstance(r, dict) or r.get("post_status") is None:
        return "CANNOT_RUN the driver produced no result"
    code = r["post_status"]
    if code == 0:
        return "CANNOT_RUN the Doctor did not answer ({}); nothing was measured".format(
            r.get("post_body", "")[:120])
    if code == -1:
        return "FAIL the Doctor answered but not with a usable reply (hung up, malformed or timed out): {}".format(
            r.get("post_body", "")[:160])
    if code != 200:
        return "FAIL the app's own tap (Origin tauri://localhost) got HTTP {}: {}".format(
            code, r.get("post_body", "")[:160])
    try:
        status = json.loads(r.get("post_body") or "{}").get("status")
    except Exception:
        status = None
    if status != "recorded":
        return "FAIL HTTP 200 but the body does not say recorded ({!r})".format(status)
    if r.get("corrections_state") != "ok" or not r.get("corrections_has_interest"):
        return ("FAIL the route answered 'recorded' but interest_corrections.json is {} "
                "and does not hold the dropped interest after a reload: Not me is NOT saved"
                ).format(r.get("corrections_state"))
    cs = r.get("card_state")
    if not (isinstance(cs, dict) and cs.get("state") == "dismissed_forever"):
        return "FAIL card_states.json does not hold the card as dismissed_forever after a reload ({!r})".format(cs)
    if r.get("foreign_status") != 403 or r.get("foreign_leaked"):
        return ("FAIL the route's origin gate is open: a foreign web origin got HTTP {} "
                "(leaked into the store: {})").format(r.get("foreign_status"), r.get("foreign_leaked"))
    if r.get("cleaned") is not True:
        return "FAIL the probe could not scrub its own synthetic ids / files from the owner's editor dir: {}".format(
            "; ".join(r.get("cleanup_problems") or ["cleanup did not report"])[:300])
    return "PASS Not me (drop) from tauri://localhost answered recorded and both stores held it on reload; a foreign origin got 403 and wrote nothing (cleaned={})".format(
        r.get("cleaned"))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "drive":
        print(json.dumps(drive(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) == 2 and sys.argv[1] == "judge":
        try:
            doc = json.loads(sys.stdin.read())
        except Exception:
            print("CANNOT_RUN the driver output was not JSON (box unreachable or python3 missing)")
            sys.exit(0)
        print(judge(doc))
    else:
        sys.exit("usage: front_page_not_me.py drive <url> <editor_dir> | judge")
