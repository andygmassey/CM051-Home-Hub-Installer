# cm059_editor — divergence not captured by the existing patch (#2603 follow-up)

Deadline review, Archie, 2026-10-02: `scripts/regenerate_divergence_patch.sh
cm059_editor --write` was not attempted under the 35-minute deadline, and no
local checkout of `andygmassey/CM059-Ostler-Editor` was available in this
session to materialise against. This file is the sanctioned fallback the
gate itself names.

## What changed

`vendor/cm059_editor/compiler/_vendor/ostler_usage_journal/usage_journal.py`:
`record_usage()` gained a `calls: int = 1` keyword parameter, mirroring the
identical change made to `cm024_knowledge`'s copy for shape parity (the
established convention for this shared module across the three vendored
copies -- see `rolling.py`'s own docstring). `scout_newsletters.py` itself
is UNCHANGED and still calls `record_usage` without this keyword (default
1), since it is low-frequency and not rolled up.

This edit is behaviourally inert in this tree today: nothing here
constructs a `RollingUsageRecorder` with calls > 1 yet. It keeps the three
vendored copies of this module byte-identical in shape, the same reason
`RollingUsageRecorder` itself was carried here for parity before anything
used it.

## Method

- vendored file: `vendor/cm059_editor/compiler/_vendor/ostler_usage_journal/usage_journal.py`
- verified: `python3 -c "import ast; ast.parse(...)"` and the full existing
  test suite for this tree pass unchanged (no caller exercises the new
  parameter)

## Follow-up

Forward-port to `andygmassey/CM059-Ostler-Editor`'s own `usage_journal.py`
and regenerate this tree's real divergence patch once a source checkout is
available in-session. Not done here under the deadline; tracked, not
silently dropped.
