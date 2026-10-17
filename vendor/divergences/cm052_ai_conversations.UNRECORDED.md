# cm052_ai_conversations: CM051-side divergences not captured by a patch

This tree has `divergence_patch = ""`, so a change made here cannot be
reconstructed from `source@pinned_sha`. Each section names the tree
`cm052_ai_conversations`, the files, what a future re-vendor must preserve,
and the test that guards it.

## AI chats older than the 365-day clamp are walked by the catch-up (v1.0.108)

Tree `cm052_ai_conversations`. NEW CM051-side behaviour, two files:

- `src/cm052/cli.py`: new `process_one(conv)`, the single per-conversation step (wire.post, then "l3_skipped" / "paused" / "posted"). `run` now calls it; its tallies are unchanged (a paused result still counts as written, exactly as before).
- `src/cm052/catchup.py` (NEW FILE): the `ai_conversations` adapter for `lib/ostler_catchup.py`. Discovers with no clamp, walks the conversations the 365-day clamp excluded newest first, five per batch, through `cli.process_one`. Reads the forward watermark `cli_state.json` READ-ONLY and never writes it. A paused subscription fails the item so the walk holds.

WHY: both production invocations pass `--since-days 365`, so history older than a year was discovered and dropped on every run, for ever. Measured on a 450-conversation, 5-year fixture: the install path covers 90 of 450.

### What a future sync must preserve

`process_one`, its use in `run`, and `catchup.py`. Guarded by `tests/test_catchup_photos_ai.py` (red on origin/main, wired in `.github/workflows/catchup-photos-ai.yml`). Registered by install.sh as `bin/catchup.d/35-aichats.sh`.
