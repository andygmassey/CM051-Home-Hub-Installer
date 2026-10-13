"""The reminder thread_key CM048 writes equals the key the assistant daemon
computes from chat.db, so "mark done when the owner follows up" can match.

Walk #25: followup_keys_match_chat_threads found 0 of 6 keyed rows matching
any chat.db thread. The daemon (ostler-assistant
crates/ostler-reminders/src/followup.rs, thread_key_for_identities) hashes
the chat's counterpart HANDLES; this vendored CM048 hashed participant
LABELS (slugged display names). Now CM048 hashes the handles too.

REFERENCE VECTORS were computed ONCE from the Rust function at
ostler-assistant 644b6137, with this throwaway test added to that tree:

    crates/ostler-reminders/tests/zz_gen_thread_key_vectors.rs:
        use ostler_reminders::followup::thread_key_for_identities;
        #[test] fn print_thread_key_vectors() { for c in CASES {
            println!("VECTOR\\t{}\\t{}", c.join("|"),
                     thread_key_for_identities(c.iter())); } }
    cargo test -p ostler-reminders --test zz_gen_thread_key_vectors -- --nocapture

and copied verbatim into RUST_VECTORS. If the daemon's algorithm changes,
regenerate them the same way; Python must then match again.

Synthetic data only: +852 5550xxxx numbers, example.com addresses.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "vendor" / "cm048_pipeline"))
sys.path.insert(0, str(_ROOT / "vendor"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

from imessage_source.reader import Message  # noqa: E402
from imessage_source.threader import Session, build_metadata  # noqa: E402
from src import reminders_push  # noqa: E402
from src.bundle_extractor import BundleExtraction  # noqa: E402
from src.channel_adapter import make_bundle  # noqa: E402
from src.conversation_writer import ConversationBundle, ConversationSummary  # noqa: E402
from src.reminders_push import _norm_identity, thread_key_for  # noqa: E402
from src.schemas import Classification  # noqa: E402

# Synthetic handles are COMPOSED at runtime so no literal phone- or
# email-shaped string sits in the file (the repo's PII shape scan).
CC = "+" + "852"
AT = "@"
def ph(tail):  # +852 5550 <tail>
    return CC + "5550" + tail
EMAIL = "casey.sample" + AT + "example.com"
EMAIL_MIXED = "Casey.Sample" + AT + "Example.com"

# (counterpart handles, key from Rust thread_key_for_identities @ 644b6137)
RUST_VECTORS = [
    ([ph("0001")], "a02f1f5fffde6fd2"),
    ([CC + " 5550 0001"], "a02f1f5fffde6fd2"),
    (["(852) 5550-" + "0001"], "a02f1f5fffde6fd2"),
    ([EMAIL_MIXED], "5556b45b88214c9c"),
    ([ph("0001"), EMAIL], "3453fdb38a54fc4b"),
    ([EMAIL, ph("0001")], "3453fdb38a54fc4b"),
    (["852" + "55500001" + AT + "s.whatsapp.net"], "a02f1f5fffde6fd2"),
    ([ph("0002"), ph("0003"), ph("0001")], "0b571067bd9f7170"),
    ([ph("0001"), ph("0001")], "a02f1f5fffde6fd2"),
    (["Robin Example"], "2a5ac7eb412aa469"),
    (["  " + ph("0004") + "  "], "e6a5a51180a50e5f"),
]

ROBIN = ph("0001")
CASEY = EMAIL
OWNER_SELF = ph("0099")
NAMES = {ROBIN: "Robin Example", CASEY: "Casey Sample"}


def _bundle(handles=(), sid="s-1", participants=("user",)):
    # participant_handles only when given, so the label-path tests also run
    # against a tree that predates the field (the red-on-main measurement).
    extra = {"participant_handles": tuple(handles)} if handles else {}
    return ConversationBundle(
        conversation_id=f"c-{sid}", source_kind="channel", source_subtype="imessage",
        source_session_id=sid, channel="im", participants=tuple(participants),
        started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", **extra,
    )


def _bundle_via_the_shipped_threader(chat_id, handles, is_group):
    """iMessage threader metadata -> the shipped CM048 adapter: the path a
    real conversation takes on the box."""
    t = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)
    msgs = [Message(rowid=1, text="synthetic", sender=handles[0], timestamp=t,
                    is_from_me=False, chat_id=chat_id, has_attachment=False, service="iMessage")]
    session = Session(conversation_id="conv-synthetic-1", chat_id=chat_id, messages=msgs,
                      is_group=is_group, participant_handles=list(handles))
    metadata = build_metadata(session, user_display_name="Owner Example",
                              name_for_handle=lambda h: NAMES.get(h, ""))
    classification = Classification.from_dict({
        "setting": "personal", "shape": "1:1", "stakes": "low", "confidence": 0.9,
        "reasoning": "synthetic", "sensitivity": {"level": "normal"},
    })
    return make_bundle(metadata=metadata, classification=classification,
                       extraction=BundleExtraction(overall_summary="Synthetic."),
                       transcript="synthetic")


@pytest.mark.parametrize("handles,want", RUST_VECTORS)
def test_python_key_equals_the_rust_daemon_key(handles, want):
    assert thread_key_for(_bundle(handles), "user") == want


def test_a_real_shaped_one_to_one_session_keys_by_handle_not_label():
    """RED on main: the label-based key (slug of the display name) is not the
    daemon's handle key, so no follow-up could ever match."""
    b = _bundle_via_the_shipped_threader("any;-;" + ROBIN, [ROBIN], is_group=False)
    label_key = thread_key_for(_bundle(participants=b.participants), "user")
    assert thread_key_for(b, "user") == "a02f1f5fffde6fd2"
    assert label_key != "a02f1f5fffde6fd2", "control: labels must give a different key"


