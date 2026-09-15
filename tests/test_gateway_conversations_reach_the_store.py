#!/usr/bin/env python3
"""The customer's own Hub-chat (gateway) conversations must reach the
durable conversation store -- not merely have their adapter listed.

WHY THIS EXISTS

vendor/cm052_ai_conversations/src/cm052/unifier.py's ``_registry()`` has
always included ``zeroclaw_sessions`` (the gateway's own ``sessions.db`` --
the customer talking directly to Ostler through the Hub's own chat UI) as a
complete, tested adapter. But the ONLY production entrypoint,
``cli.py``'s ``_ai_adapters()``, which is what install.sh and the hourly
``com.ostler.aiconv-resume`` LaunchAgent actually invoke (always with
``--source all``), narrowed the adapter set to exclude it, citing one
docstring line: "belong to the human conversation pipelines, not to the AI
Conversations ingest engine."

That claim was investigated (2026-09-13), not assumed. It is TRUE for the
adapter's sibling, ``channel_jsonl`` (iMessage/WhatsApp/email channel-bridge
transcripts): the separate ``conversation-memory`` repo already tails the
exact same ``~/.zeroclaw/workspace/sessions/*.jsonl`` files for fact
extraction into the PWG context file, and wire.py's own docstring says these
files are meant to keep "the existing CM048-tier-1 markdown ... and do not
pass through this episodic path" -- so including channel_jsonl here would
fact-extract the same conversations through a second, uncoordinated route.
That reason is FALSE for ``zeroclaw_sessions`` itself: a GitHub code search
across every plausible human-conversation-pipeline repo (conversation-memory,
CM046-PWG-Email-Intelligence, CM047-PWG-WhatsApp-Mining,
CM042-PWG-Remote-Conversations, CM048-PWG-Conversation-Processing) found zero
references to ``sessions.db`` / ``session_metadata`` / ``zeroclaw_sessions``
outside CM052 itself -- confirmed against a positive control
(``parse_filename``, known to exist in conversation-memory, which the same
search DID find). Nothing else in the estate reads the gateway's own chat
history, so it never reached ANY durable store.

cli.py's ``_ai_adapters()`` now includes the gateway adapter under
``"gateway"`` and ``"all"`` (the only value production ever passes) while
channel_jsonl stays excluded, unchanged, for the verified reason above.

WHAT THIS PROVES, AND WHY EACH STEP EXISTS

A producer-side check ("the adapter is in the returned list") is exactly the
shape of proof that let this bug ship in the first place -- the adapter was
always complete and tested; only the wiring to reach it was missing. So this
walks the FULL consumer path a real install-time backfill or hourly tick
actually takes:

  1. the gateway adapter is present in ``_ai_adapters("all")`` (the value
     every production caller passes) -- and channel_jsonl is confirmed STILL
     absent, so this fix did not overcorrect into double-ingestion;
  2. ``unifier.unify()`` -- fed a REAL sqlite ``sessions.db`` fixture, not a
     mock -- actually YIELDS a ``Conversation`` for it, carrying the real
     message content;
  3. ``wire.stage()`` actually WRITES ``transcript.md`` + ``metadata.json`` to
     the outbox, and those files are READ BACK and shown to carry the real
     conversation content and the correct provenance -- landed, not just
     staged in memory;
  4. ``wire.post()`` -- with only the network transport faked, everything
     else real -- actually ATTEMPTS the POST to CM048 (the durable store's
     real entrypoint) rather than pausing or skipping, proving the
     subscription gate and the L3 privacy gate both let a normal L2 gateway
     conversation through.

Each step is a genuine precondition for the reader's memory ever seeing this
conversation; failing at any one of them is the bug this test exists to
catch.

Exit: 0 all pass, 1 a real failure, 2 CANNOT-RUN (vendored tree missing).
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDOR_ROOT = REPO_ROOT / "vendor" / "cm052_ai_conversations"


def _load_cm052():
    if not VENDOR_ROOT.is_dir():
        print(f"CANNOT-RUN: vendored tree missing at {VENDOR_ROOT}", file=sys.stderr)
        return None
    sys.path.insert(0, str(VENDOR_ROOT))
    try:
        from src.cm052 import cli, unifier, wire
        from src.cm052.adapters import channel_jsonl, zeroclaw_sessions
    except Exception as exc:  # noqa: BLE001 - report, do not crash the runner
        print(f"CANNOT-RUN: vendored cm052 package would not import: "
              f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return None
    return cli, unifier, wire, zeroclaw_sessions, channel_jsonl


def _make_gateway_db(path: Path) -> None:
    """A real gateway sessions.db, schema verified against
    adapters/zeroclaw_sessions.py's own docstring."""
    conn = sqlite3.connect(str(path))
    conn.executescript(
        """
        CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_key TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE session_metadata (
            session_key TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            last_activity TEXT NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0,
            name TEXT,
            state TEXT NOT NULL DEFAULT 'idle',
            turn_id TEXT,
            turn_started_at TEXT
        );
        """
    )
    conn.execute(
        "INSERT INTO session_metadata "
        "(session_key, created_at, last_activity, message_count, name) "
        "VALUES (?, ?, ?, ?, ?)",
        ("sess-1", "2026-09-01T09:00:00Z", "2026-09-01T09:05:00Z", 2,
         "calendar check"),
    )
    conn.executemany(
        "INSERT INTO sessions (session_key, role, content, created_at) "
        "VALUES (?, ?, ?, ?)",
        [
            ("sess-1", "user",
             "Ostler, what's on my calendar tomorrow", "2026-09-01T09:00:00Z"),
            ("sess-1", "assistant",
             "You have a 10am with the accountant.", "2026-09-01T09:05:00Z"),
        ],
    )
    conn.commit()
    conn.close()


