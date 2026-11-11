# imessage_source: divergence not captured by the patch (v1.0.123, 2026-11-04)

Regeneration REFUSED, measured 2026-11-04: `VENDOR_PATCH_REGEN_CONFIRM=imessage_source
bash scripts/regenerate_divergence_patch.sh imessage_source --write` printed "could not
verify imessage_source: source repo not found ()". So this hand edit is recorded here.

## What changed

- `threader.py`: `Session.chat_handles` (every chat member, default empty);
  `thread_messages(..., members=None)` fills it; `build_metadata` adds
  `chat_handles` to the metadata when non-empty.
- `pipeline.py`: passes `members=convo.participants` (the reader's
  chat_handle_join list) to `thread_messages`.
- `catchup.py`: new `_members(conn, guid)` (chat_handle_join for the guid) and
  passes `members=` to `thread_messages`.

`participant_handles` (the speakers) is unchanged, so participant lists, the
per-contact L3 check and summaries are unchanged; only the follow-up thread key
reads `chat_handles` (via CM048 `_thread_basis_handles`).

## Why

Walk v1.0.122 diag: followup_keys_match_chat_threads 0 of 7. A group with a
silent member never matched the daemon's chat.db key. Proof:
tests/test_group_followup_key_counts_silent_members.py.

## Owed upstream

Yes: CM040 imessage source (`threader.py`, `pipeline.py`, `catchup.py`).

## 2026-11-11: user-facing root moved to ~/Ostler (CM051 #3429), imessage_source

The patch records only `__init__.py`'s docstring hunk (`imessage_source.patch`, changed in #3429). These two edits are NOT in the patch:

- `pipeline.py` (1 line): `~/Documents/Ostler/Conversations/...` in a docstring becomes `~/Ostler/Conversations/...`.
- `launchd/com.creativemachines.ostler.imessage-bundle.plist` (1 line): the root path in the plist text.

Upstream: NO PR. The code lives only on `origin/feat/4-artefact-imessage-first` in andygmassey/conversation-memory (CM040), not on its default branch, so there is no main to PR against. Blocked until the base branch is decided.
