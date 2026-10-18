#!/usr/bin/env python3
"""validate_payload() must accept the literal action strings the real clients
send, not just the strings a human reads on the button (#2467/#2470/#2516).

MEASURED 2026-10-01 (v1.0.106 console walk, then reproduced on a patched
Studio walk-harness install): the Tauri Hub client (ostler-assistant
web/src/lib/frontpage.ts, CardFeedbackAction) posts action: 'spot_on' for
"Spot on" -- with an underscore. The allowlist in editor_feedback.py required
'spot on' (a space) or the canonical 'strengthen', so every real "Spot on" tap
400'd with "unknown action" before it ever reached the interest_id check that
#2467/#2470 are about. This is a SEPARATE defect from the missing interest_id:
fixing interest_id alone does not fix "Spot on" while this allowlist is wrong.

The static render_frontpage.py page (CM059) sends the human-readable labels
("Spot on" / "Not me" / "Don't show") instead, so both shapes have to work.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "doctor", "agent"))
try:
    from editor_feedback import validate_payload
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

FAILS = []


def check(name, cond):
    print(("  ok    " if cond else "  FAIL  ") + name)
    if not cond:
        FAILS.append(name)


def accepts(action):
    """True if validate_payload does not refuse this action string outright
    (a card_id is supplied so only the action-allowlist gate is under test)."""
    try:
        validate_payload({"card_id": "card_test", "action": action})
        return True
    except Exception as exc:  # ValidationError -- re-raised shape not needed
        print("    -> refused {!r}: {}".format(action, exc))
        return False


# The ACTUAL wire values ostler-assistant's Tauri client sends
# (web/src/lib/frontpage.ts: CardFeedbackAction = 'spot_on' | 'drop').
check("the Tauri client's 'spot_on' (underscore) is accepted", accepts("spot_on"))
check("the Tauri client's 'drop' is accepted", accepts("drop"))

# The human-readable labels CM059's static render_frontpage.py page sends.
check("the static page's 'Spot on' is accepted", accepts("Spot on"))
check("the static page's 'Not me' is accepted", accepts("Not me"))
check("the static page's \"Don't show\" is accepted", accepts("Don't show"))

# The canonical verbs themselves must still work.
check("the canonical 'strengthen' is accepted", accepts("strengthen"))
check("the canonical 'weaken' is accepted", accepts("weaken"))

# A genuinely unknown action must still 400, not silently pass.
check("a bogus action is still refused", not accepts("yeet"))

print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
