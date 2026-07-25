# CUT_HYGIENE_GATE.md — the fail-closed cut-hygiene gate

`cut_hygiene_gate.sh` mechanically prevents the class of failures that bit the
v1.0.10 recut: built work on the wrong base branch, PRs built but not in the
merge set (orphans), stale pins (built ≠ shipped), vendored copies not
re-vendored, and docs that contradict the cut. It is the mechanical enforcement
of `HR015/launch/CUT_HYGIENE_CHARTER.md` (authoritative for the *why*).

## Where it lives and why here

`CM051/scripts/cut_hygiene_gate.sh` + `scripts/cut_manifest.v1010.tsv`, **beside
the content-provenance gate** (`scripts/provenance_gate.sh`,
`scripts/required_fixes.tsv`, `scripts/verify_cut_provenance.sh` — CM051 #436).
That is the established, **git-tracked** convention for a cut gate.

Why not `HR015/launch/` (where `cut_merge_preflight.sh`,
`verify_vendor_freshness.sh`, `verify_acceptance.sh` sit)? Because
`HR015/launch/` is **gitignored** — a local operator scratch area, not
version-controlled, so a gate placed there could never be reviewed, PR'd, or
protected from drift. `CM051/scripts/` is tracked and is where the sibling
provenance gate already lives.

The two gates are complementary and both run before ORM assembly:

- **provenance gate** (#436, CM051-internal): "the installer carries its
  required install.sh fixes" — verifies `required_fixes.tsv` symbols inside CM051.
- **hygiene gate** (this, cross-repo): "every intended item across every repo is
  on the right branch, routed, and reaches the artifact" — spans HR015, PWG,
  CM051, ostler-assistant, ostler-remote-capture, and reads the HR015 `launch/`
  cut docs. It does **not** replace #436.

Because it is cross-repo, at run time it reads two things that live outside CM051:
the cut docs (`BOX_WALK_V4_CHECKLIST.md`, `ORM_ASSEMBLY_BRIEF_v1010_recut_*.md`
in `HR015/launch/`, passed via `--docs`) and the estate PRs (via `gh`). The
manifest and script are self-contained in `scripts/`.

## What it checks

Reads a declarative **cut manifest** (TSV). For each row:

1. **PR exists**, state sane (OPEN or MERGED — never CLOSED-unmerged).
2. **Base branch correct** — `baseRefName == expected_base`. RED if a PR is on
   `main` when the manifest expects the integration line (the oa #228 failure).
3. **Not conflicting** — `mergeable != CONFLICTING` and `mergeStateStatus != DIRTY`.
4. **Path-to-artifact class check** (per the charter's classes):
   - `install-sh-native` → PR touches `install.sh` (light; WARN if not).
   - `vendored` → the row must declare a re-vendor pointer (else RED — the copy
     the DMG ships would stay stale).
   - `pinned-binary` → the row must declare a rebuild + re-pin step (daemon /
     RemoteCapture) (else RED — built ≠ shipped).
   - `pinned-image` → deferred to `provenance_gate.sh` (image digest/build).
   - `build-config` → PR touches a recognised build file (project.yml, Makefile,
     *.pbxproj, Package.swift, Cargo.toml, *.xcconfig) (light; WARN if not).
   - `separate-release` → WARN (OS001/CM031 have no DMG path — confirm agreed).
   - `ancestor` → informational (already an ancestor of the base; no assertions).
   - **unset / unknown class → RED** (fail-closed; never pass an unclassifiable item).

Then two sweeps:

5. **Orphan sweep** — for each repo in the manifest, list OPEN PRs and flag any
   that look cut-relevant (base == the integration line, or branch/title matches
   a cut theme) but are NOT in the manifest. Explicit `[no-merge]` / `[draft]` /
   `next-cut` markers are excluded. **LOUD (WARN) + printed for human
   confirmation, not auto-RED** — catches the rc #9-class "built but not routed"
   gap. (On the live v1.0.10 run this caught a *real* un-routed PR: CM051 #218.)
6. **Doc-consistency grep** — greps the cut docs for a line marking a manifest
   in-cut item as `deferred` / `not in this DMG` / `fast-follow`. **RED** (the
   FLAG-B stale-line class). Reversal/correction lines (struck-through, or
   containing `IN RECUT` / `NO LONGER` / `STALE-LINE` / `already in`) are ignored
   so a corrected stale line does not false-positive.

**Fail closed:** exits non-zero on any RED or any unclassifiable item. Prints a
per-row PASS / WARN / RED table + the orphan list + the doc-conflict list, then a
verdict. GREEN-with-warnings still exits 0 but every WARN needs human sign-off
before the cut.

## How ORM runs it (pre-assembly)

```bash
cd "CM051 - Home Hub Installer"

# 1. content-provenance gate (CM051-internal install.sh required-fixes)
./scripts/provenance_gate.sh

# 2. cut-hygiene gate (cross-repo routing / base / orphans / docs)
#    --docs is repeatable and takes ONE path each (paths like "HR015 - Gaming PC"
#    contain spaces, so never pack several into one flag).
./scripts/cut_hygiene_gate.sh \
    ./scripts/cut_manifest.v1010.tsv \
    --integration integration/hub-v1.0.10-recut \
    --docs "$HR015/launch/BOX_WALK_V4_CHECKLIST.md" \
    --docs "$HR015/launch/ORM_ASSEMBLY_BRIEF_v1010_recut_2026-07-25.md"

# both GREEN -> vendor-freshness + acceptance (HR015/launch/), then DMG assembly
```

Defaults if run with no args: manifest = `scripts/cut_manifest.v1010.tsv`
(sibling of the script), integration = `integration/hub-v1.0.10-recut`, docs =
`BOX_WALK_V4_CHECKLIST.md` + `ORM_ASSEMBLY_BRIEF_v1010_recut_2026-07-25.md`
(resolved next to the script, then relative to cwd — so pass `--docs` with
absolute paths unless you run it from `HR015/launch/`).

## The manifest

`cut_manifest.v1010.tsv` — the single source of truth for what is IN the cut.
Tab-separated: `repo  pr  expected_base  class  note  status`. Comment lines
start with `#`. **If a built PR is not a row here, the gate flags it as an
orphan.** Update it as SHAs land — copy it to `cut_manifest.v<next>.tsv` for the
next cut.

Repo alias → owner/slug + gh account is resolved inside the script
(`hr015`/`pwg`/`cm051` = **andygmassey**; `oa`/`rc` = **ostler-ai**). The gate
uses `GH_TOKEN=$(gh auth token --user <account>)` per repo (never embeds the
username in the remote URL) and unsets `HTTP(S)_PROXY` / `ALL_PROXY` so gh does
not go through the local Privoxy.

## Proof (v1.0.10, 2026-07-25)

- **RED on wrong base:** a test row pointing oa #207 (base `main`) at
  `expected_base = integration/hub-v1.0.10-recut` → `RED … <-- wrong-base (the
  #228 class)`, exit 1. (oa #228 itself had already been retargeted to the
  integration line by run time, so a stand-in main-based PR was used.)
- **Orphan detection:** the sweep flagged the *real* OPEN, un-routed CM051 #218
  ("re-vendor ostler_fda …") as an orphan candidate; adding it to the manifest
  suppressed the warning and the sweep immediately surfaced the next un-routed
  recut PR (CM051 #442, doctor re-pin).
- **Doc-consistency RED:** a synthetic stale doc line `rc #9 … deferred … NOT in
  this DMG` and `CM051 #434 fast-follow, not in this DMG` → 2× RED; a reversal
  line `oa #228 already in RECUT` was correctly ignored.
- **GREEN when clean:** the canonical manifest → 16 pass, 0 red, exit 0
  (warnings, e.g. the live CM051 #218 orphan, still require sign-off).
