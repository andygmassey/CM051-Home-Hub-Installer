# Vendored: generate_pwg_context.py

`bin/generate_pwg_context.py` is vendored from the `ostler-assistant`
repository. It is the personal-context digest generator that gives the
local assistant baseline awareness of the customer's people, meetings,
and preferences without the 9B local model having to call a tool every
turn.

> **DIVERGENT (grafted) copy -- NOT byte-identical to upstream.** This
> file was originally vendored byte-for-byte at `f441f09f` but has since
> carried CM051-local read-side fixes ahead of the upstream (see
> "Local divergence" below). Do NOT re-vendor with a clean `cp` -- that
> would silently drop the grafted fixes. Re-apply the patches on refresh.

| Field | Value |
|-------|-------|
| Upstream repo | `ostler-ai/ostler-assistant` |
| Upstream path | `scripts/generate_pwg_context.py` |
| Original vendor commit | `f441f09f` (feat(assistant): inject personal-graph CONTEXT.md digest + lookup guidance) |
| Original SHA-256 | `58d0c5e31d899ad994fb9413bd8d6d511d27433c84acaf01cff7119b2254a613` (pre-graft, historical) |
| Current SHA-256 | `27cc4d6e9a744a929e02e772185f406f9b8832b5acc64e887c4ed3ec2e89550b` (post-graft, this repo) |
| Vendored | 2026-06-02 (v1.0.1 launch-blocker #608) |
| Diverged | 2026-06-28 (calendar-owner attribution, BATCH1 #3) |
| Last divergence | 2026-09-09 (one route to the graph: the lookup paragraph names the pwg_ tools, not http_request). Matched upstream at `a9af0595` (ostler-assistant#394), so this one is a MIRROR, not a graft. |

## Local divergence (grafted on top of `f441f09f`)

These fixes MUST be preserved across any re-vendor. Five of the six are NOT
upstream; item 6 IS, and is listed anyway because a re-vendor still has to
carry it deliberately rather than assume a clean `cp` reproduces it. Read each
item's own last lines for its upstream status rather than this header, which is
the kind of blanket claim that goes stale one item at a time:

1. `_calendar_by_owner_section` -- calendar events selected with
   `pwg:sourceCalendar` / `pwg:calendarType`, grouped and labelled by
   owner, L3 dropped, so the model is handed pre-attributed facts and can
   never merge one person's trip into another's (BATCH1 #3, `838f7a1`).
2. Un-attributed upcoming-calendar section retired from `_meetings_section`
   (calendar-kind rows no longer leak un-attributed) (BATCH1 #3 F1,
   `af7fb1b`).
3. Unknown-owner calendar rows render under **"Unattributed"** (rendered
   LAST), never silently under "Your calendar" -- an unknown-owner event is
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
   divergence 4 natively and DROPS 1, 2, 3, 5 and 6. Carry them across, or
   land them upstream first. Divergence 6 IS filed upstream
   (ostler-assistant#394) and will stop needing to be carried the moment
   that merges and the vendor pin moves past it; until then it is carried
   like the rest.

6. **One route to the graph** (2026-09-09). The "Looking something up"
   paragraph told the model to fetch people live with `http_request`
   against `http://127.0.0.1:8090/api/v1/people/*`. That route works and
   `install.sh` enables `allow_private_hosts` for it deliberately, but it
   is invisible to everything that asks WHICH tool answered a turn.
   `assistant_answers_grounded` grades on a `pwg_` tool having run, so a
   correct answer fetched that way scores `memory_only`, which is one of
   the two shapes behind that probe's FAIL on the v1.0.79 walk; and the
   daemon's consolidation gate keyed live-graph state on the same prefix,
   so a count fetched that way was memorised as though it were durable.
   The paragraph now names `pwg_people` and `pwg_person_timeline`.
   UPSTREAM NOW CARRIES THE SAME EDIT plus a test: ostler-assistant#394,
     merged 2026-09-09 as `a9af0595878a423aa6b536fc560dd035510658d4`.
     So this item is a MIRROR, not a graft, unlike items 1 to 5. It is
     still listed because this copy is the one that SHIPS: the release
     tarball carries the daemon and its `.app` and never `scripts/`, so
     an upstream fix reaches a customer only by being here too.

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
blindly -- re-apply the local patches after taking the upstream base:

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
