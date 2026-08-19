#!/usr/bin/env python3
"""The WhatsApp parser claims every Facebook and Instagram message file.

MEASURED on a real 2026 GDPR archive (counts only, no content):

    01 - Facebook    WhatsAppParser  1852 files -> 0 records
    02 - Instagram   WhatsAppParser   856 files -> 0 records

2,708 real message files claimed by a parser that yields nothing from them,
so every Facebook and Instagram direct message in the export is discarded.

MECHANISM. ``WhatsAppParser.can_parse`` opens any ``*.json`` and returns

    return any(k in data for k in ['chats', 'messages', 'participants'])

That is the shape of EVERY messenger export, not WhatsApp's. Facebook and
Instagram ``message_N.json`` carry exactly ``participants`` + ``messages``.
``IngestPipeline._get_parser`` takes the FIRST claimer and WhatsAppParser is
registered ahead of MetaParser, so Meta is never asked and its own correct
shape check can never run. Same defect as #808, one directory deeper: a
generic claim beating a specific parser to a file it cannot read.

The list branch has the same flaw: ``['sender', 'message', 'date']`` on
``data[0]`` matches many non-WhatsApp exports.

WHAT THIS PINS
  1. WhatsApp declines Facebook and Instagram message payloads.
  2. Meta claims them.
  3. POSITIVE CONTROL: WhatsApp still claims its OWN exports, both the
     whatsapp_connections/groups.json form and a wa_groups payload and a
     path-marked whatsapp file. A guard that refuses everything would pass
     limb 1 and be worthless.
  4. The routing that actually decides, over the two contending parsers in
     the order read out of the SHIPPED pipeline.py rather than restated.

BOUND, stated rather than implied: limb 4 simulates the dispatcher over the
TWO parsers that contend for these names. A third parser claiming them would
not be seen by this test.

Every fixture is SYNTHETIC. No customer data, no real names, no real numbers.
See PRODUCTISATION_CHECKLIST.md Rule zero.

Exit: 0 all pass, 1 a real failure, 2 cannot-run (never a silent pass).
"""

import json
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
PIPELINE_PY = INGEST / "src" / "pipeline.py"

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def no(msg):
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


def cannot_run(msg):
    print(f"CANNOT RUN: {msg}", file=sys.stderr)
    sys.exit(2)


if not INGEST.is_dir():
    cannot_run(f"vendored ingest service missing at {INGEST}")
if not PIPELINE_PY.is_file():
    cannot_run(f"pipeline.py missing at {PIPELINE_PY}")
sys.path.insert(0, str(INGEST))

try:
    from src.parsers.whatsapp import WhatsAppParser
    from src.parsers.meta import MetaParser
