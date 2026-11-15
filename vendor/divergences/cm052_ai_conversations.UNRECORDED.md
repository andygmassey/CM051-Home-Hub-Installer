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
