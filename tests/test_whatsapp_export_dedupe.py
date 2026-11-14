#!/usr/bin/env python3
"""A WhatsApp per-chat export is a supplement: each message is kept exactly once.

The live side is the REAL renderer (vendor/whatsapp_source/renderer.py
render_transcript) writing the transcript that record_live_transcript indexes.
The export side is the REAL parser (ostler_fda.whatsapp_export.parse_chat_text).
Synthetic data only: the approved cast (Jane, Sam) and a reserved phone range.

Controls: a mutant normaliser that strips digits must make the digit scenario
fail, and a mutant filter that never consumes a live key must make the
multiset scenario fail. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
Run bare: python3 tests/test_whatsapp_export_dedupe.py
"""

import os
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))

try:
    from ostler_fda import whatsapp_export as wae
    from ostler_fda.whatsapp_history import WhatsAppChat as LiveChat
    from whatsapp_source.reader import WhatsAppConversation, WhatsAppUtterance
    from whatsapp_source.renderer import render_transcript
except ImportError as exc:  # pragma: no cover
    print(f"CANNOT-RUN: import failed: {exc}")
    sys.exit(2)

PARTNER_JID = "447700900001@s.whatsapp.net"
FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def set_zone(name):
    os.environ["TZ"] = name
    time.tzset()


def utc(y, mo, d, h, mi):
    return datetime(y, mo, d, h, mi, 0, tzinfo=timezone.utc)


def live_conv(rows, chat_id="chat-synthetic-1"):
    """rows: (utc datetime, is_from_me, text). Built as the live reader builds it."""
    chat = LiveChat(chat_id=chat_id, tier="T1", is_group=False, contact_jid=PARTNER_JID)
    utts = [
        WhatsAppUtterance(
            author_jid=None if from_me else PARTNER_JID,
            is_from_me=from_me,
            timestamp=ts,
            text=text,
        )
        for ts, from_me, text in rows
    ]
    return WhatsAppConversation(chat=chat, utterances=utts)


def live_transcript(conv):
    return render_transcript(
        conv,
        name_for_jid=lambda jid: "Sam" if jid == PARTNER_JID else None,
        user_display_name="You",
    )


def export_text(lines):
    return "\n".join(lines) + "\n"


# --- the synthetic chat, HK zone (+8, no DST) ---------------------------------
HK_ROWS = [
    (utc(2026, 11, 10, 1, 15), False, "Dinner at 7?"),          # 09:15 HK
    (utc(2026, 11, 10, 1, 16), True, "Make it 19:30"),          # owner
    (utc(2026, 11, 10, 1, 16), False, "Make it 19:30"),         # same text, other sender
    (utc(2026, 11, 10, 2, 0), False, "Call 12"),
    (utc(2026, 11, 10, 2, 0), False, "Call 21"),                # digits differ
    (utc(2026, 11, 10, 2, 5), False, "see‎ you"),          # LRM inside the text
    (utc(2026, 11, 10, 3, 0), False, "ok"),
]
HK_EXPORT = [
    "[10/11/2026, 09:15:00] Sam: Dinner at 7?",
    "[10/11/2026, 09:16:00] Jane: Make it 19:30",
    "[10/11/2026, 09:16:00] Sam: Make it 19:30",
    "[10/11/2026, 10:00:00] Sam: Call 12",
    "[10/11/2026, 10:00:00] Sam: Call 21",
    "[10/11/2026, 10:05:00] Sam: see you",
    "[10/11/2026, 11:00:00] Sam: ok",
]
OWNER = ["Jane"]


def scenario_exactly_once():
    print("1. the same chat via the live path and via an export: each message once")
    set_zone("Asia/Hong_Kong")
    conv = live_conv(HK_ROWS)
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        n = wae.record_live_transcript(conv.chat.chat_id, live_transcript(conv), index, OWNER)
        check(n == len(HK_ROWS), f"live index recorded {len(HK_ROWS)} keys (got {n})")
        counts = wae.live_key_counts(index)
        full = wae.parse_chat_text(export_text(HK_EXPORT), "Sam")
        new, matched = wae.drop_already_live(full, counts, OWNER)
        check(len(new.messages) == 0, f"no export message is new (got {len(new.messages)})")
        check(matched == len(HK_EXPORT), f"all {len(HK_EXPORT)} export messages matched the live store (got {matched})")
        union = len(HK_ROWS) + len(new.messages)
        check(union == len(HK_ROWS), f"the union holds each message once: {union} == {len(HK_ROWS)}")


def scenario_partial_keeps_id_and_only_new():
    print("2. a partial export keeps only the new message, under the full chat's id")
    set_zone("Asia/Hong_Kong")
    conv = live_conv(HK_ROWS)
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript(conv.chat.chat_id, live_transcript(conv), index, OWNER)
        extra = HK_EXPORT + ["[10/11/2026, 12:00:00] Sam: new since the live store"]
        full = wae.parse_chat_text(export_text(extra), "Sam")
        new, matched = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
        check(len(new.messages) == 1 and new.messages[0].text == "new since the live store",
              "exactly one new message, the one the live store lacks")
        cid = wae.conversation_id(full)
        payload = wae.chat_to_payload(new, cid=cid)
        check(payload["conversation_id"] == cid, "the payload keeps the full chat's conversation_id")
        check(payload["metadata"]["message_count"] == 1, "the payload carries only the new message")


