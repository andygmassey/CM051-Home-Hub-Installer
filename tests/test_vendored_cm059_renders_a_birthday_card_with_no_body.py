"""CM051 v1.0.107 URGENT: the SHIPPED vendor/cm059_editor copy crashed the
editor-frontpage LaunchAgent every hour, on every box, because
render_frontpage._card_html assumed a card's `body` key was always a string.
#2535 (upstream CM059-Ostler-Editor #28, vendored here at pin 554fb888) made
birthday_card() emit body=None, which crashed `html.escape` inside the
renderer with AttributeError: 'NoneType' object has no attribute 'replace'.

Proven in the copy that actually ships (vendor/cm059_editor), not just
upstream CM059 source -- the two can and did disagree (the bug shipped in
the vendored tree the moment it was re-pinned to 554fb888).

Synthetic data only.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import pathlib
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM059_COMPILER = ROOT / "vendor" / "cm059_editor" / "compiler"
if not VENDOR_CM059_COMPILER.is_dir():
    print(f"CANNOT-RUN: vendored cm059_editor/compiler missing: {VENDOR_CM059_COMPILER}")
    sys.exit(2)

sys.path.insert(0, str(VENDOR_CM059_COMPILER.parent))

try:
    from compiler import render_frontpage as rf
    from compiler import signals as sg
    from compiler import frontpage as fp
except Exception as exc:  # noqa: BLE001 - CANNOT-RUN, not a silent pass
    print(f"CANNOT-RUN: could not import the vendored compiler: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 10, 1, 7, 0, tzinfo=timezone.utc)

FAILS = []


def check(label, fn):
    try:
        fn()
    except AssertionError as exc:
        FAILS.append(f"{label}: {exc}")
    except Exception as exc:  # noqa: BLE001
        FAILS.append(f"{label}: unexpected {exc!r}")


def test_birthday_card_has_no_body():
    card = sg.birthday_card("Jane Doe", 5, NOW)
    assert card is not None, "birthday_card returned None for a valid input"
    assert card["body"] is None, f"expected body=None, got {card['body']!r}"


def test_render_does_not_crash_on_a_bodyless_card():
    card = sg.birthday_card("Jane Doe", 5, NOW)
    feed = {
        "schema_version": "0.2", "generated_utc": fp._iso(NOW),
        "phase": "steady", "card_count": 1, "cards": [card],
        "stats": {},
    }
    out = rf.render(feed)  # must not raise AttributeError
    assert "Jane Doe" in out, "the card's title did not reach the rendered page"
    assert '<div class="card-body">' not in out, (
        "an empty card-body div was rendered for a card with no body"
    )


check("birthday_card emits body=None", test_birthday_card_has_no_body)
check("render survives a bodyless card", test_render_does_not_crash_on_a_bodyless_card)

if FAILS:
    print("FAIL: {} of 2 checks failed".format(len(FAILS)))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("PASS: 2 of 2 checks (vendored cm059_editor renders a real bodyless birthday card)")
sys.exit(0)
