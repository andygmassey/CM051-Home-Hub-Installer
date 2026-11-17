# ostler_fda photo event URI key (CM051 #3520), UNRECORDED in the divergence patch

`vendor/ostler_fda/pwg_ingest.py`, `ingest_photo_events`: the URI key prefers the
event's `uri_key` field, and falls back to the legacy formula when it is absent.

Why it is here and not in `ostler_fda.patch`: the divergence patch does not
reconstruct the vendored tree at the pin (`a15d82f`). Measured: applying the
pwg_ingest section of the recorded patch to the pinned source leaves 11 of 38
hunks unapplied. So the patch cannot record a new hunk and be verified. The
change is recorded here instead, the way the other undocumented grafts are.

Source of the key: `ostler_fda/photos_metadata.py`, `uri_key_for`, HR015 PR #1486.
The URI must never change for an existing event: a sentinel photo's key is
`-180.0,-180.0`, which is what the graph already holds. See the test
`tests/test_photo_uri_stability.py`.

Debt: regenerate the divergence patch from a clean pin and include this hunk. Filed
in the walkdriver backlog.
