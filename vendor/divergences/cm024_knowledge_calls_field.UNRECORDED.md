# cm024_knowledge — divergence not captured by the existing patch (#2603 follow-up)

Deadline review, Archie, 2026-10-02: `scripts/regenerate_divergence_patch.sh
cm024_knowledge --write` was attempted and REFUSED -- measured, not assumed
("could not verify cm024_knowledge: source repo not available") -- because
no local checkout of `andygmassey/evernote-knowledge` was available in this
session to materialise against. This file is the sanctioned fallback the
gate itself names.

## What changed

`vendor/cm024_knowledge/ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py`:
`record_usage()` gained a `calls: int = 1` keyword parameter, written into
the record as `"calls": max(1, int(calls))`. `RollingUsageRecorder._flush_locked()`
now passes `calls=self._calls` so a rolled-up row declares its real call
count instead of the implicit 1 a reader gets when the field is absent --
the exact undercount this change exists to close (a rollup row kept every
measured token but silently dropped every call past the first from the
Bursar's displayed total).

Default `calls=1` leaves every other call site (classifier.py,
email_summarizer.py, and anything else calling `record_usage` without this
new keyword) unchanged in behaviour.

## Method

- vendored file: `vendor/cm024_knowledge/ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py`
- proven by execution: `tests/test_usage_journal_producer_parity_2472.sh`,
  `cm024k_embedder` arm, asserts the rolled-up row's `usage.calls` equals the
  real N (3), not the implicit 1
- companion: `ostler-ai/ostler-assistant#451` adds the Rust-side `calls`
  field and an end-to-end test against a real journal line

## Follow-up

Forward-port to `andygmassey/evernote-knowledge`'s own `usage_journal.py`
and regenerate this tree's real divergence patch once a source checkout is
available in-session. Not done here under the 35-minute deadline; tracked,
not silently dropped.
