# Vendored: generate_pwg_context.py

`bin/generate_pwg_context.py` is vendored from the `ostler-assistant`
repository. It is the personal-context digest generator that gives the
local assistant baseline awareness of the customer's people, meetings,
and preferences without the 9B local model having to call a tool every
turn.

> **DIVERGENT (grafted) copy — NOT byte-identical to upstream.** This
> file was originally vendored byte-for-byte at `f441f09f` but has since
> carried CM051-local read-side fixes ahead of the upstream (see
> "Local divergence" below). Do NOT re-vendor with a clean `cp` — that
> would silently drop the grafted fixes. Re-apply the patches on refresh.

| Field | Value |
|-------|-------|
| Upstream repo | `ostler-ai/ostler-assistant` |
| Upstream path | `scripts/generate_pwg_context.py` |
| Original vendor commit | `f441f09f` (feat(assistant): inject personal-graph CONTEXT.md digest + lookup guidance) |
| Original SHA-256 | `58d0c5e31d899ad994fb9413bd8d6d511d27433c84acaf01cff7119b2254a613` (pre-graft, historical) |
| Current SHA-256 | `adb39f521fafaa9f99c993e09feca5af1690ef1f02fba13756e00d930d7c95eb` (post-graft, this repo) |
| Vendored | 2026-06-02 (v1.0.1 launch-blocker #608) |
| Diverged | 2026-06-28 (calendar-owner attribution, BATCH1 #3) |

## Local divergence (grafted on top of `f441f09f`)

These fixes live here (not yet upstream) and MUST be preserved across any
re-vendor:

1. `_calendar_by_owner_section` — calendar events selected with
   `pwg:sourceCalendar` / `pwg:calendarType`, grouped and labelled by
   owner, L3 dropped, so the model is handed pre-attributed facts and can
   never merge one person's trip into another's (BATCH1 #3, `838f7a1`).
2. Un-attributed upcoming-calendar section retired from `_meetings_section`
   (calendar-kind rows no longer leak un-attributed) (BATCH1 #3 F1,
   `af7fb1b`).
3. Unknown-owner calendar rows render under **"Unattributed"** (rendered
   LAST), never silently under "Your calendar" — an unknown-owner event is
   never attributed to the operator (BATCH1 #3 F2, the fail-open fix).

## Why vendored rather than shipped in the assistant release

The assistant release tarball (`release/build-binary.sh` +
`release/wrap-in-app-bundle.sh`) bundles the daemon binary and its
`.app` wrapper only; it does not carry `scripts/`. The installer is
the half that owns the LaunchAgent wiring (the script's own docstring
says "the CM051 installer wires a LaunchAgent that calls this"), so
the script has to reach the customer's disk through CM051. Vendoring a
byte-identical copy is the self-contained launch-fix and mirrors the
existing `vendor/` pattern in this repo.

## Post-launch follow-up

Dedupe by adding `scripts/generate_pwg_context.py` to the assistant
release bundle and having CM051 reference the extracted path, removing
this copy. Tracked as a post-launch tidy; not a launch blocker.

## Refresh procedure

This is a **grafted** copy (see "Local divergence"). Do NOT `cp` over it
blindly — re-apply the local patches after taking the upstream base:

```sh
cp /path/to/ostler-assistant/scripts/generate_pwg_context.py \
   context-refresh/bin/generate_pwg_context.py
# RE-APPLY the local divergence patches listed above (calendar-owner
# attribution + Unattributed bucket), then:
shasum -a 256 context-refresh/bin/generate_pwg_context.py   # update Current SHA-256 above
```

The `vendor-integrity` workflow watches `context-refresh/**`, so a refresh
that drops the graft (or forgets to update the SHA) is caught pre-merge.

Pure Python standard library (urllib, json, pathlib, datetime); no
pip dependencies, so it runs under any `python3` on the customer Mac.
