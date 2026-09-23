# doctor -- the "Where your data came from" panel exists only in this repo

**Hand-built 2026-09-23. Board #2219. Location, shape and measurement only.**

The Doctor's source-status panel ships in the DMG and **has never existed in
HR015**, which is the repository `vendor/VENDOR_MANIFEST.toml` names as its
source. So the ordinary reading of a vendored tree -- "the real copy is
upstream, this one is a mirror" -- is false here, and every mechanism that
acts on that reading is dangerous on this tree.

This file is a record, not an instrument. Nothing reads it and it cannot be
applied. It is named from the tree's `regenerate_forbidden_reason`, which is
the one surface a person is guaranteed to meet at the moment they are deciding
whether to override.

**It is NOT an `.UNRECORDED.md`.** The other files under this directory carry
that suffix because the divergence patch could not be made to describe them.
Here the patch describes the panel completely, and that was re-measured rather
than assumed (below). Naming this file UNRECORDED would state the opposite of
what was measured, and the wrong version is the more dangerous one.

## 1. The panel is absent upstream. Measured on three refs, controls both ways

Predicate: `git grep -l -F -- <symbol>`, run in the HR015 checkout, counting
FILES. Run against the working tree, against the `origin/main` ref, and against
the pinned sha, because a working tree can be dirty and a ref cannot.

| symbol | HR015 working tree | HR015 `origin/main` | HR015 @ pin `b0b38310` | CM051 `vendor/doctor` |
|---|---|---|---|---|
| `read_source_status` | 0 | 0 | 0 | 1 |
| `_SOURCE_KINDS` | 0 | 0 | 0 | 1 |
| `_FDA_EXTRACT_KINDS` | 0 | 0 | 0 | 1 |
| `render_source_status` | 0 | 0 | 0 | 1 |
| the panel's own heading text | 0 | 0 | 0 | 1 |

Controls, in the same runs, because a bare zero is worth nothing:

- MUST BE FOUND, working tree and `origin/main`: `collect_licence_state`, **2
  files** each. At the pin that symbol does not yet exist, so the control there
  is `def render_dashboard` (**1**) and `dashboard_components` (**9**).
- MUST BE FOUND NOWHERE: a fabricated symbol, **0** on every ref.

The predicate therefore discriminates in both directions on every ref that was
read, and the zeros are real absences rather than a search that could not look.

`origin/main` was `60762906`. The whole tracked HR015 tree was swept, not just
`doctor/`, and the sweep of `doctor/` alone and of the whole tree agree.

Sizes, as a second independent shape: `doctor/agent/web_ui.py` is **3,927**
lines at the pin and **4,992** on HR015 `origin/main`; the vendored copy is
**6,755**.

## 2. The divergence IS fully captured, and that is not the same as safe

`scripts/sync_vendor.sh doctor --regen-patch` was run FIRST, before anything
else touched the tree, because the ostler_fda precedent recorded in
`scripts/sync_vendor.sh` is that a sync run without it returned rc=0, printed a
clean summary and deleted 230 lines including two tracked launch fixes.

It produced a **byte-identical** patch:

| | before | after |
|---|---|---|
| `doctor.patch` lines | 10,584 | 10,584 |
| files modified (`--- a/`) | 18 | 18 |
| vendor-only new-file hunks (`--- /dev/null`) | 5 | 5 |
| sha256 | `597dd14e45f39aa...` | `597dd14e45f39aa...` |

`git status` after the run: clean. So the capture was already complete, and the
run PROVES that rather than assuming it.

Reconstruction, which is the claim that actually matters: `source@b0b38310` +
`doctor.patch` was rebuilt in a scratch directory and compared against
`vendor/doctor`.

- `agent/web_ui.py`: 3,927 lines at the pin, **6,755 after the patch**,
  byte-identical to the vendored file.
- all five panel symbols: **0** in the raw source, **1** after the patch, **1**
  in the vendored tree.
- whole tree: identical except four files that the row's own `exclude` globs
  remove from the source side by instruction (`README.md`, `test_*.py`). One of
  those, `agent/test_daemon_cron.py`, additionally carries a
  `vendor/VENDOR_ONLY.tsv` row.

The reconstruction probe was mutation-tested before its answer was believed.
Arm A appended one line to a shared vendored file: **1 modified file of
undescribed divergence**. Arm B added an unregistered vendor-only file: **1
vendor-only file**. Restored arm: **0**. It fires on both shapes of loss.

## 3. Why a complete patch is still not a source, and what that costs

`doctor.patch` is **generated from the vendored tree**. It is a second copy
inside this repository, derived from the first, and both are inside CM051.
There is no third copy anywhere.

That closes the loop the ostler_fda incident opened. A sync rebuilds the tree
from `source@new_sha` + the patch, and then **step 4 regenerates the patch from
the result**. If the tree loses content, the patch is rewritten from the lossy
tree and the freshness gate goes green over the deletion. On an ordinary tree
that costs a graft, recoverable from upstream. On this one it costs the panel,
and there is nowhere to recover it from: the DMG carries behaviour whose only
source is the copy that was overwritten.

What a customer loses, from board #2219's own consumer-side measurement: a
Doctor that cannot check the licence acknowledgement, no beta entitlement
window, a pairing QR their phone cannot open, a keepalive reporting on an object
nobody runs, and a status daemon that forks until macOS kills it.

## 4. What was set, and why that flag rather than the existing refusal

`regenerate_forbidden = true` with `regenerate_forbidden_reason`, following
`cm041/contact_syncer`, which has carried the same pair since 2026-08-28.

The refusal a recorded divergence otherwise relies on is wrapped in
`if [ "${SYNC_ACCEPT_DIVERGENCE_LOSS:-0}" != "1" ]`, so one environment variable
switches it off, and CM051 #2068, which would make an unregenerable divergence
impossible to override, is still open. `regenerate_forbidden` has no such
escape:

- it is checked **before** the source checkout, so it cannot be cleared by
  re-pointing an env placeholder or moving a checkout;
- **both** entry points refuse, `scripts/regenerate_divergence_patch.sh` and
  `scripts/sync_vendor.sh`, through one shared helper,
  `vlib_refuse_if_regenerate_forbidden`;
- a ban with no declared reason is **still** a refusal, so it fails closed on
  malformed input.

It bans every mode of `sync_vendor.sh`, `--regen-patch` included. That is the
intent: this tree must not be re-vendored by a command, only by a person who
has first read this file and deliberately removed the flag.

## 5. How this is retired

Not by clearing the flag. The panel is lifted into HR015 so it has a real
upstream, the pin is advanced to a commit that contains it, and the flag goes
with the reason. Until then the flag is the only thing standing between a
routine re-pin and the silent deletion of a shipped customer surface.

This file carries no freshness gate and nothing verifies it. Every number above
was measured on 2026-09-23 and the method is written down so it is cheap to
re-derive or refute.
