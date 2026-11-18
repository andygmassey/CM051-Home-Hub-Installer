# cm052_ai_conversations: vendored edits NOT in the divergence patch

**Written 2026-11-11, CM051 #3429 (user-facing root moved to `~/Ostler`).**
**Location and shape only, never content.**

## Why there is no patch, measured rather than assumed

`scripts/regenerate_divergence_patch.sh cm052_ai_conversations` (dry run, 2026-11-11,
`CM052` exported to a local checkout) was NOT refused: the source is 3 commits past the
pin, all held by `hold_ack`. Its proposal covers 5 files (131 lines added, 9 removed).
The on-disk patch already records `catchup.py` and `cli.py` (manifest note, 2026-10-18),
so the proposal differs from disk mainly by #3429's path edits. The tool truncates its
diff-of-diffs, so that claim is NOT verified line by line here. Writing would replace
the whole patch, so it was not written. The on-disk patch is unchanged.

## The edits, by location and shape (all `~/Documents/Ostler` -> `~/Ostler`)

- `src/cm052/adapters/chatgpt_export.py` (3 edits): the default drop-folder constant
  `_DEFAULT_DROP_FOLDER`, and two docstring lines naming that default.
- `src/cm052/unifier.py` (1 edit): the drop-folder default string literal.
- `src/cm052/wire.py` (2 edits): the default constant `_DEFAULT_AI_CONVERSATIONS_DIR`,
  and one docstring line.

Shape: string literals and docstrings only. No function signature, no control flow, no
new import.

## Upstream

andygmassey/CM052 PR #22, not merged. Tests: `tests/`, 209 passed, 2 skipped (system
python, throwaway HOME). Mutation: restoring the old `_DEFAULT_AI_CONVERSATIONS_DIR`
makes `test_default_episodic_root_lives_under_home_ostler` fail (rc 1).

## 2026-11-16 (CM051 #3574, Archie ruling (b)): the included-window gate, two copies

Tree `cm052_ai_conversations` keeps its pin at `1ec05783` (no resync). The gate is
grafted into two vendored paths, byte-identical to the merged upstream file:

- source: CM052 `src/cm052/subscription_gate.py` at merge `fd7bf5c02f58` (CM052 #21)
- sha256 of the upstream file: `563284aca03499bfa1c9400fa2b4027c0b2a50df88ffe4139e3b174fd225a91d`
- sha256 of `vendor/cm052_ai_conversations/src/cm052/subscription_gate.py`: same value
- sha256 of `vendor/cm041/assistant_api/subscription_gate.py` (vendor-only row, VENDOR_ONLY.tsv): same value
- digest pin in `tests/test_g7_gate_copies_are_one.py` set to that value

The tree's other files are NOT resynced: `catchup.py` exists here and not upstream,
and `cli.py`, `schemas.py`, `wire.py`, `pyproject.toml` differ from upstream at
`fd7bf5c02f58`. The full resync is a 134 backlog item, with `catchup.py` upstreamed first.

## 2026-11-17 (134, branch 134/ai-conversations-vendor): the `[source_default]` table and its reader

Tree `cm052_ai_conversations`. NEW CM051-side files, not in CM052 at any pin:

- `src/cm052/privacy_scale_canonical.tsv`: a vendored copy of CM048's canonical privacy table with the `[source_default]` per-writer section (the CM048 #147 revision of 2026-11-17, before #147 moved that section into its own `privacy_source_defaults.tsv`). `ai_conversations` row L2. Its relabel comment line names the owner by role, not by first name.
- `src/cm052/source_defaults.py`: the reader beside it.

Guarded by `tests/test_ai_conversations_source_default_pin.py` (sha256 digest pin; re-pin = bytes + digest in one PR). Retire by vendoring CM048 #147's `privacy_source_defaults.tsv` once it merges, or by landing the reader in CM052 and re-pinning.

## 2026-11-17 (absent-tier fix, the 133 Box finding): gate re-grafted, digest re-pinned

The verifier PASS path reports tier_state `absent` for every production licence (CM050 mintLicense emits no `tier`). The gate counted only known and unknown as signed, so no founding or ff buyer got an included window. Fixed at the source: CM052 PR #26, head `31153f67c`, merged as the same bytes. Both vendored copies are byte-identical to it.

- sha256 now: `563284aca03499bfa1c9400fa2b4027c0b2a50df88ffe4139e3b174fd225a91d`
- previous: `b3c42937c78562afa4da297155117e77131f9cccfa8f6150c89dd5b7d4d5f161` (CM052 `fd7bf5c02`)
- digest pin in `tests/test_g7_gate_copies_are_one.py` re-set to the new value.

Tree `cm052_ai_conversations`: `vendor/cm052_ai_conversations/src/cm052/subscription_gate.py` re-grafted byte-identical. Tree pin stays `1ec05783`.

## 2026-11-17 (ORM, 134 CB134-FRESH): every edit above is now IN the patch

The tree was re-pinned to CM052 main f0b7b277 with vendored bytes unchanged and `vendor/divergences/cm052_ai_conversations.patch` regenerated against that pin (4 modified files, 1 vendor-only new file: `catchup.py`). The ~/Ostler path edits, the watermark graft and the not-taken G7 / Slack / owner-chat-pages features are recorded there as diff, not here as prose. `VENDOR_FRESH_STRICT=1 verify_vendor_fresh.sh` reports OK cm052_ai_conversations at f0b7b277.

## 2026-11-17 (134 PII unblock, CM052 #28): gate copies re-synced to the comment-only upstream text, digest re-pinned

CM052 #28 (draft, pin 32122a69) names the owner by role in six comment/docstring lines of `src/cm052/subscription_gate.py`; no code change. Both vendored copies (`vendor/cm052_ai_conversations/src/cm052/subscription_gate.py` and `vendor/cm041/assistant_api/subscription_gate.py`) now equal that file byte for byte.

- sha256 now: `e80d2d908ce20411ea1fecb3c2c01448ed1dcc3d4bcdfa2529ee4356692935e2`
- previous: `563284aca03499bfa1c9400fa2b4027c0b2a50df88ffe4139e3b174fd225a91d`
- digest pin in `tests/test_g7_gate_copies_are_one.py` re-set to the new value.
