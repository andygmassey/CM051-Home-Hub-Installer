# The shared correspondent sink records the TRUE source of each person

**Hand-built 2026-10-19 (People join fix 3). Location and shape only.**

Tree: `ostler_fda`. Not regenerated into `ostler_fda.patch`: a dry run of
`scripts/regenerate_divergence_patch.sh ostler_fda` against pin c4e7396f
reports 51 files / +7457 / -254, almost all of it other trees' unrecorded
grafts. Blessing that in bulk is not this change's call.

## What changed, per file

| file | change |
|---|---|
| `pwg_ingest.py` | `ingest_mail_contacts(fda_dir, *, person_source="apple_mail_fda", identifier_label="APPLE_MAIL")`; both written in place of the hardcoded literals; shape-validated (`^[a-z][a-z0-9_]{1,63}$`, `^[A-Z][A-Z0-9_]{1,63}$`) because they are interpolated into SPARQL |
| `universal_import.py` | `_PEOPLE_SOURCE_LABELS = {"google_chat": ("google_chat_takeout", "GOOGLE_CHAT")}`; `_persist_mail_contacts` passes them for a mapped `source`, and the defaults for every mail source |

## Why

The Google Chat Takeout importer (CM051 #3022, `SOURCE = "google_chat"`)
hands its correspondents to this sink, which minted every one as
`pwg:source "apple_mail_fda"` / `identifierLabel "APPLE_MAIL"`. Defaults are
unchanged, so every mail caller writes byte-identical triples.

## Upstream

HR015 `ostler_fda/pwg_ingest.py` has no resolve-before-create
`ingest_mail_contacts` at all (the CM051 copy is ahead), so this is not
upstreamable as a one-file port. Test:
`tests/test_people_source_label_is_the_true_source.py` (privacy-spine.yml).
