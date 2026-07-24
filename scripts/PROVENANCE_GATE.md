# Content-provenance gate (`provenance_gate.sh`)

Systemic fix for the recurring **stale-pin** release failure: a fix merges to a
source main, the artefact is re-pinned, a ledger row records the new source SHA,
the gate goes GREEN on the ledger's *claim* -- but the artefact was actually
built from OLDER source, so it ships broken behind a green gate.

## The hole this closes

The wiki image ships pinned by **digest** in `install.sh`
(`image: ghcr.io/ostler-ai/ostler-wiki-compiler@sha256:...`). Two gates already
guard the cut, and a wiki fix falls between them:

| Gate | What it checks | The gap |
|------|----------------|---------|
| `verify_cut_freshness.sh` | ledger's recorded `digest -> CM044 sha` vs CM044 main HEAD | **trusts the ledger's self-asserted SHA.** Nothing proves the digest was *built from* that SHA -- the image has no CM044 revision label (proven: `docker inspect` labels are `null` on the compiler image; the site image's only revision label is the **mkdocs-material base image's**, not CM044's). Record the right SHA, bake the wrong content -> GREEN. |
| `verify_cut_provenance.sh` | greps inside the pinned image for a fix's marker | **only for markers a human remembered to add** as `wiki_image_grep` rows in `cut_markers.manifest`. CM044 #144/#145/#146 have **no** such rows -> their content is unverified. "Forgot the marker" is the same silent-drift class the gate suite exists to kill. |

`provenance_gate.sh` drives content verification from **one declarative list**
(`required_fixes.tsv`) that names the launch-blocking commits, so a merged fix
can no longer slip because someone forgot a marker. For every required fix it
proves, on the **actual** shipped artefact:

1. **Ancestry** -- the artefact's recorded source SHA (ledger / vendor pin /
   daemon tag) is a descendant of the fix commit. Catches an *honest* stale
   binding (ledger points pre-fix).
2. **Content** -- the fix's distinctive marker is **actually baked into** the
   artefact (grep inside the pulled image / vendored tree / daemon tag). Catches
   a *false* binding (ledger records a post-fix SHA, image built from older
   source) -- **the class a merge-base check can never see.**
3. **Binding** -- (wiki images) if the image carries a *CM044* revision label it
   must equal the ledger SHA. No such label today -> loud WARN naming the
   recordability gap (see "Build-stamp fix" below). The content proof still
   stands, so absence alone is not a RED.

Fail-closed: unresolvable provenance (no ledger row, image unpullable, docker
down, unknown repo) is **always** RED.

## What actually happened on v1.0.10 (the finding)

The brief's premise -- *"the pinned wiki image was built from a pre-#146 SHA and
serves the OLD panel"* -- is **falsified for the pinned cut artefacts** by direct
image inspection:

- Pinned compiler `2f7b0b73` **contains** #146 (`settling_phase_states` x3),
  #145 (`PWG_GATEWAY_URL`), #144 (`clean_body`).
- Pinned site `563fbcec` **contains** #146 CSS (`.pwg-settling-phases`,
  `.pwg-settling-effort`).
- Ledger row `2f7b0b73 -> 648f7491` is **correct**; `648f7491` contains
  `f936095` (GitHub compare: behind_by 0).
- The pre-#146 build `a7e8c7e8` (from `77300f6`, the *parent* of #146) contains
  **none** of those markers -- confirming each marker discriminates.

So if `curl :8044/` on the box shows the old panel, the staleness is on the
**running box** (a stale container / un-recompiled static content on the
gamingrig legacy deployment), **not** in the cut's pinned artefacts. That is a
deploy/redeploy gap -- a different bug class. **Recommendation for ORM:** confirm
the box's running wiki container digest equals the pinned `2f7b0b73` /
`563fbcec` and force a recompile; the pinned images are fresh.

The *systemic* hole is still real and worth the gate: the ledger binding is an
unverifiable hand-recorded claim, and no content marker was wired for
#144/#145/#146. This gate closes both.

## How ORM runs it in the cut pipeline

Wired into `gui/Makefile` as `check-provenance-content`, a dependency of the
`package` target, immediately after `check-freshness` + `check-provenance`:

