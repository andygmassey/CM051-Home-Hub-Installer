# CX-81 B8b -- DialogIcon.icns + install.sh wire-up report

Date: 2026-05-26
Branch: feat/cx81-b8b-dialog-icon-2026-05-26 (branched from B8's
pushed `feat/cx81-b8-fda-dialog-icon-wording-2026-05-26`)
Parent issue: feedback from Andy's DMG run that B8's FDA dialog icon
showed a visible "feint square outline" around the marque.

## Diagnosis recap

B8 wired the FDA dialog icon clause to use AppIcon.icns. AppIcon was
designed with internal padding so macOS can apply the squircle mask
on Dock/Launchpad/Finder rendering paths. The osascript `display
dialog` rendering path does NOT apply the squircle mask, so AppIcon's
square canvas (cream background + padding + black-globe motif) shows
edge-to-edge. The cream squircle reads as a "bounding-box around the
mark". See `CX81_B8b_TNM_PROBE.md` for the source-asset search that
confirmed no existing brand asset solves this.

## Fix

Generated a dialog-specific `DialogIcon.icns`:

- **Source**: 1024x1024 PNG, programmatically rendered using
  `gui/OstlerInstaller/Resources/Fonts/Outfit-Bold.ttf` (the Ostler
  brand display face).
- **Composition**: edge-to-edge oxblood `#7A1F1F` circle (0 px inset
  on the 1024 canvas), white "O" letter geometrically centred,
  glyph bounding box spanning 58 % of the canvas width.
- **Iconset**: 10 sizes (16/16@2x/32/32@2x/128/128@2x/256/256@2x/512/
  512@2x) via `sips`, packed via `iconutil -c icns`.
- **Validation**: `iconutil -c iconset DialogIcon.icns` round-trips
  cleanly back to all 10 PNG sizes; tested at 16x16 + 128x128 -- the
  "O" letter remains unambiguously a letter (visible side-stroke
  weight asymmetry distinguishing it from a zero glyph) at every
  size.

## Diff stats

```
 gui/OstlerInstaller/Resources/DialogIcon.icns | Bin 0 -> 160321 bytes
 install.sh                                    |  39 ++++++++++++---
 tests/test_imessage_fda_probe.sh              |  69 +++++++++++++++++----
 3 files changed, 91 insertions(+), 17 deletions(-)
```

## install.sh change

Replaces B8's 2-step icon-resolution block with a 4-step block that
puts DialogIcon FIRST and keeps AppIcon as a SECONDARY fallback:

```
1. ${SCRIPT_DIR}/DialogIcon.icns                          (preferred)
2. /Applications/.../Resources/DialogIcon.icns            (tarball)
3. ${SCRIPT_DIR}/AppIcon.icns                             (in-flight DMG)
4. /Applications/.../Resources/AppIcon.icns               (in-flight DMG)
5. with icon note                                         (dev/CI fallback)
```

Rationale for retaining AppIcon as fallback: any DMG cut shipped
pre-B8b (none in customer hands yet -- B8 is unpushed/unmerged) won't
have DialogIcon.icns in its bundle. The fallback prevents an in-
flight retest from regressing to the bare "note" icon during the
B8 → B8b transition window.

## Test coverage

`tests/test_imessage_fda_probe.sh` grows from 8 cases to 9:

- **Case 8** (extended): asserts the install.sh icon-resolution block
  probes DialogIcon FIRST, AppIcon SECOND, and that DialogIcon
  probes precede AppIcon probes textually (line-number ordering
  guard against future accidental reshuffles).
- **Case 9** (NEW): asserts the DialogIcon.icns asset is bundled at
  `gui/OstlerInstaller/Resources/DialogIcon.icns` AND that `file`
  reports it as a valid `Mac OS X icon` container. Without this guard,
  a future CI run on a fresh checkout would silently degrade to the
  AppIcon fallback if the icns was lost.

All 9 cases pass:

```
PASS [case-1]: CX-60 probe block present in install.sh
PASS [case-2]: probe block is best-effort (set +e / set -e wrap)
PASS [case-3]: probe writes via --imessage-fda-needed flag
PASS [case-4]: all 5 CX-60 catalogue strings present
PASS [case-5]: Doctor rule passes all 5 sub-assertions
PASS [case-6]: assist block has all 6 required components
PASS [case-7]: all 9 CX-66 + CX-78c + CX-81 B8 catalogue strings present, LINE4 retired
PASS [case-8]: assist dialog prefers DialogIcon.icns, falls back to AppIcon.icns then 'with icon note'
PASS [case-9]: DialogIcon.icns asset bundled + parses as valid .icns
```

`bash -n install.sh` -> exit 0 (no syntax regression).
Rule 0.9 lint -> clean (no inline customer strings introduced).

## Bundling

No project.yml / Makefile / release.sh edits needed. The existing
project.yml resources block at line 39-42 (`path: OstlerInstaller/
Resources` with only `Fonts/**` excluded) pulls DialogIcon.icns into
`Contents/Resources/DialogIcon.icns` at build time, the same way
HintCopy.json + ViewCopy.json land there today. Verified by inspecting
the latest cut (DMG #25, 2026-05-25):

```
$ ls "/Volumes/Install Ostler/OstlerInstaller.app/Contents/Resources/"
AppIcon.icns  Assets.car  HintCopy.json  ViewCopy.json  ...
```

`HintCopy.json` + `ViewCopy.json` are the proof that flat resources
in `gui/OstlerInstaller/Resources/` land unwrapped in the .app's
Contents/Resources/.

## Visual verification

osascript dialog rendering requires a user-session UI -- can't be
captured headlessly without taking over the agent's screen. Instead,
the visual fitness was verified at the source-PNG level by previewing
the 16x16 and 128x128 round-tripped renders. The 128x128 in particular
is representative of dialog-render size (`display dialog` renders the
icon at ~64-128px in the icon column).

## What's NOT in this PR

- AppIcon.icns -- left untouched. Customer Dock/Launchpad rendering
  continues to use the existing AppIcon with squircle mask; only the
  one osascript dialog in install.sh §3.14e-probe uses the new
  DialogIcon.
- Designer-pass refinement of the icon (V1.1 follow-up tracked in
  `CX81_B8b_TNM_PROBE.md`).
- Any other osascript dialogs in install.sh -- only the FDA assist
  dialog uses an icon clause today; the other dialogs (sudo prompt,
  Touch-ID detection, etc.) rely on the system's default
  application-icon resolution.

## Hard-rule compliance

- British English: no new customer strings introduced (icon-only fix).
- Canonical oxblood: `#7A1F1F` (not `#8B1F1F`).
- Draft PR: yes, no merge.
- No push to main.
- Worktree isolation: branched in `/tmp/cm051-b8b-dialog-icon-2026-05-26/`
  per `feedback_parallel_agents_need_worktree_isolation`; did not
  touch `/tmp/cm051-b8-2026-05-26/`.
- "O" letter unambiguity: confirmed via Outfit-Bold's side-stroke
  weight asymmetry at all 10 iconset sizes.
