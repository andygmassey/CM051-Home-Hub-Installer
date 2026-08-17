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

## How to add a row

When you change anything under `vendor/cm019_preferences`, add a row here in
the same PR. File, what, why, and whether it is owed upstream. A change that
is not recorded here is a change the reconciliation will silently revert.

## What would retire this file

Flipping `verify = "skip"` to `verify = "full"` with a real
`divergence_patch`, which the manifest ack says needs the CM019 owner and a
reconciliation of the full shared-file delta. Until then this registry is the
only record that exists.
