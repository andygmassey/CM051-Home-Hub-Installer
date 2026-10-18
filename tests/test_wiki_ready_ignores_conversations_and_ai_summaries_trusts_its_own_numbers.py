"""Board #2562-G, two linked fixes to api_hydration_status (CM051, v1.0.107
candidate #5, BLOCKING).

(1) ai_summaries state machine, MEASURED on a walk box: the compiler status
file read stage_done=200, stage_total=200, with `complete` unset. The phase
stayed "running" forever at 200/200 -- the branch trusted the upstream
`complete` flag EXCLUSIVELY and never compared done to total itself. Fixed:
done >= total (with total > 0, already a separate branch) is now trusted the
same way the explicit flag is.

(2) Andy's decision: one failed phase must never hide the whole wiki.
`overall_state` reads "needs_attention" the instant the conversations phase
has any failure -- MEASURED on the same walk box, 10 of 17 dispatched --
while contacts/graph/ai_summaries (the phases that actually BUILD the wiki)
were all "done" underneath. A new `wiki_ready` field answers the narrower,
correct question for gating the wiki frame, independent of conversations.

Extracts ONLY api_hydration_status via AST (the established pattern for this
file, see test_nameless_filter_applies_to_the_hub_people_count.py) and stubs
every helper it calls, so this is network-free and depends on nothing but
the function under test. Synthetic counts only.
"""
import ast
import pathlib
import sys
from datetime import datetime

SRC = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"
WANT = {"api_hydration_status"}

try:
    text = SRC.read_text()
    tree = ast.parse(text)
except (OSError, SyntaxError) as exc:
    print("CANNOT-RUN: could not parse", SRC, exc)
    sys.exit(2)

keep = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in WANT]
if not keep:
    print("CANNOT-RUN: api_hydration_status not found in", SRC)
    sys.exit(2)

# Stubs, installed BEFORE exec so api_hydration_status's own globals dict
# resolves to these rather than the real network-calling helpers.
_STUB = {"people": 0, "triples": 0, "comp": None, "conv": {"dispatched": 0, "completed": 0, "failed": 0, "running": 0}}
ns = {
    "datetime": datetime,
    "_wiki_people_count": lambda: _STUB["people"],
    "_wiki_triples_count": lambda: _STUB["triples"],
    "_wiki_read_compiler_status": lambda: _STUB["comp"],
    "_wiki_conversations_progress": lambda: dict(_STUB["conv"]),
    "_wiki_eta_seconds": lambda eta: None,
    # Module constant read by api_hydration_status since the retry sweeper
    # (CM041 #203); this harness execs single functions, not the module.
    "CONVERSATION_RETRY_GAVE_UP_MESSAGE": "couldn't process, will retry on the next update",
}
exec(compile(ast.Module(body=keep, type_ignores=[]), str(SRC), "exec"), ns)
api_hydration_status = ns["api_hydration_status"]

fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


def phase(result, key):
    for p in result["phases"]:
        if p["key"] == key:
            return p
    return None


# ── (1) ai_summaries: done >= total must mean done, flag or no flag ──────
_STUB["people"], _STUB["triples"] = 10, 10
_STUB["comp"] = {"complete": False, "stage_done": 200, "stage_total": 200}
_STUB["conv"] = {"dispatched": 0, "completed": 0, "failed": 0, "running": 0}
r = api_hydration_status()
ai = phase(r, "ai_summaries")
check("THE REGRESSION: done==total flips ai_summaries to done without the upstream flag",
      ai is not None and ai["state"] == "done" and ai["done"] == 200 and ai["total"] == 200)

# CONTROL: done < total must still read running, not jump to done early.
_STUB["comp"] = {"complete": False, "stage_done": 150, "stage_total": 200}
r = api_hydration_status()
ai = phase(r, "ai_summaries")
check("CONTROL: done < total still reads running, not done",
      ai is not None and ai["state"] == "running" and ai["done"] == 150)

# CONTROL: total == 0 stays pending (no fake spinner), unaffected by the fix.
_STUB["comp"] = {"complete": False, "stage_done": 0, "stage_total": 0}
r = api_hydration_status()
ai = phase(r, "ai_summaries")
check("CONTROL: total==0 still reads pending, never done",
      ai is not None and ai["state"] == "pending")

# ── (2) wiki_ready must ignore conversations entirely ────────────────────
# THE WALK-FOUND SHAPE: wiki built, conversations badly failed.
_STUB["people"], _STUB["triples"] = 2793, 779189
_STUB["comp"] = {"complete": True, "stage_done": 12, "stage_total": 12}
_STUB["conv"] = {"dispatched": 17, "completed": 7, "failed": 10, "running": 0}
r = api_hydration_status()
check("THE DECISION: wiki_ready is true even though conversations failed",
      r.get("wiki_ready") is True)
check("CONTROL: overall_state still reads needs_attention (conversations IS surfaced, just not a gate)",
      r["overall_state"] == "needs_attention")
conv = phase(r, "conversations")
check("conversations carries the real counts a plain-English banner needs (counts only)",
      conv is not None and conv["dispatched"] == 17 and conv["failed"] == 10)

# CONTROL: a wiki that is NOT yet built must still read wiki_ready=False,
# even with conversations perfectly healthy -- proves wiki_ready is not
# vacuously true.
_STUB["people"], _STUB["triples"] = 0, 0
_STUB["comp"] = {"complete": False, "stage_done": 0, "stage_total": 0}
_STUB["conv"] = {"dispatched": 0, "completed": 0, "failed": 0, "running": 0}
r = api_hydration_status()
check("CONTROL: an unbuilt wiki reads wiki_ready=False",
      r.get("wiki_ready") is False)

# CONTROL: wiki built, conversations ALSO healthy -- wiki_ready true and
# overall_state complete, the ordinary happy path, unaffected by the fix.
_STUB["people"], _STUB["triples"] = 2793, 779189
_STUB["comp"] = {"complete": True, "stage_done": 12, "stage_total": 12}
_STUB["conv"] = {"dispatched": 17, "completed": 17, "failed": 0, "running": 0}
r = api_hydration_status()
check("CONTROL: the ordinary happy path still reads wiki_ready=True and overall_state=complete",
      r.get("wiki_ready") is True and r["overall_state"] == "complete")

print()
print(f"== {'PASS' if fails == 0 else 'FAIL'}: {fails} failing check(s) ==")
sys.exit(1 if fails else 0)
