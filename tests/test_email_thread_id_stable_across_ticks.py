"""A grown email thread keeps ONE thread_id and ONE conversation folder.

Suspected defect (box evidence: 6,168 of 6,930 overlapping folder pairs were
one email folder's Message-IDs wholly inside another's). email_source keys its
watermark on ``thread_id`` (the EARLIEST message in the read window), and the
CM048 folder is derived from ``conversation_id``, which hashes that same root.
When the window moves, or a missing parent arrives, the root changes, so the
same conversation looks new and is bundled into a second folder.

These drive the SHIPPED ``email_source.pipeline.process_email`` over a synthetic
Apple Mail tree and a stub pwg-convo, across two ticks, and assert on the
conversation_id (the folder key) handed to CM048. Synthetic data only
(example.test addresses, fictional names).
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))

from email_source.pipeline import process_email  # noqa: E402
from email_source.tests.test_email_source import (  # noqa: E402
    USER_ADDRESS,
    _emlx_bytes,
    _StubDispatch,
    _write_emlx,
)

PEER = "casey@partner.test"
SUBJECT = "Quarterly planning notes"


def _msg(mail, name, mid, days_ago, *, mine=False, parent=None, refs=None,
         subject=SUBJECT):
    dt = datetime.now(tz=timezone.utc) - timedelta(days=days_ago)
    _write_emlx(mail, name, _emlx_bytes(
        message_id=mid,
        from_addr=USER_ADDRESS if mine else PEER,
        from_name="Operator Synthetic" if mine else "Casey Synthetic",
        to_addr=PEER if mine else USER_ADDRESS,
        subject=subject if not parent else f"Re: {subject}",
        dt=dt, body=f"body of {mid}",
        in_reply_to=parent, references=refs,
    ))


def _tick(mail, stub, cmd, state, since_days):
    # Pin the first-window ladder off so tick 1 reads exactly since_days (a
    # sparse synthetic box would otherwise widen and see the root at once).
    if not state.exists():
        state.write_text(json.dumps({"first_window": {"days": since_days, "result": "kept"}}))
    return process_email(
        mail_dir=mail, user_display_name="Op", user_address=USER_ADDRESS,
        since_days=since_days, pwg_convo_cmd=cmd, state_path=state,
    )


def _ids(stub):
    recs = stub.load_all()
    return {r["metadata"]["conversation_id"] for r in recs}, {
        r["metadata"]["email_thread"]["thread_id"] for r in recs
    }


def test_window_moves_forward_root_drops_out(tmp_path):
    """Tick 1 sees root+r1+r2. Tick 2's narrower window drops the root and a
    new reply r3 arrives, so the earliest message in view is now r1."""
    mail = tmp_path / "Mail"
    root = "root@partner.test"
    _msg(mail, "m0", root, 6)
    _msg(mail, "m1", "r1@example.test", 3, mine=True, parent=root, refs=[root])
    _msg(mail, "m2", "r2@partner.test", 1.5, parent="r1@example.test",
         refs=[root, "r1@example.test"])
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    _tick(mail, stub, cmd, state, since_days=7)
    _msg(mail, "m3", "r3@example.test", 0.5, mine=True, parent="r2@partner.test",
         refs=[root, "r1@example.test", "r2@partner.test"])
    _tick(mail, stub, cmd, state, since_days=4)

    conv, tid = _ids(stub)
    assert len(conv) == 1 and len(tid) == 1, (
        f"one grown thread became {len(conv)} conversation folders / {len(tid)} thread_ids: {sorted(conv)}"
    )


def test_missing_parent_arrives_later(tmp_path):
    """Tick 1's window holds only replies (their parent is outside it). Tick 2
    widens and the original root appears."""
    mail = tmp_path / "Mail"
    root = "root@partner.test"
    _msg(mail, "m0", root, 6)
    _msg(mail, "m1", "r1@example.test", 3, mine=True, parent=root, refs=[root])
    _msg(mail, "m2", "r2@partner.test", 1.5, parent="r1@example.test",
         refs=[root, "r1@example.test"])
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    _tick(mail, stub, cmd, state, since_days=4)
    _tick(mail, stub, cmd, state, since_days=7)

    conv, tid = _ids(stub)
    assert len(conv) == 1 and len(tid) == 1, (
        f"one grown thread became {len(conv)} conversation folders / {len(tid)} thread_ids: {sorted(conv)}"
    )


def _seed_folders(stub, root):
    """Run every captured dispatch through the SHIPPED zero-model writer
    (seed_conversation -> conversation_writer.write_conversation) and return
    the conversation folders it produced."""
    sys.path.insert(0, str(REPO / "vendor" / "cm048_pipeline"))
    from src.seed import seed_conversation
    from src.settings import Settings

    settings = Settings(user_id="synthetic-owner", output_conversations_dir=root)
    for rec in stub.load_all():
        if rec["cmd"] != "process":
            continue
        md = rec["metadata"]
        seed_conversation(md["conversation_id"], rec["transcript"], md, settings)
    return sorted(p.parent for p in root.glob("*/*/summary.md"))


def test_grown_thread_writes_into_one_folder(tmp_path):
    """Same scenario as the first test, but through the real writer: the
    customer's disk must hold ONE folder, so one set of facts and todos."""
    mail = tmp_path / "Mail"
    root = "root@partner.test"
    _msg(mail, "m0", root, 6)
    _msg(mail, "m1", "r1@example.test", 3, mine=True, parent=root, refs=[root])
    _msg(mail, "m2", "r2@partner.test", 1.5, parent="r1@example.test",
         refs=[root, "r1@example.test"])
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    _tick(mail, stub, cmd, state, since_days=7)
    _msg(mail, "m3", "r3@example.test", 0.5, mine=True, parent="r2@partner.test",
         refs=[root, "r1@example.test", "r2@partner.test"])
    _tick(mail, stub, cmd, state, since_days=4)

    folders = _seed_folders(stub, tmp_path / "Conversations")
    assert len(stub.load()) == 2, "tick 2 must still dispatch the new reply"
    assert len(folders) == 1, f"folders on disk: {[f.name for f in folders]}"


def test_unrelated_thread_sharing_only_a_subject_stays_separate(tmp_path):
    """Two strangers who both write 'Invoice' with no reference headers are two
    conversations, not one (the subject fallback must not merge strangers)."""
    mail = tmp_path / "Mail"
    _msg(mail, "s1", "inv1@partner.test", 2, subject="Invoice")
    dt = datetime.now(tz=timezone.utc) - timedelta(days=1)
    _write_emlx(mail, "s2", _emlx_bytes(
        message_id="inv2@other.test", from_addr="robin@other.test",
        from_name="Robin Synthetic", to_addr=USER_ADDRESS, subject="Invoice",
        dt=dt, body="a different invoice from a different person",
    ))
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    _tick(mail, stub, cmd, tmp_path / "state.json", since_days=7)
    conv, _ = _ids(stub)
    assert len(conv) == 2, f"two strangers merged into {len(conv)} conversation(s)"
