#!/usr/bin/env python3
"""A WhatsApp export and the live channel get the same privacy level.

Both paths reach CM048's ``_whatsapp_resolve_privacy`` (vendor/cm048_pipeline/
src/channel_adapter.py) with the same inputs: the sensitivity verdict of the
classifier (processor step 01) and the operator labels. The export pins no level.
The classifier verdict is stubbed here, since the real one is an LLM call made by
``pwg-convo process`` for both paths.

Synthetic data only: the approved cast (Sam, Jane) and a reserved JID.
Controls: a mutant that drops the export's labels must fail the family arm.
Exit 0 pass, 1 fail, 2 CANNOT-RUN. Run bare: python3 tests/test_whatsapp_privacy_parity.py
"""

import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "vendor" / "cm048_pipeline"))

try:
    from ostler_fda import whatsapp_export as wae
    from whatsapp_source.reader import WhatsAppConversation, WhatsAppUtterance
    from whatsapp_source.renderer import build_metadata
    from ostler_fda.whatsapp_history import WhatsAppChat as LiveChat
    from src.channel_adapter import _whatsapp_resolve_privacy as resolve
    from src.schemas import Classification, Sensitivity
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


def cls(level):
    return Classification(
        setting="social", shape="one-on-one", stakes="low", confidence=0.9,
        reasoning="synthetic verdict", sensitivity=Sensitivity(level=level),
    )


def write_contacts(d: Path, label: str) -> Path:
    path = d / "contacts.yaml"
    path.write_text(
        "whatsapp:\n"
        "  contacts:\n"
        f'    "{PARTNER_JID}":\n'
        "      name: Sam\n"
        f"      contact_label: {label}\n",
        encoding="utf-8",
    )
    return path


def export_text():
    return (
        "[10/11/2026, 09:15:00] Sam: Dinner at 7?\n"
        "[10/11/2026, 09:16:00] Jane: Make it 19:30\n"
    )


def export_metadata(contacts_file, verdict=None):
    """The export side: the payload the importer hands to pwg-convo process."""
    os.environ["OSTLER_WHATSAPP_CONTACTS"] = str(contacts_file) if contacts_file else ""
    try:
        chat = wae.parse_chat_text(export_text(), "Sam")
        return wae.chat_to_payload(chat)["metadata"]
    finally:
        os.environ.pop("OSTLER_WHATSAPP_CONTACTS", None)


def live_metadata(label):
    """The live side: the metadata the live pipeline builds for the same DM."""
    chat = LiveChat(chat_id="chat-synthetic-1", tier="T1", is_group=False,
                    contact_jid=PARTNER_JID)
    conv = WhatsAppConversation(chat=chat, utterances=[
        WhatsAppUtterance(author_jid=PARTNER_JID, is_from_me=False,
                          timestamp=datetime(2026, 11, 10, 1, 15, tzinfo=timezone.utc),
                          text="Dinner at 7?"),
        WhatsAppUtterance(author_jid=None, is_from_me=True,
                          timestamp=datetime(2026, 11, 10, 1, 16, tzinfo=timezone.utc),
                          text="Make it 19:30"),
    ])
    return build_metadata(
        conv,
        name_for_jid=lambda jid: "Sam" if jid == PARTNER_JID else None,
        user_display_name="You",
        privacy_level=None,
        contact_label=label,
        group_label=None,
    )


def level_for(metadata, verdict):
    return resolve(metadata, cls(verdict))


GROUP_JIDS = ["447700900001@s.whatsapp.net", "447700900002@s.whatsapp.net", "447700900003@s.whatsapp.net"]
GROUP_NAMES = {GROUP_JIDS[0]: "Sam", GROUP_JIDS[1]: "Jane", GROUP_JIDS[2]: "Bob"}
GROUP_EXPORT = (
    "[10/11/2026, 19:00:00] Sam: Shall we meet Saturday?\n"
    "[10/11/2026, 19:01:00] Jane: Yes\n"
    "[10/11/2026, 19:02:00] Bob: Me too\n"
)


def write_groups_contacts(d: Path, chat_id: str, label: str) -> Path:
    path = d / "groups-contacts.yaml"
    path.write_text(
        "whatsapp:\n  groups:\n"
        f'    "group:{chat_id}":\n      group_label: {label}\n',
        encoding="utf-8",
    )
    return path


def live_group_conv(chat_id: str, subject: str):
    chat = LiveChat(chat_id=chat_id, tier="T2", is_group=True, contact_jid=None,
                    participants=list(GROUP_JIDS))
    utts = [
        WhatsAppUtterance(author_jid=GROUP_JIDS[0], is_from_me=False,
                          timestamp=datetime(2026, 11, 10, 11, 0, tzinfo=timezone.utc),
                          text="Shall we meet Saturday?"),
        WhatsAppUtterance(author_jid=GROUP_JIDS[1], is_from_me=False,
                          timestamp=datetime(2026, 11, 10, 11, 1, tzinfo=timezone.utc),
                          text="Yes"),
    ]
    return WhatsAppConversation(chat=chat, utterances=utts, group_subject=subject)


def live_index_group(index: Path, chat_id: str, subject: str):
    from whatsapp_source.renderer import render_transcript as render
    conv = live_group_conv(chat_id, subject)
    md = render(conv, name_for_jid=lambda j: GROUP_NAMES.get(j), user_display_name="You")
    wae.record_live_transcript(chat_id, md, index, is_group=True)


def live_group_metadata(chat_id: str, subject: str, group_label):
    return build_metadata(
        live_group_conv(chat_id, subject),
        name_for_jid=lambda j: GROUP_NAMES.get(j),
        user_display_name="You",
        privacy_level=None,
        contact_label=None,
        group_label=group_label,
    )


