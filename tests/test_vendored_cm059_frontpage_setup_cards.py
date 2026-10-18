"""The shipped Front Page offers the Safari extension and Remote Capture.

Proven on the vendored copy that ships (vendor/cm059_editor), through its real
emitter and its real feedback route, not upstream CM059. For each card:
shown when its app is installed and not yet working; hidden once the real
signal says it works; held back when its app is absent (the #2878 rule: no
card without a working action); hidden for good after a dismiss.

Signals, as the shipped writers produce them:
  browser extension  ~/.ostler/state/browsing_capture.json last_write_ts
                     (vendor/cm041/assistant_api/ical-server.py _safari_write_state)
  remote capture     ~/.ostler/processing/<id>/00_metadata.json
                     capture_source "cm042_mac" (vendor/cm048_pipeline processor
                     _write_raw; vendor/spoken_source renderer CAPTURE_SOURCE)

Synthetic data only. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import tempfile
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm059_editor"
if not (VENDOR / "compiler").is_dir():
    print(f"CANNOT-RUN: {VENDOR}/compiler missing")
    sys.exit(2)
sys.path.insert(0, str(VENDOR))

try:
    from compiler import emit_artefact as ea
    from compiler import emit_frontpage as ef
    from compiler import feedback as fb
    from compiler import interest_profile as ip
    from compiler import setup_cards as su
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: import failed: {exc!r}")
    sys.exit(2)

# The signal shapes must be the ones the shipped writers emit, or this test
# proves a contract nobody honours.
ical = (ROOT / "vendor/cm041/assistant_api/ical-server.py").read_text(encoding="utf-8")
renderer = (ROOT / "vendor/spoken_source/renderer.py").read_text(encoding="utf-8")
if '"last_write_ts"' not in ical or "browsing_capture.json" not in ical:
    print("CANNOT-RUN: ical-server no longer writes browsing_capture.json last_write_ts")
    sys.exit(2)
if not re.search(r'CAPTURE_SOURCE\s*=\s*"cm042_mac"', renderer):
    print("CANNOT-RUN: spoken_source no longer stamps capture_source cm042_mac")
    sys.exit(2)
if su.REMOTE_CAPTURE_SOURCE != "cm042_mac":
    print("FAIL: setup_cards reads a capture_source the writers do not emit")
    sys.exit(1)

NOW = datetime(2026, 10, 19, 9, 0, tzinfo=timezone.utc)
EXT, RC = "ostler:setup_browser_extension", "ostler:setup_remote_capture"
fails: list[str] = []


def row(subject):
    return {"subject": subject, "category": "music", "strength": "0.7",
            "source": "linkedin", "observed_at": "2026-05-01T00:00:00",
            "created_at": None, "polarity": "like"}


def box(*, ext_app=False, rc_app=False, ext_sent=False, rc_used=False):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="setupcards-"))
    apps = tmp / "Applications" / "Ostler"
    apps.mkdir(parents=True)
    if ext_app:
        (apps / su.SAFARI_EXTENSION_APP).mkdir()
    if rc_app:
        (apps / su.REMOTE_CAPTURE_APP).mkdir()
    state = tmp / "state" / "browsing_capture.json"
    if ext_sent:
        state.parent.mkdir(parents=True)
        state.write_text(json.dumps({"last_write_ts": 1760864400}))
    proc = tmp / "processing"
    proc.mkdir()
    # Negative control on every box: a conversation from another source.
    (proc / "conv-email").mkdir()
    (proc / "conv-email" / "00_metadata.json").write_text(
        json.dumps({"capture_source": "hr015_email_source"}))
    if rc_used:
        (proc / "conv-call").mkdir()
        (proc / "conv-call" / "00_metadata.json").write_text(
            json.dumps({"capture_source": "cm042_mac"}))
    art = tmp / "interest_profile.json"
    art.write_text(json.dumps(ea.build_artefact(
        ip.compile_profile([row("Radiohead")], now=NOW), now=NOW)))
    os.environ.update({
        "OSTLER_APPS_DIR": str(apps), "OSTLER_BROWSING_STATE_PATH": str(state),
        "OSTLER_PROCESSING_DIR": str(proc), "OSTLER_EDITOR_DIR": str(tmp / "editor"),
        "OSTLER_INTEREST_PROFILE": str(art), "OSTLER_STATE_DIR": str(tmp / "nostate"),
        "OSTLER_EDITOR_DISABLE_SIGNALS": "1", "OSTLER_EDITOR_DISABLE_SCOUTS": "1",
    })
    for k in ("OSTLER_DEMO_MODE", "OSTLER_EDITOR_ENTITLEMENT_GATE",
              "OSTLER_EDITOR_CARD_STATES", "OSTLER_EDITOR_CARD_LEDGER",
              "OSTLER_EDITOR_CORRECTIONS", "OSTLER_HYDRATION_PROGRESS_FILE"):
        os.environ.pop(k, None)


def feed():
    res = ef.emit("http://127.0.0.1:1", from_artefact=True, now=NOW)
    return json.loads(open(res["feed"], encoding="utf-8").read())


def shown(f, source):
    return [c for c in f["cards"] if c.get("source") == source]


def expect(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


box(ext_app=True, rc_app=True)
f = feed()
e, r = shown(f, EXT), shown(f, RC)
expect("extension card shows when installed and silent", len(e) == 1)
expect("remote capture card shows before the first capture", len(r) == 1)
expect("extension button is open_safari_extension",
       bool(e) and e[0]["action"]["kind"] == "open_safari_extension")
expect("remote capture button is open_remote_capture",
       bool(r) and r[0]["action"]["kind"] == "open_remote_capture")

box(ext_app=True, rc_app=True, ext_sent=True, rc_used=True)
f = feed()
expect("extension card hides once the Hub has a page", shown(f, EXT) == [])
expect("remote capture card hides after the first capture", shown(f, RC) == [])

box()
f = feed()
expect("both held back when neither app is installed",
       shown(f, EXT) == [] and shown(f, RC) == [])

box(ext_app=True, rc_app=True)
f = feed()
for source in (EXT, RC):
    cards = shown(f, source)
    if not cards:
        expect(f"{source} present to dismiss", False)
        continue
    out = fb.record_feedback(cards[0]["id"], None, "drop", now=NOW)
    expect(f"{source} drop recorded", out.get("ok") is True and out.get("dismissed") is True)
f = feed()
expect("both hidden for good after dismiss",
       shown(f, EXT) == [] and shown(f, RC) == [])

print("FAIL" if fails else "PASS", fails)
sys.exit(1 if fails else 0)
