# cm048_pipeline -- unrecorded divergences

This file is this tree's `unrecorded_divergence` pointer
(`vendor/VENDOR_MANIFEST.toml`). It exists for edits that cannot be captured
by `vendor/divergences/cm048_pipeline.patch` -- see each entry for why. The
earlier entries were retired on 2026-10-18 (CM051 #2969), when source@0190f448
plus the patch was measured to reconstruct the tree; this graft landed after.

## Graft: summaries and todos in the conversation's own language (Lane 9, 2026-10-07)

Tree `cm048_pipeline`. A graft of CM048 branch `claude/great-heisenberg-qrc0f3`
(written on top of `436c89c1`, merged forward onto the `0190f448` pin), applied as one patch; NOT in
`cm048_pipeline.patch`: `verify = "skip"` and `$CM048` is not checked out here,
so the patch cannot be regenerated to carry it.

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
