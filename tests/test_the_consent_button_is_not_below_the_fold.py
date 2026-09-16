#!/usr/bin/env python3
"""The acknowledge button must never move inside the scroll region.

WHY THIS EXISTS. OnboardingQuestionView's own layout comment records THREE
regressions of one defect, each found by a human on a box walk and none by a
test:

  BW3-9 (2026-07-30)  no ScrollView at all. Dense legal copy overflowed the
                      window and clipped the super-title AND the input control
                      off-screen.
  #503  (2026-08-01)  the fix parked the input ~400px below short copy.
  #632  (2026-08-05)  the second fix top-flowed the buttons under the body, so
                      the click target JUMPED between questions.

The shape that reconciles them is written in that comment: sticky top (header +
title), ONE ScrollView holding body + input, and buttonRow PINNED OUTSIDE it so
Back/Continue sit at a constant viewport-bottom position.

WHAT THIS GUARDS, and why it matters more for consent than for anything else:
the personal-use and spoken-capture acknowledgements are `.acknowledge`, which
renders EmptyView() for the input -- the Continue button IS the consent action.
If that button drifts inside the ScrollView, a customer facing ~33 lines of
legal copy would have to scroll to find the only control that grants consent,
and a consent surface whose action is below the fold is the one place
"they probably scrolled" is not good enough.

This asserts SOURCE STRUCTURE, not pixels. It cannot tell you the window is big
enough; it can tell you the button is not inside the scrolling region, which is
the thing that regressed three times.
"""
import pathlib
import re
import sys

PASS = FAIL = 0


def ok(msg: str) -> None:
    global PASS
    print(f"  [PASS] {msg}")
    PASS += 1


def bad(msg: str, detail: str = "") -> None:
    global FAIL
    print(f"  [FAIL] {msg}")
    if detail:
        print(f"         {detail}")
    FAIL += 1


REPO = pathlib.Path(__file__).resolve().parents[1]
VIEW = REPO / "gui" / "OstlerInstaller" / "Views" / "OnboardingQuestionView.swift"

print("\n=== THE CONSENT BUTTON IS NOT BELOW THE FOLD ===\n")

if not VIEW.is_file():
    print(f"  [CANNOT-RUN] no view at {VIEW}")
    sys.exit(2)

src = VIEW.read_text(encoding="utf-8")


def body_of(func_name: str) -> str:
    """Return the source of one func, brace-balanced. '' when not found."""
    m = re.search(r"func\s+" + re.escape(func_name) + r"\s*\(", src)
    if not m:
        return ""
    i = src.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return ""


body = body_of("standardQuestionBody")
if len(body) > 200:
    ok(f"found standardQuestionBody ({len(body)} chars)")
else:
    bad("could not extract standardQuestionBody; every arm below would be vacuous")
    print(f"\n== {PASS} pass / {FAIL} fail ==")
    sys.exit(1)

# Strip comments: the layout history NAMES ScrollView and buttonRow, and a
# structural claim read off prose is not a structural claim.
code = re.sub(r"//[^\n]*", "", body)

n_scroll = code.count("ScrollView")
n_button = code.count("buttonRow(")
if n_scroll == 1:
    ok("exactly ONE ScrollView in the body, which is the shape the comment settled on")
else:
    bad(f"{n_scroll} ScrollView(s) in standardQuestionBody, expected 1",
        "Two scroll regions reintroduce the BW3-9 ambiguity about which one holds the input.")
if n_button == 1:
    ok("exactly ONE buttonRow call")
else:
    bad(f"{n_button} buttonRow call(s), expected 1")

# THE ASSERTION. Walk the braces from the ScrollView and require buttonRow to
# appear only AFTER it closes.
si = code.find("ScrollView")
oi = code.find("{", si)
depth = 0
close = -1
for j in range(oi, len(code)):
    if code[j] == "{":
        depth += 1
    elif code[j] == "}":
        depth -= 1
        if depth == 0:
            close = j
            break

bi = code.find("buttonRow(")
if close == -1:
    bad("could not find the ScrollView's closing brace; not asserting anything")
elif bi == -1:
    bad("buttonRow is not called in standardQuestionBody at all")
elif bi > close:
    ok("buttonRow is OUTSIDE the ScrollView, so the consent button cannot scroll away (#632)")
else:
    bad("buttonRow sits INSIDE the ScrollView -- the consent action can be scrolled off screen",
        "This is regression #632. Move buttonRow below the ScrollView's closing brace.")

# The input must stay INSIDE, or BW3-9 and #503 come back the other way.
ii = code.find("inputField(")
if ii != -1 and oi < ii < close:
    ok("CONTROL: inputField is INSIDE the ScrollView, so the BW3-9 / #503 fix is intact too")
elif ii == -1:
    bad("inputField is not called in standardQuestionBody")
else:
    bad("inputField moved OUTSIDE the ScrollView -- that is the #503 regression",
        "The input must hug its body copy; only the buttons are pinned.")

# MUST-FAIL: the predicate has to be able to say no. Feed it the broken shape.
broken = "VStack { ScrollView { bodyRegionContent(q); inputField(q); buttonRow(q) } }"
b_si = broken.find("ScrollView")
b_oi = broken.find("{", b_si)
d = 0
b_close = -1
for j in range(b_oi, len(broken)):
    if broken[j] == "{":
        d += 1
    elif broken[j] == "}":
        d -= 1
        if d == 0:
            b_close = j
            break
if broken.find("buttonRow(") < b_close:
    ok("MUST-FAIL: the same predicate REJECTS a buttonRow nested inside the ScrollView")
else:
    bad("the predicate accepts the broken shape, so its verdict above means nothing")

# And acknowledge must stay button-only, or the consent gains a control that
# CAN be below the fold.
ack = re.search(r"case\s+\.acknowledge:(.{0,400}?)case\s+\.", src, re.S)
if ack and "EmptyView()" in ack.group(1):
    ok("CONTROL: .acknowledge still renders EmptyView(), so the button is the whole interaction")
else:
    bad("the .acknowledge case no longer renders EmptyView()",
        "If it gained an input control, that control lives inside the ScrollView and CAN be "
        "below the fold on ~33 lines of consent copy. Re-check this guard's premise.")

print(f"\n== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
