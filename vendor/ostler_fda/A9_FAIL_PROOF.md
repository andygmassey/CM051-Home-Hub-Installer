# A9 fail-proof -- settling-progress writers alive + fresh

Per the launch-blocking brief at `/private/tmp/...ARCHIE_BRIEF_SETTLING_PROGRESS.md`
§7 and §10: the acceptance gate must **be proven to fail** when the writers
are disabled. A gate that cannot go red is decoration.

The gate is `scripts/a9_settling_progress.sh` (locally-runnable twin of the
inline A9 block in `~/bin/ostler-acceptance-gate.sh`, which SSHes to the
target Mac). Point it at an `OSTLER_STATE_DIR` that violates each invariant
and confirm it exits non-zero with a clear `A9 FAIL: <reason>` line.

## Reproduction (one-liner per case)

Seed the fixture states, then run the gate at each. All commands assume the
worktree root as CWD and use only a scratch directory -- no touching of the
real `~/.ostler/state`.

```bash
# 1. Seed the four fixture states.
python3 /private/tmp/claude-501/.../scratchpad/seed_a9_red.py \
    /private/tmp/claude-501/.../scratchpad

# 2. Run A9 against each.
GATE=./scripts/a9_settling_progress.sh
SCRATCH=/private/tmp/claude-501/.../scratchpad

OSTLER_STATE_DIR="$SCRATCH/a9_red/case1_no_dir"      "$GATE" ; echo exit=$?
OSTLER_STATE_DIR="$SCRATCH/a9_red/case2_empty"       "$GATE" ; echo exit=$?
OSTLER_STATE_DIR="$SCRATCH/a9_red/case3_zero_total"  "$GATE" ; echo exit=$?
OSTLER_STATE_DIR="$SCRATCH/a9_red/case4_stale"       "$GATE" ; echo exit=$?
OSTLER_STATE_DIR="$SCRATCH/a9_red/case5_green"       "$GATE" ; echo exit=$?
```

The `seed_a9_red.py` script builds the fixture states:

- **case1_no_dir** -- no `settling_progress.d/` at all (fresh install with
  no writers wired). Not seeded.
- **case2_empty** -- dir exists but no shards inside (writer imports OK, then
  crashes before first write). Just `mkdir -p .../settling_progress.d`.
- **case3_zero_total** -- five shards, but every `total=0` (writer runs on
  a schedule but always emits zeros; the reader would drop these silently).
- **case4_stale** -- one shard with `total=1200`, but `updated_at` is 15 min
  in the past (launchd penalty-box: fired once, exit 78, never retries).
- **case5_green** -- one shard with `total=250, updated_at=now` (control).

## Verbatim output -- RED cases

Captured 2026-08-06 from the worktree at
`/Users/andy/Documents/Projects/HR015 - Gaming PC/.claude/worktrees/agent-ae0f66f517d708b5f`.

### Case 1 -- `settling_progress.d` does not exist (fresh install)

```
A9 FAIL: settling_progress.d does not exist at /private/tmp/.../scratchpad/a9_red/case1_no_dir/settling_progress.d
exit=1
```

### Case 2 -- dir exists, no shards inside (writer never got past import)

```
A9 FAIL: no shard files in /private/tmp/.../scratchpad/a9_red/case2_empty/settling_progress.d
exit=1
```

### Case 3 -- every shard has `total=0` (writer emits nothing meaningful)

```
A9 FAIL: all shards have total=0 (calendar.json,contacts.json,emails.json,messages.json,notes.json) in /private/tmp/.../scratchpad/a9_red/case3_zero_total/settling_progress.d
exit=1
```

### Case 4 -- shard has `total>0` but is 15 min stale (penalty-box mode)

```
A9 FAIL: freshest shard contacts.json (key=contacts) is stale -- age=901s (>600s), total=1200. Likely launchd penalty-box (exit 78, never retries) or a producer that died after its first tick.
exit=1
```

### Case 5 (control) -- one fresh shard with `total>0`

```
A9 OK: messages.imessage.json (key=messages) total=250 age=1s
exit=0
```

## Interpretation

Each RED case maps to a real customer-facing regression the reader would
otherwise render as **the calendar countdown**, indistinguishable from
"the writers are working fine":

| Case | Real-world cause it catches |
|------|-----------------------------|
| 1    | Writers were never wired (dead-code, exactly the pre-brief state) |
| 2    | Writer's module imports OK but its first call raises before any shard exists |
| 3    | Writer runs on schedule but every call emits `total=0` -- reader excludes zero-total channels, aggregate `settling_progress()` returns `None`, panel falls back to calendar |
| 4    | launchd penalty-box: `RunAtLoad` fails, `exit 78`, never retries -- exactly the failure mode that killed email-ingest on this very box |

The gate is not decoration.
