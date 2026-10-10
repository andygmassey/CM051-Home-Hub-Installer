# cm019_preferences — divergence NOT captured by a patch (CM051 #2472)

`cm019_preferences` ships with `divergence_patch = ""`, which this tree's own
manifest note already documents as a POSITIVE ASSERTION of byte-identity to
source at the pin — an assertion that row's own history has already found to
be false once (the 42-file reconciliation gap). This file does not reopen
that finding; it records a SEPARATE, NEW hand-edit on top of it, so the gate
that watches for undescribed vendor changes has something to find.

## What changed, and why it has no patch

`vendor/cm019_preferences/services/ingest/src/vectorizer.py` gained a usage-
journal write in `embed_batch()`, plus a vendored copy of the shared
`ostler_usage_journal` writer at
`vendor/cm019_preferences/services/ingest/src/_vendor/`.

Source `andygmassey/personal-world-graph` has no Ollama call in its own
vectorizer at all — it embeds via `sentence-transformers`, the swap this
file's own docstring already documents. So there is no upstream commit this
fix could ever be a divergence FROM: the usage-journal wiring can only exist
here, vendor-side, permanently. Unlike `cm024_knowledge` and `cm059_editor`
(whose equivalent fixes landed upstream and were re-vendored, superseding
their first-commit vendor-side drafts), this tree's fix is terminal, not a
placeholder for a future re-pin.

A `sync_vendor.sh --regen-patch` run against this tree would not describe
this change either: the row's `divergence_patch` is deliberately empty, and
turning it on now would also turn on patch maintenance for the pre-existing,
much larger, already-declared 81-file reconciliation gap this row's note
describes — out of scope for this change and not this PR's decision to make.

## Method

- vendored file: `vendor/cm019_preferences/services/ingest/src/vectorizer.py`
- new vendor-only files:
  `vendor/cm019_preferences/services/ingest/src/_vendor/__init__.py`,
  `vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/__init__.py`,
  `vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/usage_journal.py`
  (verbatim copy of `vendor/cm048_pipeline/src/_vendor/ostler_usage_journal/`)
- proven by execution, not by this record: `tests/test_cm019_vectorizer_usage_journal.sh`
  and the embedder arm of `tests/test_usage_journal_producer_parity_2472.sh`

## 2026-10-02: moved from per-call writes to a 60-second rollup

