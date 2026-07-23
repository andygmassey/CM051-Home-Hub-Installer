# #657 Social-archive GDPR ingest — verification + hardening report

**Author:** TNM · **Date:** 2026-06-08 · **Against:** CM051 `origin/main` (clean, 0 ahead/0 behind at recon) · **Branch:** `verify/social-archive-ingest-657` (NOT pushed)

Status convention: **TRUE** = brief/scope claim verified on origin/main; **DRIFTED** = claim was stale, corrected here; **GAP** = genuine unproven/missing thing; **BLOCKED** = needs a clean-wipe box I do not control; **DECISION** = needs Andy, not self-decided.

## Headline status (literal, not rounded)

- Wired: **TRUE** (both pipelines, fanned out by `~/.ostler/bin/ostler-import`).
- Parse-proven on real archives: **TRUE** (per scope doc; not re-run here -- no real archive data touched, Rule 0).
- Write-path-on-a-clean-box (people + preferences land as rows): **✗ STILL UNPROVEN.** Not done. Blocked on a clean-wipe install (Studio post-wipe or a fresh Mac). Local proof not possible on this box: Qdrant/Oxigraph/Ollama are all down here and Ollama is not even installed, so a real `/api/embed` run cannot be exercised. Recipe to close it is in this doc.

## Per-item verdicts

### 1. Clean-box end-to-end -- BLOCKED (needs the wipe)
The whole point is a *fresh-install* Qdrant/Oxigraph, so running it on my polluted dev box proves little even if I stood the services up. Recipe below; this stays ✗ until run on the real box.

### 2. Embed-health gate before readback -- DRIFTED (already exists) + one residual GAP
The brief says "a 0-row import currently risks reporting success; add a hard embed gate." **That gate already exists and hard-fails.** `install.sh` L6959-6972 POSTs `{"model":"nomic-embed-text","input":"healthcheck"}` to `/api/embed`, asserts HTTP 200 AND a non-empty `embeddings[0][0]` numeric, and calls `fail_with_code "ERR-13-EMBED-HEALTHCHECK"` otherwise. It runs at L6959, *before* the §3.12b import at L7670. The comment (L6955-58) says it was added for the exact "hydrate reported ok while landing 0 points" incident. So the embed-dead silent-success class is **closed**.
- **Residual GAP:** the gate proves the embedder is alive; it does NOT assert the target Qdrant collections exist before the readback claims success. The CM019 CLI self-creates `preferences` (scope doc: `ensure_collection(dim=768)`), but the `people` collection's creation on a fresh box is unverified, and `feedback_qdrant_collections_no_self_create_fresh_install` says self-create is not guaranteed. Covered by the item-6 readback hardening (people-count readback will surface a missing/empty `people` collection honestly).

