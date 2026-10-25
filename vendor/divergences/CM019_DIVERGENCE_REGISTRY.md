# `vendor/cm019_preferences` -- what in here is OURS

**Why this file exists.** Every other vendored tree records its divergence
from upstream as a `divergence_patch` that
`scripts/verify_vendor_fresh.sh` re-applies and checks. This one cannot:

    name             = "cm019_preferences"
    pinned_sha       = "282ebfeba2b7751d48966e89e2b856c31218c524"
    divergence_patch = ""
    verify           = "skip"
    unverifiable_ack = true

`verify = "skip"` plus an empty patch means **nothing in this repo can tell a
CM051-authored fix from upstream code**. That is not hypothetical: the tree's
own manifest note records that CM051 #431's regression once shipped labelled
"byte-identical to upstream" when it was not.

This registry is the artefact the eventual reconciliation reads, so that
CM051-authored fixes get MERGED rather than reverted.

## The measured state

Taken 2026-08-17 by materialising `CM019@282ebfeb` and diffing every shared
`.py` file against `origin/main`'s vendored copy.

**77 shared `.py` files examined. 16 differ.** The denominator is stated
because "16 files diverge" and "16 of 16 files diverge" are very different
facts and the number alone does not say which.

| file | delta lines | attributed |
|---|---:|---|
| `services/enrich/src/clients/base.py` | 22 | CM051 #805 |
| `services/enrich/src/clients/openlibrary.py` | 14 | CM051 #805 |
| `services/enrich/src/models/enrichment.py` | 5 | CM051 #805 |
| `services/ingest/src/parsers/youtube.py` | 156 | CM051 #808 + UNATTRIBUTED |
| `services/enrich/src/config.py` | 4 | UNATTRIBUTED |
| `services/ingest/src/config.py` | 50 | UNATTRIBUTED |
| `services/ingest/src/filters.py` | 182 | UNATTRIBUTED |
| `services/ingest/src/loaders/qdrant_loader.py` | 148 | UNATTRIBUTED |
| `services/ingest/src/parsers/__init__.py` | 8 | UNATTRIBUTED |
| `services/ingest/src/parsers/apple.py` | 2 | UNATTRIBUTED |
| `services/ingest/src/parsers/base.py` | 92 | UNATTRIBUTED |
| `services/ingest/src/parsers/csv_parser.py` | 22 | UNATTRIBUTED |
| `services/ingest/src/parsers/meta.py` | 48 | UNATTRIBUTED |
| `services/ingest/src/parsers/whatsapp.py` | 2 | UNATTRIBUTED |
| `services/ingest/src/pipeline.py` | 63 | UNATTRIBUTED |
| `services/ingest/src/vectorizer.py` | 151 | UNATTRIBUTED |

`UNATTRIBUTED` is an honest state, not a placeholder. It means the delta is
real and measured and nobody has yet established whether it is a CM051 fix, a
PII scrub, or upstream drift the pin has not caught up with. The manifest note
names operator-PII scrubs in `enricher.py`, `ingest/cli.py`, `netflix.py`,
`disney.py` and `enrich/cli.py`; none of those five appear above, so they are
either already native at this pin or in files this sweep did not reach.

## The known-deliberate entries

### CM051 #805 -- an unreachable source is not a negative result

`base.py` records a transport verdict (`_last_transport_failure`),
`enrichment.py` adds `MatchType.UNAVAILABLE` distinct from `NONE`, and
`openlibrary.py` reports "could not reach" rather than "book not found". A 404
deliberately does NOT set the transport verdict, because a 404 IS a genuine
absence.

**Upstream status:** not ported. Belongs upstream.

### CM051 #808 -- the YouTube parser claimed three Facebook files

`YouTubeParser.can_parse` claimed any `*.json` whose name contains
`comments`, which is true of all three Facebook activity exports, and
`YouTubeParser` is registered ahead of `MetaParser`, so Meta's own
(correct, pre-existing) shape check could never run. Adds
`_looks_like_youtube_json` and `_takeout_records`.

**Upstream status:** not ported. Belongs upstream, and the same defect is
live in CM019 today.

**Note:** `youtube.py` measures 156 delta lines, of which roughly 90 are
#808. The remainder predates it and is UNATTRIBUTED.

