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
| Current SHA-256 | `f9779f1a49f8e15675f18927669f9cbb52c0f899de2cf4056b568b510a383889` (post-graft, this repo) |
| Vendored | 2026-06-02 (v1.0.1 launch-blocker #608) |
| Diverged | 2026-06-28 (calendar-owner attribution, BATCH1 #3) |
| Last divergence | 2026-08-18 (service-token auth + loud failure) |

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
4. **Service-token authentication** (2026-08-18). **BACKPORT, not a new
   fix.** The pinned base `f441f09f` sends no `Authorization` header, so
   every `/api/v1/*` read has returned 401 since the ical-server data
   plane was locked at v1.0.10 (#200), and `CONTEXT.md` had never been
   produced on any install. Upstream fixed this in **ostler-assistant PR
   #232** ("v1.0.11 data-dark fix") and even gates it in CI, job
   "Context Digest Auth", step "Digest writer sends service-token auth".
   That gate has been green throughout. **It guards the copy that does
   not ship.** The release tarball carries the daemon binary and its
   `.app`, never `scripts/`, so the copy customers run is THIS one,
   pinned before #232, in a repo that had no such gate. The gate and the
   defect were not on different surfaces; they were in different
   repositories.

   Implemented to MATCH upstream so the eventual re-vendor is a merge
   and not a puzzle: same env var names (`OSTLER_SERVICE_TOKEN`, then
   `PWG_SERVICE_TOKEN`, then `$OSTLER_SERVICE_TOKEN_FILE` else
   `~/.ostler/secrets/service_token`), and both accepted header forms
   (`Authorization: Bearer` and `X-Ostler-Service`).

5. **Loud failure** (2026-08-18). **This half is NOT upstream, and is
   owed to it.** Upstream #232 fixed the auth and left both honesty
   defects in place: its `_get_json` still catches `HTTPError` in the
   same tuple as `URLError` and returns `None`, and its `main()` still
   prints "no data available (ical-server down or empty graph)" and
   returns 0. Upstream's own `_service_token` docstring predicts the
   consequence in writing: requests "will 401 against a locked server
   (surfaced by the caller as 'no data')". So the next silent failure of
   this pipeline is already paid for upstream.

   This copy instead: `_get_json` / `_sparql_select` RECORD every
   non-delivery with the status observed; `main` exits non-zero when the
   digest is empty (2) or degraded (3); and the invented failure cause
   (both halves of which were false on the install that surfaced this)
   is replaced by a report of what was measured. Regression suite:
   `context-refresh/tests/test_context_digest_auth.py`, plus the
   corrected `tests/test_context_refresh_wired.sh`, both wired in
   `.github/workflows/context-digest-auth.yml`.

   **Re-vendor guidance.** A re-vendor from current upstream main takes
   divergence 4 natively and DROPS 1, 2, 3 and 5. Carry 5 across, or
   land it upstream first.

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