### 3. identity_resolver vendor-integrity -- partial TRUE + GAP now CLOSED here
- TRUE: `contact_syncer` does import it (`dedup.py`, `facebook_friends.py`: `from identity_resolver.{models,resolver,normalise} import ...`); install.sh stages it as a sibling in `PIPELINE_DIR` (L7016 contact_syncer, L7025 identity_resolver); the DMG Makefile lists it in the required-Resources loop (L735).
- GAP: the existing static guard `tests/test_vendor_import_resolution.py` **explicitly excludes** cross-package sys.path imports (its docstring "Known limitation"), which is exactly the `contact_syncer -> identity_resolver` shape. So nothing tested that the cross-package import actually resolves on the staged layout. If a re-vendor moved/dropped identity_resolver, contact_syncer would `ImportError` only at customer runtime and the GDPR people path would go dark with no parse error.
- **CLOSED here:** new `tests/test_contact_syncer_identity_resolver_vendor_integrity.py` mirrors the install staging, AST-extracts the real `identity_resolver.*` imports from contact_syncer, and asserts each resolves on the staged PIPELINE_DIR layout (filesystem resolution -- no `__init__` execution, so no third-party dep needed). GREEN + RED control (drops identity_resolver, asserts the imports then fail). Passes.
  - **Staging caveat to flag (not yet a confirmed bug):** install.sh L7025 stages from `${SCRIPT_DIR}/identity_resolver`, but in the repo the source lives at `vendor/cm041/identity_resolver`. On the **DMG** path this is fine -- the Makefile copies it to the `.app` Resources *root*, so `${SCRIPT_DIR}/identity_resolver` exists at runtime. On a **source/tarball** install where `SCRIPT_DIR` is the repo/tarball root, `${SCRIPT_DIR}/identity_resolver` does NOT exist (it's under `vendor/cm041/`), so identity_resolver would not be staged and the people path would go dark. Needs confirming against what the HR015 curl|bash tarball actually lays out before calling it a bug; DMG (the ship vehicle) is safe.

### 4. Preference-noise tuning -- DECISION MADE (Andy + Archie, 2026-06-08)
**Drop reaction-owners + priority-cap 5,000 prefs/source, log what's capped.** Keep `category in {page, facebook_content, instagram_creator, movies, books, music, follows, saved}`; drop bare reaction-owner names (`category == social`).
Archie refinement (incorporated): after dropping reaction-owners FB has only ~7k real prefs left, so an arbitrary 5k cap would trim ~2k of legitimate signal. So **cap by category priority**, not arbitrarily -- keep the high-signal categories first (pages, follows, interests/page) and let the cap trim the lowest-value tail (saved/media) only if the ceiling is hit. Make 5,000 a **named constant** (one-line tunable) and **log every row capped** (no silent truncation -- per `feedback`/`no-silent-caps`).
- **Implementation plan (insertion points identified, NOT yet built):**
  - Reaction-owner drop: extend `vendor/cm019_preferences/services/ingest/src/filters.py` `PreferenceFilter` (a category-exclusion alongside the existing `is_low_value` / `should_include`; the meta parser sets `category == "social"` for reaction owners).
  - Priority-cap: stateful per-source ceiling in `pipeline.py` (it already tracks per-ingest stats); sort retained prefs by a category-priority order, keep up to `MAX_PREFS_PER_SOURCE = 5000`, log the dropped tail count per category.
  - Synthetic fixture test (no real data): a meta-shaped export with > 5k mixed-category rows; assert reaction-owners dropped, high-priority categories retained, tail trimmed, cap logged.

### 5. Schema shape -- DECISION MADE (Andy + Archie, 2026-06-08)
**Connections + friends -> people ONLY.** LinkedIn connections + FB friends -> `pwg:Person` (via contact_syncer, already wired). Everything else -> `pwg:LikePreference`. Do NOT promote FB reaction-owner / IG-creator name-strings into `pwg:Person`. No "preference-subject -> Person" resolver will be written. Confirmed -- the existing wiring already matches this, so no schema work needed.
- **Archie follow-up note (recorded, NOT for launch):** the real LinkedIn export also ships `ImportedContacts.csv`, `Email Addresses.csv`, `PhoneNumbers.csv` alongside `Connections.csv` -- these are *also* legitimately people-bearing and are currently treated as preferences-only. Flag as a **candidate people-source follow-up** (post-v1.0.1) so they are not silently preferences-only forever. NOT in scope for the confirmed shape above.

### 6. Auto-detect -> importer reachability + honest reporting -- partial TRUE + GAP (designed, not yet built)
- TRUE: §9 detect seeds `EXPORTS_DIR`; §3.12b runs `ostler-import` over it + the prefs drop-zone; the `MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE` stub is the `elif` fallback (L7729), only firing when `_IMPORT_DIRS` is empty or the importer is non-executable -- NOT the happy path. Confirmed.
- GAP (honest reporting): the §3.12b readback is NOT honest on a 0-row land:
  - The importer (`ostler-import` heredoc, L7587-7665) returns `rc=0` even when BOTH consumers are skipped because their venvs are absent (the `if [[ -d $PIPELINE_DIR/contact_syncer && -x .venv/bin/python3 ]]` and `if [[ -x $CM019_PY ]]` guards both go false -> loop body no-ops -> `rc=0`). So "GDPR import complete" can print with zero work done.
  - The preferences readback (L7715-7727) prints the done-line only when points `> 0`; a 0-row land prints **nothing** -- no success, no failure. Silent.
  - There is **no people-count readback at all** -- the people path's success is invisible to the installer.
  - **Designed fix (NOT yet built -- see "next step"):** before claiming success, (a) assert each consumer's venv/dir actually exists and report "skipped: pipeline not ready" honestly when not; (b) read back both the Qdrant `preferences` AND `people` collection counts (existence + points), reporting 0 as an explicit "imported 0 -- check X" rather than silence. Left as the next commit so the readback change is reviewed on its own, not rushed into this verification pass next to a frozen cut.

## Clean-box test recipe (run on the wiped Studio / a fresh Mac)
1. Place a real LinkedIn `Connections.csv` and a Facebook `your_friends.json` in `~/Downloads/` (or a single export root) BEFORE running the installer.
2. Run the DMG install to completion. Do nothing manual.
3. Assert on the box (counts only, no content):
   - `curl -s localhost:6333/collections/people | jq .result.points_count` rises by ~ (LinkedIn connections + FB friends).
   - `curl -s localhost:6333/collections/preferences | jq .result.points_count` > 0.
   - Oxigraph `pwg:Person` count rises: `curl -s 'localhost:7878/query?query=SELECT (COUNT(*) AS ?c) WHERE { ?p a <...Person> }' -H 'Accept: application/sparql-results+json'`.
   - Wiki People surface + Hub People card show the new people; wiki preferences surface shows interests.
4. If any count is 0 despite a clean parse: chase the write/embed path (the embed gate should already have hard-failed if embed was dead -- so a 0 with a green embed gate points at collection creation or the loader upsert).

## What was delivered on this branch (no push)
- `tests/test_contact_syncer_identity_resolver_vendor_integrity.py` -- item 3 gap closed (GREEN + RED control, passes).
- This report.

## Next concrete steps (in priority order)
1. **Andy decisions 4 + 5** (preference ceiling + schema shape) -- gating, surfaced above.
2. **Item 6 honest-readback hardening** -- people+prefs count readback + skipped-pipeline honesty in §3.12b (designed above; build as its own commit after the decisions).
3. **Item 1 clean-box e2e** -- run the recipe on the wiped box (the only thing that flips write-path-on-clean-box from ✗ to ✓).
4. Confirm the source/tarball identity_resolver staging caveat (item 3) against the HR015 curl|bash layout.

## Cleanup done
Scope-agent throwaways noted in the brief (`/tmp/gdpr_probe.py`, `/tmp/people_probe.py`, `/tmp/gdpr_scope_venv`) -- left untouched (not mine to assume; harmless).