### CM051 #1974 -- the search filter asked for a type and an owner the store does not hold

`services/ingest/src/loaders/qdrant_loader.py`. Two independent read-side
mismatches, both in `QdrantLoader.search()`, both measured on a live customer
box on 2026-09-16 against the `preferences` collection (5733 points):

| probe | count | what it says |
|---|---:|---|
| `compartment_level` match `"L2"` | 4804 | the stored value is a STRING |
| `compartment_level` range `{gte: 0}` | 0 | the shipped reader's query |
| CONTROL `strength` range `{gte: 0}` | 5733 | the range operator works |
| `is_empty user_id` | 5733 | the owner tag is never written |
| CONTROL `is_empty category` | 0 | the probe discriminates |

So compartment-scoped search matched nothing at all, and every user-scoped
read returned an empty list. Both were silent: the query is valid, Qdrant
answers 200, and the caller sees a legitimate-looking empty result.

**The reader was changed, not the writer, on both counts.** The 4804 string
levels are on customers' disks already and a writer-only fix leaves them
unsearchable until a full re-ingest; and `user_id` cannot be back-filled with
an identity that the single-machine product does not have. `search()` now
accepts the numeric type AND the stored string vocabulary, and treats an
absent owner as this user's -- which is the call `services/enrich/src/enricher.py`
already makes, in this same tree, for this same reason, citing the
single-machine architectural directive. The same one-of clause is applied to
`count()` and `get_all_for_user()`.

**`delete_by_user()` was deliberately NOT changed**, and there is a test that
fails if a later tidy-up makes it "consistent" with the others. Widening a
delete to include untagged points would turn an owner-scoped erase into a
full-collection wipe -- all 5733 on the measured box.

Also recorded here because it is a real defect this change did NOT fix: the
`gte` in the compartment filter is preserved exactly as it was. Levels run L0
Personal to L6 Broadcast, so whether a "max compartment level" cap should be
`gte` or `lte` is a genuine open question, and answering it by accident while
fixing a type mismatch would have been a silent privacy change.

**Upstream status:** not ported. The user-id half is Ostler-specific (it
follows from the single-machine directive and from `ostler_fda/pwg_ingest.py`
being the real producer for this collection, which upstream does not have).
The compartment-type half is owed upstream, and upstream would more likely fix
its writer than its reader.

### CM051 #1583: the compartment filter could not express its own docstring

`services/ingest/src/loaders/qdrant_loader.py`,
`services/ingest/src/pipeline.py`, `services/ingest/src/api.py`.

The row above records, correctly, that `gte` was preserved on purpose and that
the direction question was left open. What it did not record is that the
method had no way to say the other thing. `QdrantLoader.search()` documented
`compartment_level` as a "max compartment level", `IngestPipeline.search_similar()`
documented it as "Maximum compartment level to include", and both sent a
`gte`, which selects the complement of a maximum. A caller who believed either
docstring got the opposite half of the store and nothing anywhere said so.

WHAT CHANGED. `search()` takes `compartment_direction`, defaulting to
`COMPARTMENT_AT_OR_ABOVE`, which emits byte-identical filter bodies to the
ones this file emitted before for every threshold in the 0..6 domain. The
docstrings now say what the code does. `COMPARTMENT_AT_OR_BELOW` is the other
direction. An unrecognised value raises rather than defaulting.

WHAT DID NOT CHANGE. The direction. No customer's privacy-scoped read returns
anything different because of this change, and the `at_or_below` arm is
reachable from Python only, never from `POST /search`, because choosing it is
the privacy decision this registry says is still open.

TWO SMALLER THINGS FIXED IN PASSING. The string arm is now DERIVED from the
numeric predicate instead of hand-written as `range(level, 7)`, which agreed
with `gte` by construction and would silently have disagreed with `lte`. And a
threshold outside the 0..6 domain no longer sends `match: {any: []}`, which
Qdrant rejects: a rejected request is logged and returns `[]`, which reads to
the customer exactly like owning nothing.

RECORDED, NOT FIXED. `parsers/base.py::_compartment_uri` maps an unrecognised
level to `L2Trusted`, so a level nobody can place is labelled in the middle of
the scale rather than at either end. Which end is fail-closed depends on the
direction question, so it is left alone here.