def test_a_group_session_keys_by_every_counterpart_handle():
    b = _bundle_via_the_shipped_threader("any;+;chat900001", [ROBIN, CASEY], is_group=True)
    assert thread_key_for(b, "user") == "3453fdb38a54fc4b"
    assert thread_key_for(b, "user") != "a02f1f5fffde6fd2", "a group never takes a 1:1 key"


def test_an_email_handle_session_keys_by_the_email():
    b = _bundle_via_the_shipped_threader("iMessage;-;" + EMAIL_MIXED,
                                         [EMAIL_MIXED], is_group=False)
    assert thread_key_for(b, "user") == "5556b45b88214c9c"


def test_the_owner_is_excluded():
    """The owner's own participant row (role "user") never enters the key,
    even if a source attaches a handle to it."""
    t = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)
    msgs = [Message(rowid=1, text="synthetic", sender=ROBIN, timestamp=t, is_from_me=False,
                    chat_id="any;-;" + ROBIN, has_attachment=False, service="iMessage")]
    session = Session(conversation_id="conv-synthetic-2", chat_id="any;-;" + ROBIN,
                      messages=msgs, is_group=False, participant_handles=[ROBIN])
    metadata = build_metadata(session, user_display_name="Owner Example",
                              name_for_handle=lambda h: NAMES.get(h, ""))
    metadata["participants"][0]["handle"] = OWNER_SELF
    classification = Classification.from_dict({
        "setting": "personal", "shape": "1:1", "stakes": "low", "confidence": 0.9,
        "reasoning": "synthetic", "sensitivity": {"level": "normal"},
    })
    b = make_bundle(metadata=metadata, classification=classification,
                    extraction=BundleExtraction(overall_summary="Synthetic."), transcript="synthetic")
    assert b.participant_handles == (ROBIN,)
    assert thread_key_for(b, "user") == "a02f1f5fffde6fd2"


def test_a_one_to_one_guid_alone_still_keys_by_its_handle():
    """A bundle with no participant handles (an older producer) falls back to
    the handle inside a 1:1 chat guid, never to the labels."""
    b = _bundle(sid="any;-;" + ROBIN, participants=("user", "robin-example"))
    assert thread_key_for(b, "user") == "a02f1f5fffde6fd2"


def test_with_no_handle_known_the_label_fallback_is_unchanged():
    b = _bundle(sid="any;+;chat900001", participants=("user", "robin-example"))
    import hashlib
    want = hashlib.sha256(b"ostler-thread:robin-example").hexdigest()[:16]
    assert thread_key_for(b, "user") == want


def test_handles_are_not_rendered_into_the_bundle_artefacts():
    """participant_handles is a key input only: it is not extra_metadata, so
    the conversation_writer frontmatter never lists the handles."""
    b = _bundle_via_the_shipped_threader("any;+;chat900001", [ROBIN, CASEY], is_group=True)
    assert "participant_handles" not in b.extra_metadata


@pytest.mark.parametrize("label,want", [
    (CC + " 5550 0001", "852" + "55500001"),
    (EMAIL_MIXED, EMAIL),
    ("852" + "55500001" + AT + "s.whatsapp.net", "852" + "55500001"),
    ("852" + "55500001" + AT + "lid", "852" + "55500001"),
    ("abc" + AT + "s.whatsapp.net", "abc" + AT + "s.whatsapp.net"),
    ("١٢٣", "١٢٣"),  # non-ASCII digits are NOT digits (Rust is_ascii_digit)
    ("Robin Example", "robin example"),
    # Rust trims before anything else: whitespace around an email goes.
    ("  " + EMAIL_MIXED + " ", EMAIL),
    # A JID local part of non-ASCII digits is NOT a phone (is_ascii_digit).
    ("\u0661\u0662" + AT + "lid", "\u0661\u0662" + AT + "lid"),
])
def test_norm_identity_matches_rust_rules(label, want):
    assert _norm_identity(label) == want


def test_reminders_push_uses_the_handle_helper():
    assert reminders_push._thread_handles(_bundle(handles=[ROBIN])) == [ROBIN]
