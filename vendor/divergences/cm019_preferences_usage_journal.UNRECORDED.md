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