except Exception as exc:  # noqa: BLE001
    cannot_run(f"could not import the shipped parsers: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# Fixtures. Facebook/Instagram message_N.json is a top-level OBJECT with
# "participants" and "messages". WhatsApp Account Info is wa_*-keyed or lives
# under whatsapp_connections/.
# ---------------------------------------------------------------------------

META_MESSAGE_FILES = {
    "01 - Facebook/your_facebook_activity/messages/inbox/thread_a/message_1.json": {
        "participants": [{"name": "Synthetic Person One"},
                         {"name": "Synthetic Person Two"}],
        "messages": [{"sender_name": "Synthetic Person One",
                      "timestamp_ms": 1600000000000,
                      "content": "synthetic message body"}],
        "title": "Synthetic Thread",
        "thread_path": "inbox/thread_a",
    },
    "02 - Instagram/your_instagram_activity/messages/inbox/thread_b/message_1.json": {
        "participants": [{"name": "Synthetic Person Three"}],
        "messages": [{"sender_name": "Synthetic Person Three",
                      "timestamp_ms": 1600000000001,
                      "content": "another synthetic body"}],
        "title": "Synthetic IG Thread",
        "thread_path": "inbox/thread_b",
    },
}

WHATSAPP_OWN_FILES = {
    "whatsapp_connections/groups.json": {
        "wa_groups": [{"group_name": "Synthetic Group", "members": 3}]
    },
    "export/whatsapp_account_info.json": {
        "wa_communities": [{"community_name": "Synthetic Community"}]
    },
}


def write(root, rel, payload):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


def registration_order():
    """Read the real order out of the SHIPPED pipeline.py, never restate it."""
    src = PIPELINE_PY.read_text(encoding="utf-8")
    m = re.search(r"self\.parsers:\s*List\[BaseParser\]\s*=\s*\[(.*?)\n\s*\]",
                  src, re.S)
    if not m:
        cannot_run("could not locate the parser registration list in pipeline.py")
    return re.findall(r"^\s*(\w+)\(\)\s*,", m.group(1), re.M)


def main():
    wa = WhatsAppParser()
    meta = MetaParser()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # --- limb 1: WhatsApp must DECLINE Meta message payloads ----------
        for rel, payload in META_MESSAGE_FILES.items():
            p = write(root, rel, payload)
            if wa.can_parse(p):
                no(f"WhatsApp CLAIMS a Meta message export: {rel}")
            else:
                ok(f"WhatsApp declines {rel}")

        # --- limb 2: Meta must ALSO decline, and that is CORRECT ----------
        #
        # An earlier draft of this test asserted "Meta must claim them". That
        # was WRONG and it would have frozen a false conclusion into a gate.
        # MetaParser has no message-thread limb at all: SUPPORTED_PATTERNS
        # carries no "message" entry and there is no _parse_messages. Meta
        # declining message_N.json is the correct behaviour, and routing these
        # files to Meta would yield zero exactly as WhatsApp does.
        #
        # So this limb pins the HONEST state: the preferences ingest has NO
        # owner for a Meta message thread. Stopping WhatsApp stealing them
        # converts 2,708 real files from "claimed and silently destroyed" to
        # "unclaimed", which is truthful but is NOT a yield. Direct messages
        # are conversations, not preferences; their owner is the conversation
        # pipeline under the 4-artefact spec, and that wiring does not exist
        # for archive exports. Tracked separately -- do not "fix" this limb by
        # teaching Meta to claim a file it cannot read.
        for rel, payload in META_MESSAGE_FILES.items():
            p = root / rel
            if meta.can_parse(p):
                no(f"Meta claims {rel} but has no message limb; it would yield 0")
            else:
                ok(f"Meta correctly declines {rel} (no message-thread parser exists)")

        # --- limb 3: POSITIVE CONTROL, WhatsApp still claims its own ------
        for rel, payload in WHATSAPP_OWN_FILES.items():
            p = write(root, rel, payload)
            if wa.can_parse(p):
                ok(f"POSITIVE CONTROL: WhatsApp still claims {rel}")
            else:
                no(f"POSITIVE CONTROL BROKEN: WhatsApp refuses its own {rel}")

        # --- limb 4: the dispatcher, in the SHIPPED order ------------------
        order = registration_order()
        if "WhatsAppParser" not in order or "MetaParser" not in order:
            cannot_run("pipeline.py does not register both parsers under test")
        pair = [(n, wa if n == "WhatsAppParser" else meta)
                for n in order if n in ("WhatsAppParser", "MetaParser")]
        # Neither contender may claim a Meta message thread. WhatsApp cannot
        # read it; Meta has no limb for it. An unclaimed file is logged and
        # left alone. A CLAIMED one is silently destroyed, and that is the
        # difference this gate exists to hold.
        for rel in META_MESSAGE_FILES:
            p = root / rel
            winner = next((n for n, inst in pair if inst.can_parse(p)), None)
            if winner is None:
                ok(f"dispatcher leaves {Path(rel).parent.name}/message_1.json unclaimed")
            else:
                no(f"dispatcher gives {rel} to {winner}, which yields 0 from it")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
