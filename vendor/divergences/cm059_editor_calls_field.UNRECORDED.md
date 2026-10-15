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

## Shape sweep: person_label and clean_card_text (2026-10-12), tree cm059_editor

`compiler/frontpage.py` gains `clean_card_text` and `person_label` (+
`UNKNOWN_CONTACT`); `display_subject` speaks a snake_case key as words;
`is_cardable_interest` refuses a bare number/address; `signals.py` routes
reply-debt, gone-quiet, birthday and commitment names through `person_label`
(gone-quiet and birthday are suppressed when there is no showable name);
`render_frontpage.py` footer date is human and three em dashes in fixed copy
are gone. Test: `tests/test_customer_leak_shapes.py`.

## Interest cards say where the interest came from (CM051, 2026-10-14)

Tree `cm059_editor`, file `vendor/cm059_editor/compiler/frontpage.py`.
`scripts/regenerate_divergence_patch.sh cm059_editor --write` with
`CM059=~/Developer/CM059-Ostler-Editor` REFUSED (exit 1): the source has
advanced past the pin (6cc9d83), so this is recorded here.

- NEW `_SOURCE_NAMES`, `_SOCIAL_SOURCES`, `_source_name`, `_join_names` and
  `interest_provenance(it, now)` above `interest_card`;
- `interest_card` body: `interest_provenance(it, now)` replaces the fixed
  "One of the things Ostler reckons you're into." (dislikes unchanged).

The sentence is built from the card's own `sources` and `last_seen` ("Followed
on X, last seen in 2019.", "From your Apple Music and Spotify listening.", "On
your LinkedIn profile.", "You told Ostler about this."). Pinned by
`tests/test_interest_card_says_what_and_where.py`. CM059 upstream needs the
same change, or the next re-pin reverts it.

## 2026-10-15 Ostler #30 console walk: the hunch card never offers a flagged interest; Neutral reaches the profile

Tree: `cm059_editor`. `scripts/regenerate_divergence_patch.sh` was not run: no local CM059 checkout is pinned to 85c87924 in this worktree; this file is the sanctioned fallback.

Edits under `vendor/cm059_editor/compiler/`:

- `frontpage.py`: new `_UNFIT_FOR_A_CARD_FLAGS` / `_fit_for_a_card`; `exploration_pick`, `_rotation_picks` and `_top_interests` skip an interest carrying too_long, too_short, empty, url_only, email_reply_prefix, email_thread or dated_subject.
- `project_preferences.py`: `_POLARITY` gains `neutral -> NeutralPreference`, so a Neutral play row is projected instead of skipped.
- `interest_profile.py`: `fetch_preferences` also reads `NeutralPreference` (polarity "neutral", ranked with likes, never as a dislike).

Proof: `tests/test_hunch_card_never_shows_a_flagged_interest.py` (fails on origin/main), `tests/test_passive_plays_are_not_likes.py::test_neutral_survives_into_the_graph_and_the_profile`.

## 2026-10-15 walk #29: the projection stops duplicating pipeline preferences, plus a one-time cleanup

Tree: `cm059_editor`. File: `vendor/cm059_editor/compiler/project_preferences.py`. That file is VENDOR-ONLY (CM059 upstream has no `project_preferences.py`), so `verify_vendor_fresh.sh` does not compare it and `cm059_editor.patch` cannot carry it. It is recorded here, as the earlier Neutral change to the same file was. Measured with CM059 cloned and exported: `verify_vendor_fresh.sh cm059_editor` reports the same single pre-existing `frontpage.py` drift on origin/main and on this branch. Nothing new.

Why: CM019's ingest pipeline writes every preference as `pwg:pref_<preference_id>` (`vendor/cm019_preferences/.../parsers/base.py` `to_turtle`, `pipeline.py` `insert_triples`). The projection then copied every Qdrant point again as `urn:ostler:preference:<sha256(id)[:32]>`. On the walk #29 box Oxigraph held 138,999 music preference subjects against 70,667 Qdrant music points.

Edits:

- `project()` skips a point whose `pwg:pref_<preference_id>` node exists (`pipeline_preference_ids`). Only Qdrant-only rows are still projected: CM041 `places_ingest`, and the ostler_fda iMessage and bookmark rows.
- NEW `dedupe_projected_twins()` is the one-time cleanup.
  - It removes a node only when all three hold: the node carries the projector's marker, its IRI is the SHA256 twin of an existing `pwg:pref_` id, and the backup holds it.
  - Before deleting, it writes the triples it will remove as N-Triples to `~/.ostler/backups/preference-projection/projected-twins-<utc>.nt` (override: `OSTLER_PREFERENCE_PROJECTION_BACKUP_DIR`) and reads the file back. If any subject is missing from the backup, nothing is deleted.
  - `__main__` runs it before `project()`, so `bin/editor-frontpage-tick.sh` Step 0 runs it unchanged.
- `_count_marked` now raises on a refused query. Before, any failure returned 0, which disarmed the ratio guard.

Other `urn:ostler:preference:` readers, checked by grep in CM044, CM051 and CM059: the CM019 enrich service (`services/enrich/src/enricher.py`, `cli.py`) and CM044 `compiler/enrichment_reader.py` use `<urn:ostler:preference:{raw preference_id}>`. That is a different node, carries no projection marker, and is never matched by the cleanup (tested).

Proof: `tests/test_preference_projection_does_not_duplicate_the_pipeline.py`, wired in `.github/workflows/misclassified-things.yml`. On origin/main: 5 failed. Here: 5 passed. CM059 upstream has no copy of this module, so nothing needs forward-porting.
## Reply debt that could not be checked says so (CM051 #30, studio29), tree cm059_editor

Tree `cm059_editor`, file `vendor/cm059_editor/compiler/signals.py`.

- NEW strings `reply_debt_unchecked_title` / `reply_debt_unchecked_body`;
- NEW `reply_debt_degraded(raw)` and `reply_debt_unchecked_card(now, ledger)`
  (signal type `reply_debt` with `unchecked: true`, L2, names nobody, no
  action, a quarter of the reply-debt band);
- `build_signal_cards` emits the "Couldn't check who is waiting on you" card
  when the reply-debt payload is `degraded: true`, instead of no card, which
  read exactly like nobody waiting. The Hub's Front Page renders the same
  feed, so it shows the same card.
- review follow-up: NEW strings `reply_debt_not_connected_title` /
  `_body`, `reply_debt_not_connected(raw)`; `reply_debt_unchecked_card` gains
  `not_connected=` and, for reason `imessage_not_connected`, renders "Messages
  isn't connected" with no retry promise (signal `not_connected: true`).

Guarded by `tests/test_reply_debt_never_opens_protected_data.py`. CM059
upstream needs the same change, or a re-sync reverts it.