**Upstream status:** not ported. Owed upstream, and upstream has the same
ambiguity.

### Walk #16 -- an enrichment miss is not a failure (enricher.py, cli.py)

Walk #16: import_data went red over a fully successful import. Three Wikidata
look-ups found nothing ("No Wikidata entity for: ...", "Wikidata has no film or
programme named: ..."), `enrich_batch` counted each as `failed`, cli.py's
`failed > successful` exited 1, and ostler-import's `|| rc=$?` carried that into
install.sh's warn branch.

`is_enrichment_miss()` (enricher.py) classifies a result as a MISS only when it
carries `MatchType.NONE` AND an error text on a fixed list of "answered, no
confident match" phrasings. Fail-closed: `MatchType.NONE` is also the dataclass
default, so a caught exception (`result.error = str(e)`) would carry it too; an
unrecognised message stays a failure, and `MatchType.UNAVAILABLE` is never a
miss. Misses go to `EnrichmentStats.no_match` / `misses`, count toward
`attempted()` (they were dispatched), are merged across categories, are logged
at INFO, and print under "--- No enrichment match (N, not errors) ---". They
never set the exit code. Test: tests/test_an_enrichment_miss_is_not_an_import_error.py.

**Upstream status:** not ported. Owed upstream (personal-world-graph
services/enrich), same shape.

### Walk #28 -- public look-ups only on a recorded yes (cli.py)

Setup asks consent_enrichment (default no) and writes the answer to
`~/.ostler/config/.env` as `OSTLER_CONSENT_ENRICHMENT_DECISION`. The enrich CLI
had no consent reference at all, so any caller that forgot to check sent
preference subjects to Wikidata, MusicBrainz and Open Library regardless.
`require_public_lookup_consent()` (cli.py) now runs before `enrich` (not
`--dry-run`, which calls no external API) and before `parallel`. It reads the
FILE, never the inherited environment; "accepted" proceeds, "declined" exits 0
with a plain sentence, and a missing file, missing key or any other value exits
3 having sent nothing. `stats`, `normalize` and `test-connections` touch only
the local stores and are not gated. This is the backstop: install.sh's
ostler-import and enrich tick check the same value first. Test:
tests/test_enrichment_honours_a_decline.sh (arm C, socket-guarded).

**Upstream status:** not ported. Owed upstream (personal-world-graph
services/enrich), same shape: upstream has no consent gate either.

### v1.0.108 -- local-store clients ignore HTTP(S)_PROXY (enricher.py, hierarchy.py, cli.py)

`trust_env=False` on the 13 httpx clients that talk to the local Qdrant and
Oxigraph. UPSTREAM since 4e023299 (personal-world-graph #409); this tree is
pinned there, so this is no longer a divergence. Detail and proof:
`cm019_preferences_usage_journal.UNRECORDED.md`, "2026-10-17 v1.0.108".

### smart-prefs (build after v1.0.108) -- the derive engine is grafted; filters.py does NOT delegate to strength.py

The pin stays at 5622a763, which already carries the preference-derivation engine
("What you like"). Seventeen files arrive BYTE-IDENTICAL to upstream@5622a763
(cmp-verified; the same bytes as at 96ff272d): `services/enrich/src/derive/` (11 `.py`, `dimensions.yaml`,
`readers.yaml`, `contract/derived_preferences_response.example.json`),
`services/common/strength.py`, `ontology/shacl/derived-preference-shapes.ttl`
and `ontology/upper/pwg-derived.ttl`. Those are not divergences.

**The divergence this re-pin CREATES**, and it is deliberate: upstream aae370bc
also rewrote `services/ingest/src/filters.py` so `_calculate_strength` delegates
to `strength.calculate_strength` via a top-level `from strength import ...`.
That edit is NOT grafted. On the box nothing puts `services/common` on the
ingest path's `sys.path`, so the delegation would make
`services.ingest.src.filters` fail to import and take every preference ingest
with it. The vendored file keeps its inline copy of the same math, which
upstream's own golden test (`services/common/tests/test_strength_golden.py`)
asserts is byte-identical in output. So the two copies agree today and this
row is the record that they are two copies.

**Also not vendored, on purpose:** `services/enrich/scripts/store_derived_preferences.py`
(upstream's CLI). Its `--user-id` default is the operator's first name, which
cannot enter this public repository; the box gets its own runner instead.

**Upstream status:** nothing owed for the engine. For `filters.py`, retire by
grafting the delegation once the box's ingest entrypoint puts `services/common`
on `sys.path` (or upstream packages `strength` under `services/ingest`).

### smart-prefs -- the derive registry spans all of life (ahead of the pin; personal-world-graph #422)

`services/enrich/src/derive/{config,engine,model,query,readers}.py`,
`dimensions.yaml`, `readers.yaml` and `ontology/upper/pwg-derived.ttl` are AHEAD
of the pin: they carry upstream #422 (open). Not a divergence from intent: the
same diff, to be re-pinned when #422 merges. Detail:
`cm019_preferences_usage_journal.UNRECORDED.md`, "2026-10-22 smart-prefs".

### T0j -- smart-prefs at personal-world-graph 5af9f5b5 (the pin since T0j)

`services/enrich/src/derive/**`, `services/common/recency.py`, `services/enrich/src/hierarchy.py`,
`services/ingest/src/minors.py` and the two derive ontology files are byte-identical to
upstream@5af9f5b5 except comment-only paraphrases (public names) in `derive/engine.py`,
`derive/sensitive.py`, `derive/sensitive_terms.yaml`, `derive/patterns.py` and `ingest/src/minors.py`. `enricher.py`,
`cli.py` (QID pass) and `ingest/src/pipeline.py` (minors stamp) carry upstream hunks grafted
onto the existing CM051 divergence. Detail: `cm019_preferences_usage_journal.UNRECORDED.md`,
"2026-10-24 T0j", which also lists the upstream hunks past the old pin that are
NOT carried (food #432 -> CM051 #3124, representative-first CLI #431 -> CM051 #3120).

## How to add a row

When you change anything under `vendor/cm019_preferences`, add a row here in
the same PR. File, what, why, and whether it is owed upstream. A change that
is not recorded here is a change the reconciliation will silently revert.

## What would retire this file

Flipping `verify = "skip"` to `verify = "full"` with a real
`divergence_patch`, which the manifest ack says needs the CM019 owner and a
reconciliation of the full shared-file delta. Until then this registry is the
only record that exists.

## 2026-10-21: Facebook watched rows emit `facebook_watched` (personal-world-graph #419, 5d1cdf13)

Tree `cm019_preferences`. Pin HELD at 7fd66daf; 5d1cdf13 added to `hold_ack_shas` (grafted, pin held).

- `services/ingest/src/parsers/meta.py`: the single upstream hunk (the movie_tv Like rows from Facebook watched history use `source="facebook_watched"`), applied by exact replacement because the vendored file carries earlier CM051 grafts. Measured: the changed lines equal upstream's for this file. The upstream test file is not in the vendored set.
- Why not re-pin: main is 10 commits past the pin, nine of them the smart-prefs derive engine this row holds.
- Paired in the same CM051 change: the data_conservation `expected.json` movie_tv row moves from `facebook` to `facebook_watched`, and cm059_editor is re-pinned to 5f3e94ce (#36), which pins `facebook_watched` as observed and local-only.
- Retire: a re-pin past 5d1cdf13 once the smart-prefs hold is lifted.

## 2026-10-23: per-item privacy gate on online enrichment (personal-world-graph fix/enrich-privacy-gate)

Tree `cm019_preferences`. Pin HELD at 5622a763; grafted ahead of the upstream merge. `privacy_gate.py` byte-identical; `enricher.py` changed lines equal upstream's; `derive/readers.py` SCROLL_FIELDS not carried (the vendored derive tree predates it and drives no online lookup). Detail and proof in `cm019_preferences_usage_journal.UNRECORDED.md`, same date.
- Retire: re-pin past the upstream merge commit.

## 2026-10-23: an explicit L0 survives ingest (personal-world-graph fix/ingest-explicit-l0-survives)

Tree `cm019_preferences`. Pin HELD at 5622a763; grafted ahead of the upstream merge. Five `or`-default sites in ingest pipeline.py, parsers/email.py and parsers/apple.py now use an explicit None check; changed lines equal upstream's. Detail and proof in `cm019_preferences_usage_journal.UNRECORDED.md`, same date.
- Retire: re-pin past the upstream merge commit.
