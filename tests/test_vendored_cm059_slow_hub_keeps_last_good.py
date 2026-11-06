"""The SHIPPED vendor/cm059_editor keeps today's last good cards on a slow Hub,
and hands the Hub's owed list to the wiki (CM059 #40 and #39, pin fdb11f2b).

v1.0.125 walk, 2026-11-06: on a freshly installed box the Hub answered
/api/v1/suggestions in 6.3 s and 11.5 s during its first hour. The editor's
fetch timed out at 5 s, the payload was None, and every birthday card left
the Front Page with nothing in the log and nothing on the page. CM059 #40
lengthens the timeout to 20 s and keeps the last good answer from the same
local day (signals_last_good.json, 0600), named on stderr either way.

Ported from CM059-Ostler-Editor tests/test_signals_slow_hub_keeps_last_good.py
and tests/test_reply_debt_handoff.py, run here against the VENDORED copy
(the copy that ships), not upstream source. Standalone (no pytest), so the
workflow can run it with a bare python3.

Synthetic cast only. Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM059_COMPILER = ROOT / "vendor" / "cm059_editor" / "compiler"
if not VENDOR_CM059_COMPILER.is_dir():
    print(f"CANNOT-RUN: vendored cm059_editor/compiler missing: {VENDOR_CM059_COMPILER}")
    sys.exit(2)

sys.path.insert(0, str(VENDOR_CM059_COMPILER.parent))

try:
    from compiler import emit_artefact as ea
    from compiler import emit_frontpage as ef
    from compiler import interest_profile as ip
    from compiler import signals as sig
except Exception as exc:  # noqa: BLE001 - CANNOT-RUN, not a silent pass
    print(f"CANNOT-RUN: could not import the vendored compiler: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 11, 6, 9, 0, tzinfo=timezone.utc)
SUGGESTIONS = {"birthdays": [{"name": "Test Person A", "days_until": 3}], "privacy": "L2"}
REPLY_DEBT = {"count": 1, "names": ["Test Person B"], "privacy": "L2"}
HANDOFF = {"count": 1, "degraded": False, "sources": ["imessage"],
           "debts": [{"person_name": "Test Person C", "channel": "imessage",
                      "privacy_level": "L2", "resolved": True}]}

FAILS: list[str] = []
PASSES = 0


def check(cond, label, detail=""):
    global PASSES
    if cond:
        PASSES += 1
        print(f"  [PASS] {label}")
    else:
        FAILS.append(label)
        print(f"  [FAIL] {label} {detail}")


class Patch:
    """Minimal monkeypatch: setattr and env, undone in reverse order."""

    def __init__(self):
        self._undo = []

    def setattr(self, obj, name, value):
        old = getattr(obj, name)
        self._undo.append(lambda: setattr(obj, name, old))
        setattr(obj, name, value)

    def setenv(self, key, value):
        old = os.environ.get(key)
        self._undo.append(lambda: os.environ.__setitem__(key, old) if old is not None
                          else os.environ.pop(key, None))
        os.environ[key] = value

    def delenv(self, key):
        if key in os.environ:
            old = os.environ[key]
            self._undo.append(lambda: os.environ.__setitem__(key, old))
            del os.environ[key]

    def undo(self):
        while self._undo:
            self._undo.pop()()


class _Slow(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):  # noqa: N802
        if self.path.split("?", 1)[0] != "/api/v1/suggestions":
            self.send_response(404)
            self.end_headers()
            return
        time.sleep(6.0)  # the 125 box measured 6.3 s and 11.5 s
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(SUGGESTIONS).encode("utf-8"))


def _box(tmp: pathlib.Path, mp: Patch):
    raws = [{"subject": s, "category": "music", "strength": "0.8",
             "source": "linkedin", "observed_at": "2026-05-01T00:00:00",
             "created_at": None, "polarity": "like"}
            for s in ("Jazz", "Cycling", "Pottery")]
    art = ea.build_artefact(ip.compile_profile(raws, now=NOW), now=NOW)
    art_path = tmp / "interest_profile.json"
    art_path.write_text(json.dumps(art), encoding="utf-8")
    mp.setenv("OSTLER_EDITOR_DIR", str(tmp / "editor"))
    mp.setenv("OSTLER_INTEREST_PROFILE", str(art_path))
    mp.setenv("OSTLER_STATE_DIR", str(tmp / "nostate"))
    for k in ("OSTLER_HYDRATION_PROGRESS_FILE", "OSTLER_EDITOR_DISABLE_SIGNALS",
              "OSTLER_DEMO_MODE"):
        mp.delenv(k)


def _tick(mp: Patch, now, answered, err: io.StringIO):
    mp.setattr(sig, "fetch_signals", lambda *a, **k: dict(answered))
    with contextlib.redirect_stderr(err):
        res = ef.emit(from_artefact=True, now=now)
    return json.loads(open(res["feed"], encoding="utf-8").read())


def _birthdays(feed):
    return [c for c in feed["cards"]
            if (c.get("signal") or {}).get("type") == "birthday"]


def t_slow_hub_read_with_default_timeout():
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        os.environ.pop(k, None)
    srv = HTTPServer(("127.0.0.1", 0), _Slow)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        raw = sig.fetch_signals(f"http://127.0.0.1:{srv.server_address[1]}")
    finally:
        srv.shutdown()
    check(raw.get("suggestions") == SUGGESTIONS,
          "a Hub answering in 6 s is read with the default timeout", repr(raw)[:200])


def t_timed_out_fetch_keeps_last_good(tmp, mp):
    _box(tmp, mp)
    err = io.StringIO()
    good = _tick(mp, NOW, {"suggestions": SUGGESTIONS, "reply_debt": REPLY_DEBT}, err)
    check(len(_birthdays(good)) == 1, "a good tick shows the birthday card")
    err = io.StringIO()
    later = _tick(mp, NOW + timedelta(hours=1), {}, err)
    kept = _birthdays(later)
    check(len(kept) == 1, "an hour later, both fetches failed: the birthday card is kept",
          repr(later["cards"])[:200])
    if kept:
        check(kept[0].get("as_of") == NOW.isoformat(), "the kept card carries as_of = the good tick")
        check(str(kept[0].get("body") or "").startswith("As of "), "the kept card says 'As of'")
    fresh = _birthdays(good)[0] if _birthdays(good) else {}
    check("as_of" not in fresh and not fresh.get("body"), "the fresh card carries no as_of")
    lg = tmp / "editor" / "signals_last_good.json"
    mode = (os.stat(lg).st_mode & 0o777) if lg.exists() else None
    check(mode == 0o600, "signals_last_good.json is owner-only (0600)", oct(mode or 0))
    e = err.getvalue()
    check("suggestions" in e and "last good" in e, "stderr names the endpoint and 'last good'", e[:200])
    handoff = json.loads((tmp / "editor" / "reply_debt.json").read_text())
    check(handoff.get("status") == "unavailable", "reply_debt.json stays status=unavailable")
    lgd = handoff.get("last_good") or {}
    check(lgd.get("payload") == REPLY_DEBT and lgd.get("fetched_at") == NOW.isoformat(),
          "reply_debt.json carries last_good with its real fetched_at")


def t_earlier_day_not_reused(tmp, mp):
    _box(tmp, mp)
    _tick(mp, NOW - timedelta(days=2), {"suggestions": SUGGESTIONS}, io.StringIO())
    err = io.StringIO()
    feed = _tick(mp, NOW, {}, err)
    check(_birthdays(feed) == [], "a last good from an earlier day is not reused")
    e = err.getvalue()
    check("suggestions" in e and "unavailable" in e, "the loss is named on stderr", e[:200])
    handoff = json.loads((tmp / "editor" / "reply_debt.json").read_text())
    check(handoff.get("status") == "unavailable" and "last_good" not in handoff,
          "reply_debt.json has no last_good from an earlier day")


def t_fresh_answer_replaces_last_good(tmp, mp):
    _box(tmp, mp)
    _tick(mp, NOW, {"suggestions": SUGGESTIONS}, io.StringIO())
    _tick(mp, NOW + timedelta(minutes=30), {"suggestions": {"birthdays": [], "privacy": "L2"}},
          io.StringIO())
    feed = _tick(mp, NOW + timedelta(hours=1), {}, io.StringIO())
    check(_birthdays(feed) == [], "a fresh 'no birthdays' answer replaces the old card")


def t_handoff_verbatim(tmp, mp):
    check(ef.write_reply_debt_list({"reply_debt": HANDOFF}, NOW, str(tmp)) == "ok",
          "handoff: write returns ok")
    doc = json.loads((tmp / "reply_debt.json").read_text())
    check(doc.get("status") == "ok" and doc.get("payload") == HANDOFF
          and doc.get("fetched_at") == NOW.isoformat(), "handoff: payload handed over verbatim")


def t_handoff_failed_fetch_unavailable(tmp, mp):
    r1 = ef.write_reply_debt_list(None, NOW, str(tmp))
    r2 = ef.write_reply_debt_list({"commitments": {}}, NOW, str(tmp))
    doc = json.loads((tmp / "reply_debt.json").read_text())
    check(r1 == r2 == "unavailable" and doc.get("status") == "unavailable" and "payload" not in doc,
          "handoff: a failed fetch is unavailable, never an empty list")


def t_handoff_every_tick_even_degraded(tmp, mp):
    mp.setenv("OSTLER_EDITOR_DIR", str(tmp))
    mp.delenv("OSTLER_DEMO_MODE")
    mp.setattr(ef, "read_signals", lambda: {"reply_debt": HANDOFF})

    def no_profile(*a, **k):
        raise RuntimeError("graph down")

    mp.setattr(ef, "_obtain_profile", no_profile)
    with contextlib.redirect_stderr(io.StringIO()):
        ef.emit(now=NOW)
    doc = json.loads((tmp / "reply_debt.json").read_text())
    check(doc.get("payload") == HANDOFF, "handoff: written on a tick whose feed degrades")


def t_handoff_demo_mode_nothing(tmp, mp):
    mp.setenv("OSTLER_EDITOR_DIR", str(tmp))
    mp.setenv("OSTLER_DEMO_MODE", "1")
    mp.setattr(ef, "read_signals", lambda: {"reply_debt": HANDOFF})

    def no_profile(*a, **k):
        raise RuntimeError("x")

    mp.setattr(ef, "_obtain_profile", no_profile)
    with contextlib.redirect_stderr(io.StringIO()):
        ef.emit(now=NOW)
    check(not (tmp / "reply_debt.json").exists(), "handoff: demo mode hands nothing over")


def main() -> int:
    print("== vendored cm059_editor: slow Hub keeps last good; owed list handoff ==")
    t_slow_hub_read_with_default_timeout()
    for fn in (t_timed_out_fetch_keeps_last_good, t_earlier_day_not_reused,
               t_fresh_answer_replaces_last_good, t_handoff_verbatim,
               t_handoff_failed_fetch_unavailable, t_handoff_every_tick_even_degraded,
               t_handoff_demo_mode_nothing):
        mp = Patch()
        with tempfile.TemporaryDirectory() as d:
            try:
                fn(pathlib.Path(d), mp)
            except Exception as exc:  # noqa: BLE001 - an exception is a FAIL, named
                FAILS.append(fn.__name__)
                print(f"  [FAIL] {fn.__name__} raised {exc!r}")
            finally:
                mp.undo()
    print(f"{PASSES} pass, {len(FAILS)} fail")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