def scenario_digits_kept():
    print("3. digits are never collapsed: 'Call 12' and 'Call 21' stay distinct")
    set_zone("Asia/Hong_Kong")
    only_12 = live_conv([HK_ROWS[3]])
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript("c", live_transcript(only_12), index, OWNER)
        full = wae.parse_chat_text(export_text(["[10/11/2026, 10:00:00] Sam: Call 21"]), "Sam")
        new, _ = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
        check(len(new.messages) == 1, "'Call 21' is new against a live store holding only 'Call 12'")


def scenario_owner_names():
    print("4. the owner's own messages match only when the owner's name is known")
    set_zone("Asia/Hong_Kong")
    conv = live_conv([HK_ROWS[1]])
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
        full = wae.parse_chat_text(export_text(["[10/11/2026, 09:16:00] Jane: Make it 19:30"]), "Sam")
        new_known, _ = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
        new_unknown, _ = wae.drop_already_live(full, wae.live_key_counts(index), [])
        check(len(new_known.messages) == 0, "with owner name 'Jane', the owner's line matches")
        check(len(new_unknown.messages) == 1,
              "without the owner name, it does not match (the documented gap, not a silent drop)")


def scenario_dst():
    print("5. a summer message in a DST zone lines up in the owner's local time")
    set_zone("Europe/London")
    conv = live_conv([(utc(2026, 7, 10, 8, 0), False, "Summer")])  # 09:00 BST
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
        full = wae.parse_chat_text(export_text(["[10/07/2026, 09:00:00] Sam: Summer"]), "Sam")
        new, _ = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
        check(len(new.messages) == 0, "07:00 UTC live is 09:00 BST in the export, and it matches")
    set_zone("Asia/Hong_Kong")


def scenario_replace_not_append():
    print("6. a re-bundled chat replaces its entry, so nothing is counted twice")
    set_zone("Asia/Hong_Kong")
    conv = live_conv(HK_ROWS)
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
        wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
        counts = wae.live_key_counts(index)
        check(sum(counts.values()) == len(HK_ROWS),
              f"two bundles of one chat count {len(HK_ROWS)} keys, not {2 * len(HK_ROWS)}")


def scenario_no_index_is_not_silent():
    print("7. no live index means every export message is new, never a silent skip")
    set_zone("Asia/Hong_Kong")
    with tempfile.TemporaryDirectory() as tmp:
        full = wae.parse_chat_text(export_text(HK_EXPORT), "Sam")
        new, matched = wae.drop_already_live(full, wae.live_key_counts(Path(tmp) / "none.json"), OWNER)
        check(len(new.messages) == len(HK_EXPORT) and matched == 0,
              f"all {len(HK_EXPORT)} messages are new with no index (got {len(new.messages)})")


def scenario_multiset():
    print("10. two identical lines in one minute, one live copy: one is new")
    set_zone("Asia/Hong_Kong")
    conv = live_conv([HK_ROWS[6]])  # one 'ok' at 03:00 UTC = 11:00 HK
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "idx.json"
        wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
        full = wae.parse_chat_text(export_text(["[10/11/2026, 11:00:00] Sam: ok",
                                                "[10/11/2026, 11:00:00] Sam: ok"]), "Sam")
        new, matched = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
        check(len(new.messages) == 1 and matched == 1,
              f"one copy matched, one kept (new={len(new.messages)}, matched={matched})")


def controls():
    print("8. control: a digit-stripping normaliser fails scenario 3")
    real_plain = wae._plain
    try:
        wae._plain = lambda t: "".join(ch for ch in real_plain(t) if not ch.isdigit())
        set_zone("Asia/Hong_Kong")
        only_12 = live_conv([HK_ROWS[3]])
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "idx.json"
            wae.record_live_transcript("c", live_transcript(only_12), index, OWNER)
            full = wae.parse_chat_text(export_text(["[10/11/2026, 10:00:00] Sam: Call 21"]), "Sam")
            new, _ = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
            mutant_collides = len(new.messages) == 0
    finally:
        wae._plain = real_plain
    check(mutant_collides, "the digit mutant collides 'Call 21' with 'Call 12' (so check 3 can fail)")

    print("9. control: a filter that never consumes a live key fails scenario 10")
    real_drop = wae.drop_already_live

    def never_consumes(chat, live, owner_names=()):
        kept, matched = [], 0
        for m in chat.messages:
            k = wae.message_key(m.timestamp, m.sender, m.text, owner_names)
            if live[k] > 0:
                matched += 1
            else:
                kept.append(m)
        return WhatsAppChat_(chat.name, kept), matched

    try:
        WhatsAppChat_ = wae.WhatsAppChat
        wae.drop_already_live = never_consumes
        set_zone("Asia/Hong_Kong")
        conv = live_conv([HK_ROWS[6]])
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "idx.json"
            wae.record_live_transcript("c", live_transcript(conv), index, OWNER)
            full = wae.parse_chat_text(export_text(["[10/11/2026, 11:00:00] Sam: ok",
                                                    "[10/11/2026, 11:00:00] Sam: ok"]), "Sam")
            new, _ = wae.drop_already_live(full, wae.live_key_counts(index), OWNER)
            mutant_drops_both = len(new.messages) == 0
    finally:
        wae.drop_already_live = real_drop
    check(mutant_drops_both, "the non-consuming mutant drops both copies, so check 10 can fail")


def main():
    scenario_exactly_once()
    scenario_partial_keeps_id_and_only_new()
    scenario_digits_kept()
    scenario_owner_names()
    scenario_dst()
    scenario_replace_not_append()
    scenario_no_index_is_not_silent()
    scenario_multiset()
    controls()
    set_zone("UTC")
    print()
    if FAILS:
        print(f"RESULT: {len(FAILS)} FAIL")
        return 1
    print("RESULT: all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