```
package: check-tools check-identity check-create-dmg \
         check-freshness check-provenance check-provenance-content
```

- `check-freshness` proves nothing lags live HEAD (trusts the ledger SHA).
- `check-provenance` proves the hand-listed markers are present.
- `check-provenance-content` proves **every required fix is actually baked into
  the artefact**, driven from `required_fixes.tsv` -- no marker to forget.

Standalone: `scripts/provenance_gate.sh` (env in the script header). It needs
`docker` + the pinned images (present locally after a cut, or pulled).

**Per cut, ORM maintains `required_fixes.tsv`:** add one row per launch-blocking
fix with a marker verified *present-at-fix and absent-before-fix* on a real
artefact (the discipline `cut_markers.manifest` documents). `#TODO` rows for
not-yet-merged fixes (oa #226/#227, CM051 #435) are surfaced as reminders.

## Proof: RED on a stale wiki image (acceptance test)

The exact brief hole -- a **false ledger binding**: the ledger records the good
post-#146 SHA (so `verify_cut_freshness.sh` / any merge-base check goes GREEN),
but the image content is pre-#146. Demo pins the real pre-#146 image
(`a7e8c7e8`) against a ledger row claiming `648f7491`:

```
  FAIL  CM044 f936095 -> wiki-compiler (#146 settling-panel redesign -- per-phase renderer) ::
        image a7e8c7e8151e does NOT contain /settling_phase_states/ under /app/compiler --
        STALE IMAGE (ledger claims 648f7491ea2f but f936095 content is absent)
          the digest was NOT built from source containing f936095; rebuild the
          wiki-compiler image from current CM044 main + re-pin + fix the ledger row

=== Verdict ===
  0 pass / 1 fail / 0 warn
  CONTENT-PROVENANCE RED -- 1 artifact(s) miss a required fix, or cannot be verified.
```

Exit 1. Ancestry passed (ledger SHA is legitimate) -- only the **content** check
caught it. That is the failure mode `verify_cut_freshness.sh` cannot see.

## Result: GREEN on the current v1.0.10 cut (honest)

Against the real pinned digests the gate is GREEN on content (the images genuinely
carry #144/#145/#146), with advisory WARNs flagging the unrecordable binding:

```
  PASS  CM044 f936095 -> wiki-compiler :: f936095 content baked into 2f7b0b7332f8; ledger 648f7491ea2f contains f936095
  PASS  CM044 f936095 -> wiki-site     :: f936095 content baked into 563fbcecc46c; ledger 648f7491ea2f contains f936095
  PASS  CM044 3baa916 -> wiki-compiler :: 3baa916 content baked into 2f7b0b7332f8
  PASS  CM044 9061847 -> wiki-compiler :: 9061847 content baked into 2f7b0b7332f8
  WARN  ... image carries NO CM044 revision label -- ledger SHA is an unverifiable hand-recorded claim
  4 pass / 0 fail / 4 warn -- CONTENT-PROVENANCE GREEN
```

## Build-stamp fix (makes the binding enforceable next cut) -- Deliverable 3

Today the binding is a WARN because the image has no CM044 revision label. **Do
NOT reuse the generic `org.opencontainers.image.revision` label** -- a derived
image inherits it from its base (the site image carries mkdocs-material's
`b3e6dd88...`, nothing to do with CM044). Stamp a **dedicated** label at build
time. In CM044 `.github/workflows/release-images.yml`, add to the
`docker/build-push-action@v5` `with:` block (the 2-line change):

```yaml
        labels: |
          ai.ostler.wiki.source_revision=${{ github.sha }}
```

`github.sha` is the CM044 commit the release tag points at. The gate already
reads `ai.ostler.wiki.source_revision` first; once every image carries it, the
binding WARN becomes an enforceable RED-on-mismatch -- a re-pin that records a
SHA disagreeing with the baked-in one fails the cut.

The ORM must still add the matching row to `wiki_image_provenance.tsv` at re-pin
(unchanged), and the gate cross-checks the two.

> Namespace caveat (not fixed here): the workflow pushes to
> `ghcr.io/creativemachines-ai/...` but `install.sh` pins `ghcr.io/ostler-ai/...`.
> The stamp lands regardless of namespace; flagged for ORM awareness.
