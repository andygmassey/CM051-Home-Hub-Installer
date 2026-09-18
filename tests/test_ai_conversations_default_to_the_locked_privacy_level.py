#!/usr/bin/env python3
"""Regression guard: AI conversations are private by default, in every
place that pins the default.

THE BUG THIS KILLS, measured 2026-09-16 on origin/main.

``CLAUDE.md`` locks AI conversations to ``privacy_level: L3`` -- "private by
default". ``cm052/wire.py`` shipped ``transcript=L2, gist=L2``: both artefacts
at the one level that is PUBLISHABLE (L2 is the sole member of
``privacy_model.PUBLISHABLE_LEVELS``). A third party's words pasted into a
chat with an assistant defaulted to the publishable level.

The function's OWN docstring still said "``privacy_level`` (L3 default)" while
the code two dozen lines above it emitted L2 -- the clearest evidence that L3
was the intent and the value had drifted. NOTHING ASSERTED EITHER VALUE:
measured before this test existed, flipping the default broke zero tests in
either direction, which is exactly why it survived.

TWO PLACES PIN THIS DEFAULT, and a fix to one alone is invisible on a real
install: the builtin in ``wire.py``, and the env/plist that the installer
renders for the LaunchAgent. The agent's plist WINS at runtime, so changing
only the Python would have been a merged-but-not-delivered fix. Both are
asserted here.

WHAT THIS TEST DOES NOT CLAIM. The transcript level is DECLARED and not
ENFORCED anywhere in the cut: no wiki renderer and no MCP server ship in the
DMG, so nothing reads the frontmatter back. That gap is recorded in
PRIVACY_ENFORCEMENT_GAPS.md and this test asserts the record stays there, so
the correct default is never mistaken for a working withhold.

Network-free.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor" / "cm052_ai_conversations" / "src"))

# The resolver reads these at call time; clear them so the BUILTIN default is
# what is measured. An inherited value would make this test pass on a machine
# that had exported the right answer, and fail nowhere useful.
for _v in ("OSTLER_AI_CONV_TRANSCRIPT_PRIVACY", "OSTLER_AI_CONV_GIST_PRIVACY"):
    os.environ.pop(_v, None)

from cm052 import wire  # noqa: E402
from cm052.schemas import Conversation, ConversationProvenance  # noqa: E402

FAILURES: list[str] = []


def synthetic_conversation(conv_id: str, metadata: dict | None = None):
    """A minimal, wholly synthetic Conversation. No real-person data."""
    return Conversation(
        conversation_id=conv_id,
        provenance=ConversationProvenance(
            source_kind="external_llm",
            source_subtype="claude_code",
        ),
        channel="ai_assistant",
        participants=[],
        messages=[],
        last_activity="2026-09-16T00:00:00+00:00",
        metadata=metadata or {},
    )


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        FAILURES.append(msg)


# ── 1. The builtin default, resolved the way the writer resolves it ──
check(wire._default_privacy_level("transcript") == "L3",
      "an AI transcript defaults to L3 (private), not to the publishable L2")
check(wire._default_privacy_level("gist") == "L2",
      "the gist stays L2 so the assistant can still answer from a "
      "conservative extract (the locked Option B, not a blanket L3)")

# ── 2. Through the real resolver, on a conversation with no override ──
#
# Asserting the constant alone would not notice a resolver that ignored it.
conv = synthetic_conversation("synthetic-test-conversation")
check(wire._privacy_level(conv, "transcript") == "L3",
      "a conversation carrying no override resolves its transcript to L3")
check(wire._privacy_level(conv, "gist") == "L2",
      "and its gist to L2")

# ── 2b. The user's escape hatch still works, in both directions ───────
#
# CONTROL. Without these, a resolver hardcoded to return L3 would pass
# every assertion above.
conv_l1 = synthetic_conversation("synthetic-override-down",
                                 {"privacy_level": "L1"})
check(wire._privacy_level(conv_l1, "transcript") == "L1",
      "CONTROL: a per-conversation override still wins over the default")
check(wire._privacy_level(conv_l1, "gist") == "L1",
      "CONTROL: and it applies to both artefacts")

conv_junk = synthetic_conversation("synthetic-override-junk",
                                   {"privacy_level": "not-a-level"})
check(wire._privacy_level(conv_junk, "transcript") == "L3",
      "an unparseable override falls back to the default, not to L0")

# ── 2c. The env override is still the config flip it is documented as ─
os.environ["OSTLER_AI_CONV_TRANSCRIPT_PRIVACY"] = "L2"
try:
    check(wire._default_privacy_level("transcript") == "L2",
          "CONTROL: the env var still overrides the builtin, so this "
          "default is configuration and not a hardcode")
finally:
    os.environ.pop("OSTLER_AI_CONV_TRANSCRIPT_PRIVACY", None)

# ── 3. THE INSTALLER, which is what actually runs on a customer Mac ───
#
# The LaunchAgent plist the installer renders carries its own default, and
# it wins over the Python builtin. A fix that changed only wire.py would
# be MERGED and not DELIVERED.
install_sh = (REPO_ROOT / "install.sh").read_text()

transcript_pins = re.findall(
    r"OSTLER_AI_CONV_TRANSCRIPT_PRIVACY[^\n]*?:-(L[0-3])", install_sh)
gist_pins = re.findall(
    r"OSTLER_AI_CONV_GIST_PRIVACY[^\n]*?:-(L[0-3])", install_sh)

# DENOMINATOR FIRST. A regex that matched nothing would make every
# assertion below pass vacuously, and "the installer sets L3" and "the
# installer was not searched" print identically.
check(len(transcript_pins) >= 2,
      f"denominator: install.sh pins the transcript default in "
      f"{len(transcript_pins)} places (the direct invocation AND the "
      f"LaunchAgent plist); expected at least 2")
check(len(gist_pins) >= 2,
      f"denominator: install.sh pins the gist default in {len(gist_pins)} "
      f"places; expected at least 2")
check(set(transcript_pins) == {"L3"},
      f"EVERY installer pin of the transcript default is L3 (found "
      f"{sorted(set(transcript_pins))})")
check(set(gist_pins) == {"L2"},
      f"every installer pin of the gist default is L2 (found "
      f"{sorted(set(gist_pins))})")

# ── 4. The unenforced limb stays on the record ───────────────────────
#
# The default being right is not the transcript being withheld. Nothing in
# the DMG reads the frontmatter back. If that record is deleted, somebody
# will read the correct default as a working protection.
gaps = REPO_ROOT / "PRIVACY_ENFORCEMENT_GAPS.md"
check(gaps.exists(), "PRIVACY_ENFORCEMENT_GAPS.md exists")
gaps_text = gaps.read_text() if gaps.exists() else ""
check("cm052" in gaps_text and "get_conversation" in gaps_text,
      "and it still records that the transcript level has no reader in "
      "the cut")

# The claim in that record, re-measured rather than trusted. If an MCP
# server is ever vendored in, this arm fails and the register must be
# updated -- the register cannot go quietly stale.
vendor = REPO_ROOT / "vendor"
mcp_servers = [p for p in vendor.rglob("server.py")
               if "mcp" in str(p).lower()]
check(not mcp_servers,
      f"re-measured: no MCP server ships in vendor/ (found "
      f"{len(mcp_servers)}); if this fails, the reader has arrived and "
      f"PRIVACY_ENFORCEMENT_GAPS.md entry 1 can be closed")
# POSITIVE CONTROL for the search above: the same rglob over the same tree
# must find something, or an empty result proves only that it cannot look.
control = list((vendor / "cm019_preferences").rglob("*"))
check(len(control) > 50,
      f"CONTROL: the same search of vendor/cm019_preferences finds "
      f"{len(control)} entries, so an empty result above is a real absence")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} check(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: AI conversations are private by default in both pinning places")
