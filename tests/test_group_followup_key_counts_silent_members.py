"""A group chat's follow-up key counts EVERY member, as the daemon does.

v1.0.122 diag (followup_keys_match_chat_threads, 0 of 7): the iMessage
threader handed CM048 only the members who SPOKE in a session window
(threader.py), while the assistant daemon keys a chat by ALL its
chat_handle_join handles (ostler-assistant followup.rs). A group with one
silent member therefore never matched, so its follow-ups never closed.

The expected key is the Rust reference vector for the three handles,
computed from thread_key_for_identities at ostler-assistant 644b6137
(tests/test_cm048_thread_key_matches_the_daemon.py, RUST_VECTORS).
Synthetic data only.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "vendor" / "cm048_pipeline"))
sys.path.insert(0, str(_ROOT / "vendor"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

from imessage_source.reader import Message  # noqa: E402
from imessage_source.threader import build_metadata, thread_messages  # noqa: E402
from src.bundle_extractor import BundleExtraction  # noqa: E402
from src.channel_adapter import make_bundle  # noqa: E402
from src.reminders_push import thread_key_for  # noqa: E402
from src.schemas import Classification  # noqa: E402

CC = "+" + "852"


def ph(tail):
    return CC + "5550" + tail


A, B, SILENT = ph("0001"), ph("0002"), ph("0003")
DAEMON_KEY_ALL_THREE = "0b571067bd9f7170"   # Rust vector for [0002, 0003, 0001]
CHAT = "any;+;chat900002"


def _key(members):
    t = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)
    msgs = [Message(rowid=i + 1, text="synthetic", sender=s, timestamp=t + timedelta(minutes=i),
                    is_from_me=False, chat_id=CHAT, has_attachment=False, service="iMessage")
            for i, s in enumerate([A, B, A])]
    sessions = thread_messages(CHAT, msgs, is_group=True, display_name="Synthetic group", members=members)
    assert len(sessions) == 1
    assert SILENT not in sessions[0].participant_handles, "control: the silent member never spoke"
    metadata = build_metadata(sessions[0], user_display_name="Mary Doe", name_for_handle=lambda h: "")
    classification = Classification.from_dict({
        "setting": "personal", "shape": "group", "stakes": "low", "confidence": 0.9,
        "reasoning": "synthetic", "sensitivity": {"level": "normal"},
    })
    bundle = make_bundle(metadata=metadata, classification=classification,
                         extraction=BundleExtraction(overall_summary="Synthetic."), transcript="synthetic")
    return thread_key_for(bundle, "user")


def test_a_silent_member_still_counts_in_the_group_key():
    assert _key([A, B, SILENT]) == DAEMON_KEY_ALL_THREE


def test_control_without_the_member_list_the_key_is_the_speakers_only():
    assert _key(None) != DAEMON_KEY_ALL_THREE