A live walk (v1.0.107 candidate) measured `cm019_preferences`'s vectorizer
writing 1,099 journal rows from a single ingest run under the per-call shape
this file originally described -- a meaningful share of total journal
volume, with no rotation on the journal and no cache on the Bursar's
monthly-summary reader. `vectorizer.py` now holds a `RollingUsageRecorder`
(new sibling file,
`vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/rolling.py`,
kept separate from `usage_journal.py` because that file carries a "DO NOT
EDIT" banner pinning it byte-identical to its canonical HR015 source) that
sums real measured tokens across a 60-second window per (model, purpose) and
writes ONE rolled-up row on flush, matching the same fix already applied to
`cm024_knowledge`'s embedder for the identical reason.

`__init__.py` under that `_vendor/ostler_usage_journal/` directory changed
too, to export `RollingUsageRecorder` from the new `rolling.py` alongside
the existing re-exports from the pinned `usage_journal.py`.

Proven by execution: `tests/test_cm019_vectorizer_usage_journal.sh` (updated
for the rollup shape: a write is not visible until `flush()`) and the
`cm019_vectorizer` arm of `tests/test_usage_journal_producer_parity_2472.sh`
(N=3 calls fold into exactly 1 row, whose `input_tokens` is the exact SUM of
all three calls' measured tokens -- proving no call's tokens were dropped by
the rollup). Both confirmed RED against the pre-fix per-call code before
this change.

## 2026-10-02, same day: estimate on miss, never drop a call

Andy's product rule, same review: "I'd rather Bursar overcounted, than
undercounted." `RollingUsageRecorder.add()` gained an optional
`estimated_input_tokens` kwarg: when Ollama reports no `prompt_eval_count` at
all, `vectorizer.py` now computes a chars/4 estimate of the text it actually
submitted and folds that in instead of dropping the call. The flushed row's
`session_id` gets an "-est" suffix so it stays distinguishable from a purely
measured row, short of a dedicated wire-format field (none exists yet; filed
as a follow-up, not done here).

This is scoped to `cm019_preferences`'s vectorizer ONLY, the one producer
this walk-defect review actually touched. The other four #2472 producers
(`cm024k_embedder`, `cm024k_classifier`, `cm024k_email_summarizer`,
`cm059_scout_newsletters`) are UNCHANGED and still write nothing on a miss --
whether to roll this rule out estate-wide, and whether to add a real
"estimated" field to the Rust `TokenUsage` schema so the UI can show it
honestly, are decisions for Archie/Andy, not assumed here.

Proven by execution, same two files: both now also assert that an
unmeasured call writes one ESTIMATED row (not zero), with the `-est` suffix
and the correct chars/4 value.

## Second, unrelated hand-edit: the Netflix thumbs-value polarity bug (walk #6, candidate #10)

Tree `cm019_preferences`, file
`vendor/cm019_preferences/services/ingest/src/parsers/netflix.py`,
`_parse_ratings()`. UNRELATED to the vectorizer change above (different
file, different root cause); recorded in this same journal because the
manifest points one `unrecorded_divergence` pointer at this tree and that
pointer is this file.

A customer console walk (macmini16-walk) found shows rated positively
listed under "Dislikes" on the wiki. Root cause: this parser's docstring
documented the WRONG Netflix GDPR "Thumbs Value" encoding (0=down,
1=up, 2=strong-down, 3=strong-up) and the code matched it exactly. The
real encoding is 0=not rated, 1=down, 2=up, 3=strong up -- there is no
"strong down" tier. Values 1 and 2 were swapped, and 0 ("not rated") was
being stored as an explicit Dislike.

Matches CM019 PR #396 (upstream, open at time of writing), applied here
via `git apply` of that PR's own diff against this vendor copy's
byte-identical `_parse_ratings()` (confirmed identical before this fix --
the only pre-existing divergence in this file is the
`NETFLIX_UNIQUE_PATTERNS`/`NETFLIX_EXACT_LEAF_NAMES` file-detection fix
for a Foursquare filename collision, landed earlier, which this patch
does not touch). CM019's test suite
(`services/ingest/tests/test_netflix_parser.py`) is NOT vendored (tests/
is outside this tree's shipping subset per this manifest row's own
note), so there is no vendor-side test to point at here -- proof is
upstream, at CM019 PR #396.

Also ships, as a SEPARATE file not vendored FROM anywhere (CM019's own
`scripts/` directory is likewise outside the shipping subset, so this is
a CM051-native script, not a graft): `scripts/repair_netflix_rating_polarity.py`
plus `tests/test_repair_netflix_rating_polarity.py`. One-time, idempotent
repair for Netflix preference points already written by the buggy parser
on an upgraded box. Dry-run by default, `--apply` to mutate. Measured on
macmini16-walk's own `preferences` collection (a test/walk box): 95 of
5,000 Netflix points carried a wrong label; repaired, then re-run twice
more with zero candidates found both times (idempotent, proven by
execution, not asserted). NOT wired into install.sh as an automatic
upgrade step in this PR -- that decision (same shape as `repair_lid_as_
phone`'s install.sh wiring) is flagged for Archie/Andy, not assumed here.
Retire the parser-fix portion by landing CM019 PR #396 and re-pinning;
the repair script has no upstream to retire against since it is native
to this repo.

## cm019_preferences: an enrichment miss is not an import error (walk #16)

A second hand-edit on `cm019_preferences`, recorded here because this tree's
manifest block declares this file as its `unrecorded_divergence` record.

**Measured refusal:** `scripts/regenerate_divergence_patch.sh cm019_preferences --write`
prints `CANNOT RUN -- cm019_preferences declares no divergence_patch path in the
manifest` (2026-10-10). Turning a patch on would also take on the pre-existing
reconciliation gap described above, which is not this change's decision.

**Location and shape of every edit in cm019_preferences:**

- `vendor/cm019_preferences/services/enrich/src/enricher.py`
  - `import re` added.
  - `EnrichmentStats`: new fields `no_match: int` and `misses: List[str]`;
    `attempted()` now adds `no_match`; `summary()` prints `No match: N`.
  - New module-level `_MISS_MESSAGE` regex and `is_enrichment_miss(result)`:
    true only for `MatchType.NONE` AND a fixed "answered, no confident match"
    phrasing. Fail-closed; `MatchType.UNAVAILABLE` is never a miss.
  - `enrich_batch()`: a new `elif` before the failure branch counts a miss in
    `no_match`/`misses` and logs it at INFO instead of `failed`/`errors`.
  - `enrich_categories()`: merges `no_match` and `misses` like the others.
- `vendor/cm019_preferences/services/enrich/src/cli.py`
  - `_run_enrichment()`: prints misses under
    `--- No enrichment match (N, not errors) ---` before the errors block; the
    exit rule (`failed > successful`) is unchanged and now excludes misses.

**Why:** three Wikidata look-ups that found nothing made the enrich CLI exit 1,
which `ostler-import` carried into install.sh's warn branch, so import_data went
red over a fully successful import. Tests:
`tests/test_an_enrichment_miss_is_not_an_import_error.py` and
`tests/test_ostler_import_exit_code_separates_misses_from_failures.sh`.
Also recorded in `vendor/divergences/CM019_DIVERGENCE_REGISTRY.md`.

**Upstream status:** not ported; owed to personal-world-graph `services/enrich`.
