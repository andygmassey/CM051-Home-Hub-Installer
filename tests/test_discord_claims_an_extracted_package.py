#!/usr/bin/env python3
"""An extracted Discord package becomes invisible to its own parser.

MEASURED on a real 2026 Discord export, counts only, no content:

    11 - Discord   package.zip        can_parse = True   (layout test matches
                                      all four of account/activity/messages/
                                      servers as top-level segments)
                   extracted/*.json   can_parse = False  for ALL 74

`discord.py` claims a `.json` only when the FILENAME contains the literal
string "discord". A real package names its members `messages.json`,
`servers/index.json` and so on, so the moment the customer unzips it -- which
is what a customer does, and what that archive already is -- every file in it
becomes unclaimable, while the same bytes inside the zip are claimed
correctly.

THE FIX reuses the EXISTING two-of-four sibling rule from the zip path rather
than inventing a second predicate, so the Facebook/Instagram exclusion that
rule was hardened for holds identically on disk: their activity trees carry a
`messages` directory and NONE of the other three, so they score 1 and are
declined here exactly as they are in the zip.

VERIFIED against the real archives after the fix:

    11 - Discord     readable=77    Discord claims=75
    01 - Facebook    readable=5388  Discord claims=0
    02 - Instagram   readable=2346  Discord claims=0

WHAT THIS PINS
  1. An extracted Discord package IS claimed.
  2. NEGATIVE CONTROL: an extracted Meta tree is NOT, because one sibling is
     not two. Without this limb the fix could be "make Discord claim more",
     which is how the defects this file's siblings document were created.
  3. POSITIVE CONTROL: a discord-named file is still claimed, so a guard that
     refuses everything cannot pass.
  4. A lone `messages/` directory with no sibling is declined.

Fixtures are SYNTHETIC. Rule zero.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
if not INGEST.is_dir():
    print(f"CANNOT RUN: ingest missing at {INGEST}", file=sys.stderr)
    sys.exit(2)
sys.path.insert(0, str(INGEST))

try:
    from src.parsers.discord import DiscordParser
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)

PASS = FAIL = 0


def ok(m):
    global PASS
    print(f"  PASS  {m}")
    PASS += 1


def no(m):
    global FAIL
    print(f"  FAIL  {m}")
    FAIL += 1


def touch(root, rel, payload):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


d = DiscordParser()
with tempfile.TemporaryDirectory() as td:
    root = Path(td)

    # --- 1. extracted Discord package: all four siblings -------------------
    pkg = root / "11 - Discord" / "extracted"
    f_msg = touch(pkg, "messages/c1234/messages.json",
                  [{"ID": 1, "Timestamp": "2026-01-01", "Contents": "synthetic"}])
    touch(pkg, "servers/index.json", {"1234": "Synthetic Server"})
    touch(pkg, "activity/analytics.json", {"events": []})
    touch(pkg, "account/user.json", {"username": "synthetic_user"})
    if d.can_parse(f_msg):
        ok("an extracted Discord package IS claimed")
    else:
        no("an extracted Discord package is NOT claimed (74 real files lost)")

    # --- 2. NEGATIVE CONTROL: extracted Meta tree, one sibling only --------
    meta = root / "01 - Facebook" / "your_facebook_activity"
    f_meta = touch(meta, "messages/inbox/t1/message_1.json",
                   {"participants": [{"name": "Synthetic One"}],
                    "messages": [{"sender_name": "Synthetic One",
                                  "timestamp_ms": 1600000000000}]})
    touch(meta, "comments_and_reactions/comments.json", {"comments_v2": []})
    touch(meta, "groups/your_comments_in_groups.json", {"group_comments_v2": []})
    if d.can_parse(f_meta):
        no("NEGATIVE CONTROL BROKEN: Discord claims a Meta message export")
    else:
        ok("NEGATIVE CONTROL: Discord declines a Meta tree (one sibling is not two)")

    # --- 3. a lone messages/ directory is not a Discord package ------------
    lone = root / "some-other-export"
    f_lone = touch(lone, "messages/thread.json", {"messages": []})
    if d.can_parse(f_lone):
        no("a lone messages/ directory was treated as a Discord package")
    else:
        ok("a lone messages/ directory is declined")

    # --- 4. POSITIVE CONTROL: a discord-named file still claimed -----------
    f_named = touch(root / "elsewhere", "discord_messages.json", [{"ID": 2}])
    if d.can_parse(f_named):
        ok("POSITIVE CONTROL: a discord-named .json is still claimed")
    else:
        no("POSITIVE CONTROL BROKEN: discord-named .json no longer claimed")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