def export_group_metadata(subject: str):
    chat = wae.parse_chat_text(GROUP_EXPORT, subject)
    return wae.chat_to_payload(chat)["metadata"]


def group_arms():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        index = d / wae.LIVE_INDEX_FILENAME
        os.environ["OSTLER_STATE_DIR"] = str(d)
        os.environ.pop("OSTLER_WHATSAPP_OWNER_NAMES", None)

        print("8. an exported live family-labelled group lands L3")
        live_index_group(index, "g-weekend-1", "Hikers")
        contacts = write_groups_contacts(d, "g-weekend-1", "family")
        os.environ["OSTLER_WHATSAPP_CONTACTS"] = str(contacts)
        meta = export_group_metadata("Hikers")
        check(meta.get("group_label") == "family", f"export group_label {meta.get('group_label')!r} (want family)")
        check(level_for(meta, "normal") == "L3", f"exported family group -> {level_for(meta, 'normal')} (want L3)")

        print("9. parity on groups: live and export, same level")
        for label, verdict, want in (("family", "normal", "L3"), (None, "normal", "L2"),
                                     (None, "sensitive", "L3")):
            if label is None:
                contacts_g = write_groups_contacts(d, "g-other-chat", "family")  # no entry for this chat
                os.environ["OSTLER_WHATSAPP_CONTACTS"] = str(contacts_g)
                want_live_label = None
            else:
                want_live_label = label
            exp = export_group_metadata("Hikers")
            live = live_group_metadata("g-weekend-1", "Hikers", want_live_label)
            le, ll = level_for(exp, verdict), level_for(live, verdict)
            check(le == ll == want, f"group label={label} verdict={verdict}: export={le} live={ll} (want both {want})")

        print("10. no live group with that title: the sensitivity verdict alone decides")
        os.environ["OSTLER_WHATSAPP_CONTACTS"] = str(contacts)
        meta = export_group_metadata("Gardeners")
        check("group_label" not in meta, "no live match, so no group label")
        check(level_for(meta, "sensitive") == "L3", f"sensitive, unmatched group -> {level_for(meta, 'sensitive')} (want L3)")
        check(level_for(meta, "normal") == "L2", f"ordinary, unmatched group -> {level_for(meta, 'normal')} (want L2)")

        print("11. more than one live group with that title: fail closed to L3")
        live_index_group(index, "g-weekend-2", "Hikers")
        meta = export_group_metadata("Hikers")
        check(meta.get("privacy_level") == "L3", f"ambiguous group pins {meta.get('privacy_level')!r} (want L3)")
        check(level_for(meta, "normal") == "L3", f"ambiguous group, ordinary verdict -> {level_for(meta, 'normal')} (want L3)")

        print("12. control: a mutant that ignores the live index fails arm 8")
        real = wae.export_chat_labels
        try:
            wae.export_chat_labels = lambda chat, c, i: {}
            os.environ["OSTLER_WHATSAPP_CONTACTS"] = str(contacts)
            mutant = level_for(export_group_metadata("Hikers"), "normal")
        finally:
            wae.export_chat_labels = real
        check(mutant == "L2", f"the index-blind mutant gives {mutant}, so arm 8 can fail")
    os.environ.pop("OSTLER_WHATSAPP_CONTACTS", None)


def main():
    set_zone("Asia/Hong_Kong")
    with tempfile.TemporaryDirectory() as tmp:
        family_file = write_contacts(Path(tmp), "family")

        print("1. a family-labelled chat lands L3 on the export")
        meta = export_metadata(family_file)
        check("privacy_level" not in meta, "the export pins no privacy level")
        check(level_for(meta, "normal") == "L3", f"export family chat -> {level_for(meta, 'normal')} (want L3)")

        print("2. a highly-sensitive chat lands L3")
        meta = export_metadata(None)
        check(level_for(meta, "highly-sensitive") == "L3",
              f"highly-sensitive -> {level_for(meta, 'highly-sensitive')} (want L3)")

        print("3. a sensitive chat is escalated one tier, L2 to L3")
        check(level_for(meta, "sensitive") == "L3", f"sensitive -> {level_for(meta, 'sensitive')} (want L3)")

        print("4. an ordinary chat stays L2")
        check(level_for(meta, "normal") == "L2", f"normal -> {level_for(meta, 'normal')} (want L2)")

        print("5. parity: the same thread through the live adapter and the export")
        for label, verdict, want in (("family", "normal", "L3"),
                                     (None, "highly-sensitive", "L3"),
                                     (None, "sensitive", "L3"),
                                     (None, "normal", "L2")):
            exp_file = write_contacts(Path(tmp), label) if label else None
            exp = export_metadata(exp_file)
            live = live_metadata(label)
            le, ll = level_for(exp, verdict), level_for(live, verdict)
            check(le == ll == want,
                  f"label={label} verdict={verdict}: export={le} live={ll} (want both {want})")

        print("6. an unavailable verdict fails toward L3, never a lower level")
        got_none = resolve(live_metadata(None), None)  # no classification at all
        check(got_none == "L3", f"no classification -> {got_none} (want L3)")
        got_nolevel = level_for(live_metadata(None), None)  # classification, level None
        check(got_nolevel == "L3", f"classification with no level -> {got_nolevel} (want L3)")

        print("7. control: a mutant that drops the export labels fails arm 1")
        real = wae.export_labels
        try:
            wae.export_labels = lambda *a, **k: {}
            meta = export_metadata(family_file)
            mutant = level_for(meta, "normal")
        finally:
            wae.export_labels = real
        check(mutant == "L2", f"the no-label mutant gives {mutant}, so arm 1 can fail")

    group_arms()
    print()
    if FAILS:
        print(f"RESULT: {len(FAILS)} FAIL")
        return 1
    print("RESULT: all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
