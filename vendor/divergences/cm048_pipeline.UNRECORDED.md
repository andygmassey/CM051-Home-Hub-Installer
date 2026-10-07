# cm048_pipeline -- unrecorded divergences

This file is this tree's `unrecorded_divergence` pointer
(`vendor/VENDOR_MANIFEST.toml`). It exists for edits that cannot be captured
by `vendor/divergences/cm048_pipeline.patch` -- see each entry for why.

## First graft: a WhatsApp LID stops being written as a phone number (CM051 #2578, 2026-10-01)

Tree `cm048_pipeline`, file `vendor/cm048_pipeline/src/ingest.py`:

- new `_whatsapp_jid_is_genuine_phone(local)`, validating with
  `phonenumbers.is_valid_number` rather than `str.isdigit()`;
- `_normalise_chat_identifier`'s WhatsApp branch calls it before formatting
  a JID's local part as a `"+<digits>"` phone;
- `import phonenumbers` added; `phonenumbers>=8.13.0` added to
  `vendor/cm048_pipeline/pyproject.toml`'s `dependencies` (install.sh's
  `pip install "$_dir"` into the cm048 venv picks this up automatically --
  no install.sh change needed).

Not attempted against the regeneration tool for this change: `cm048_pipeline`
is pinned with `verify = "skip"` / `unverifiable_ack = true` already (this
tree's own round-trip cannot be certified at all, independent of this edit),
and the divergence patch at the pin is already a hand-maintained record for
a tree in that state. Recorded here by location and shape instead, same
discipline as the other per-tree UNRECORDED files in this directory.

WHY: `_normalise_chat_identifier` used `local.isdigit()` to decide whether a
WhatsApp JID's local part was a genuine phone number -- true for both a
real phone-rooted JID and a 14-15 digit linked-device id (LID) presented
through the same `@s.whatsapp.net` suffix. Same bug class as CM051 #2543
(ostler_fda's `pwg_ingest.py`, already shipped with the same discriminator)
and CM051 #2545 (CM041's `identity_resolver.normalise.is_valid_phone`).
Mirrors CM048 PR #80's source-side fix (`andygmassey/CM048-PWG-Conversation-
Processing#80`, open at the time of this graft).

### What a future sync must preserve

`_whatsapp_jid_is_genuine_phone` and its call site inside
`_normalise_chat_identifier`'s `channel == "whatsapp"` branch, plus the
`phonenumbers` import and the `pyproject.toml` dependency line. Guarded by
`tests/test_cm048_whatsapp_lid_not_phone.py` (CM051 repo root, following the
same top-level placement `tests/test_every_conversation_produces_all_four_
artefacts.py` already uses for this same vendored tree), wired into
`.github/workflows/cm048-whatsapp-lid-not-phone.yml`. Retire by landing CM048
PR #80 and re-pinning.

## Second graft: summaries and todos in the conversation's own language (Lane 9, 2026-10-07)

Tree `cm048_pipeline`. A graft of CM048 branch `claude/great-heisenberg-qrc0f3`
(on top of the pinned `436c89c1`), applied as one patch; NOT in
`cm048_pipeline.patch` for the same reason as the first graft (`verify = "skip"`,
`unverifiable_ack = true`).

Product decision (founder, 2026-09-22): the UI stays English; the assistant
answers, transcribes and summarises in the owner's language. Files:

- new `src/language.py`: output-language resolution (owner's `summary_language`
  setting, else the capture-side language, else detected from the text, else the
  locale) and the prompt block. DEFAULT, one and documented: summaries and todos
  are written in the language the conversation was held in; the owner can pin a
  language with `summary_language: <code>` in `settings.yaml`.
- `src/settings.py` + `settings.yaml.example`: the `summary_language` setting.
- `src/processor.py`: an OUTPUT LANGUAGE block in the enrichment and merge prompts;
  the resolved language passed to the bundle extractor.
- `src/bundle_extractor.py`, `prompts/09_bundle_extract.md`,
  `prompts/_conventions.md`: the same instruction; section headings, table columns
  and JSON keys stay English because software parses them.
- `src/outstanding_todos.py`: localised heading, column, priority, done-phrase and
  relative-day aliases so a model that translates `## Action items` anyway does not
  silently lose every todo of a non-English conversation.
- `src/topic_writer.py`: a topic name in a script ASCII cannot represent (CJK,
  Cyrillic) used to slug to `""` and the topic was skipped; it now gets a stable
  hashed slug (same idea as ical-server `_wiki_slug`'s `person-<sha1>`).
- `src/conversation_writer.py`: folder slugs keep non-ASCII letters.
- `src/chunker.py`: character budget scaled for CJK (about 1.5 characters per token,
  not 4), non-Latin speaker labels, CJK sentence enders.

### What a future sync must preserve

All of the above. Guarded by `tests/test_cm048_multilingual_vendored.py`, run by
`.github/workflows/cm048-multilingual-output.yml` against this vendored tree. The
CM048 source repo carries the same change and the same suite, so a re-pin to a CM048
commit that includes it makes this entry redundant and it can be deleted.

