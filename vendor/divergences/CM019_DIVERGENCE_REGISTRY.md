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

## How to add a row

When you change anything under `vendor/cm019_preferences`, add a row here in
the same PR. File, what, why, and whether it is owed upstream. A change that
is not recorded here is a change the reconciliation will silently revert.

## What would retire this file

Flipping `verify = "skip"` to `verify = "full"` with a real
`divergence_patch`, which the manifest ack says needs the CM019 owner and a
reconciliation of the full shared-file delta. Until then this registry is the
only record that exists.
