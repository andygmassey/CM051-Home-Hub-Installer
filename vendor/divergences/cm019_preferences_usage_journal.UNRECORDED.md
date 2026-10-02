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