class _FakeResponse:
    def raise_for_status(self):
        return None

    def json(self):
        return {"job_id": "fake-job", "status": "queued"}


def _make_fake_httpx_client(posted: dict):
    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def post(self, url, json=None):
            posted["url"] = url
            posted["json"] = json
            return _FakeResponse()

    return _FakeClient


def main() -> int:
    loaded = _load_cm052()
    if loaded is None:
        return 2
    cli, unifier, wire, zeroclaw_sessions, channel_jsonl = loaded

    failures: list[str] = []
    tmp = Path(tempfile.mkdtemp(prefix="cm052-gateway-test-"))
    try:
        hub_dir = tmp / "hub"
        hub_dir.mkdir()
        _make_gateway_db(hub_dir / "sessions.db")

        sub_state_path = tmp / "sub_state.json"
        sub_state_path.write_text(json.dumps({"status": "active"}), encoding="utf-8")

        os.environ["CM052_USER_HUB_DIR"] = str(hub_dir)
        os.environ["CM052_USER_EMAIL"] = "test-user@example.invalid"
        os.environ["OSTLER_SUBSCRIPTION_STATE"] = str(sub_state_path)

        # --- 1. the adapter reaches the ONLY entrypoint production calls,
        # and its excluded sibling stays excluded (no overcorrection). -------
        pairs_all = cli._ai_adapters("all")
        funcs_all = [p[0] for p in pairs_all]
        if zeroclaw_sessions.read not in funcs_all:
            failures.append(
                "_ai_adapters('all') does not include zeroclaw_sessions.read "
                "-- the gateway fix did not land in the production entrypoint")
        if channel_jsonl.read in funcs_all:
            failures.append(
                "_ai_adapters('all') now includes channel_jsonl.read -- this "
                "was deliberately left to conversation-memory's existing "
                "fact-extraction pipeline; including it here double-ingests "
                "the same channel conversations through a second route")

        gateway_pairs = cli._ai_adapters("gateway")
        if len(gateway_pairs) != 1 or gateway_pairs[0][0] is not zeroclaw_sessions.read:
            failures.append(
                f"_ai_adapters('gateway') did not return exactly the "
                f"zeroclaw_sessions pair, got {gateway_pairs!r}")
            print("\n".join(f"FAIL: {f}" for f in failures), file=sys.stderr)
            return 1

        # --- 2. unify() actually YIELDS the gateway conversation, with the
        # real message content, not just a listed adapter. --------------
        convs = unifier.unify(adapters=gateway_pairs)
        gateway_convs = [c for c in convs if c.provenance.source_kind == "zeroclaw_gateway"]
        if len(gateway_convs) != 1:
            failures.append(
                f"expected exactly 1 zeroclaw_gateway Conversation from "
                f"unify() over the fixture db, got {len(gateway_convs)}")
            print("\n".join(f"FAIL: {f}" for f in failures), file=sys.stderr)
            return 1
        conv = gateway_convs[0]
        if len(conv.messages) != 2:
            failures.append(
                f"expected 2 messages in the unified gateway conversation, "
                f"got {len(conv.messages)}")
        if not any("accountant" in m.content for m in conv.messages):
            failures.append(
                "the fixture's actual message content did not survive into "
                "the unified Conversation")

        # --- 3. wire.stage() actually LANDS it in the outbox, and the
        # written files are READ BACK, not just asserted to exist. --------
        transcript_path, metadata_path = wire.stage(conv, outbox_root=tmp / "outbox")
        if not transcript_path.is_file() or not metadata_path.is_file():
            failures.append(
                "wire.stage() did not write transcript.md/metadata.json for "
                "the gateway conversation")
        else:
            transcript_text = transcript_path.read_text(encoding="utf-8")
            if "accountant" not in transcript_text:
                failures.append(
                    "transcript.md was written but does not contain the "
                    "conversation's actual content -- staged, not readably")
            meta = json.loads(metadata_path.read_text(encoding="utf-8"))
            got_kind = meta.get("provenance", {}).get("source_kind")
            if got_kind != "zeroclaw_gateway":
                failures.append(
                    f"metadata.json provenance.source_kind is {got_kind!r}, "
                    f"expected 'zeroclaw_gateway'")

        # --- 4. wire.post() actually ATTEMPTS the CM048 POST (only the
        # network transport is faked; the subscription gate, the L3 privacy
        # gate and the staging all run for real). ------------------------
        posted: dict = {}
        real_client = wire.httpx.Client
        wire.httpx.Client = _make_fake_httpx_client(posted)
        try:
            result = wire.post(conv, outbox_root=tmp / "outbox2",
                               episodic_root=tmp / "episodic")
        finally:
            wire.httpx.Client = real_client

        if result.get("status") in ("paused", "skipped"):
            failures.append(
                f"wire.post() did not reach CM048 for the gateway "
                f"conversation: {result}")
        if "url" not in posted:
            failures.append(
                "wire.post() never called httpx.Client.post -- the CM048 "
                "POST that makes a conversation durable never happened")
        elif "transcript_path" not in (posted.get("json") or {}):
            failures.append(
                "the POST payload did not carry the staged transcript_path")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("FAIL: the customer's gateway conversations do not reach the "
              "durable store:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("gateway (zeroclaw_sessions) conversations: unified, staged, "
          "read back, and posted toward CM048 -- landed, not just listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
