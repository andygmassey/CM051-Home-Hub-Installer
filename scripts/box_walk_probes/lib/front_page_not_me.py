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
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

APP_ORIGIN = "tauri://localhost"
FOREIGN_ORIGIN = "https://evil.example"


def _post(url, origin, body):
    req = urllib.request.Request(
        url.rstrip("/") + "/api/v1/editor/feedback",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Origin": origin},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # connection refused, DNS, timeout: nothing was measured
        return 0, "{}: {}".format(type(e).__name__, e)


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
    st, data = _read(path)
    if st != "ok" or not isinstance(data, dict):
        return
    if isinstance(data.get("drop"), list):
        data["drop"] = [k for k in data["drop"] if k not in drop_ids]
    for k in card_ids:
        data.pop(k, None)
    tmp = path + ".walkprobe.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def drive(url, editor_dir):
    stamp = str(int(time.time()))
    ok_card, ok_int = "walkprobe-notme-" + stamp, "walkprobe-interest-" + stamp
    bad_card, bad_int = "walkprobe-foreign-" + stamp, "walkprobe-foreign-interest-" + stamp
    editor_dir = os.path.expanduser(editor_dir)
    corr = os.path.join(editor_dir, "interest_corrections.json")
    states = os.path.join(editor_dir, "card_states.json")

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
    cleaned = True
    try:
        for p in (corr, states):
            _scrub(p, {ok_int, bad_int}, {ok_card, bad_card})
    except Exception:
        cleaned = False
    out["cleaned"] = cleaned
    return out


def judge(r):
    if not isinstance(r, dict) or r.get("post_status") is None:
        return "CANNOT_RUN the driver produced no result"
    code = r["post_status"]
    if code == 0:
        return "CANNOT_RUN the Doctor did not answer ({}); nothing was measured".format(
            r.get("post_body", "")[:120])
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
