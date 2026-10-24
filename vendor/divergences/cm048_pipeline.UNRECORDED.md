# cm048_pipeline -- unrecorded divergences

This file is this tree's `unrecorded_divergence` pointer
(`vendor/VENDOR_MANIFEST.toml`). It exists for edits that cannot be captured
by `vendor/divergences/cm048_pipeline.patch` -- see each entry for why. The
earlier entries were retired on 2026-10-18 (CM051 #2969), when source@0190f448
plus the patch was measured to reconstruct the tree; this graft landed after.
The 2026-10-15 start_time graft (in the patch, not here) was RETIRED by the
14d75c15 re-pin: upstream CM048 #89 reads both key spellings itself.

## Graft: summaries and todos in the conversation's own language (Lane 9, 2026-10-07)

Tree `cm048_pipeline`. A graft of CM048 branch `claude/great-heisenberg-qrc0f3`
(written on top of `436c89c1`, merged forward onto the `0190f448` pin, then onto
the `14d75c15` pin on 2026-10-18).

NOW CARRIED BY `cm048_pipeline.patch` (2026-10-18, v1.0.109 re-pin): the patch
was regenerated with `$CM048` cloned, so this graft is no longer an
unrecorded edit; the entry stays because CM048 main (14d75c15) still has no
`src/language.py`, i.e. upstream does not carry it yet. Measured:
`grep -c language.py vendor/divergences/cm048_pipeline.patch` = 4 (was 0).

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

## Graft: reply debt names people, never the owner, never a short code (P13, 2026-10-23)

Tree `cm048_pipeline`. A graft of CM048 branch `fix/p13-handle-identity`
(head `b83c30132b25623c388f00b18b38f2c417e28b9f`, written on CM048 main
`f6b75be`, open for review). NOT at the pin and NOT in the patch: `$CM048` is
not checked out on CI, and the branch is unmerged upstream.

v1.0.117 walk: the 18:00 brief listed "Waiting on a reply from you" as five raw
phone numbers, one the owner's own. Files:

- new `src/handle_identity.py`: canonical phone form in the owner's country,
  owner handles (installer env plus every identifier on the owner node or the
  owner's own-name me-card), short code / sender id / no-reply shapes.
  BYTE-IDENTICAL to upstream (sha256 dc42984808773f0a...).
- `src/handle_resolver.py`: `build_directory()`. BYTE-IDENTICAL to upstream.
- `src/reply_debt.py`: `identify_threads()`, `resolved` / `handle_kind`
  fields, the brief line never prints digits. BYTE-IDENTICAL to upstream.
- `src/reply_debt_service.py`: the same three hunks upstream carries (the
  `directory` argument, identification before detect, `excluded` and
  `names_degraded` in the payload), applied to this tree's snapshot-based
  service, which already diverges from upstream (CM051 #30).

### What a future sync must preserve

All of the above. Guarded by `tests/test_reply_debt_names_people_p13.py`, run by
`.github/workflows/reply-debt-never-reads-protected-data.yml` through the real
vendored ical-server. A re-pin to a CM048 commit that includes the branch makes
the first three files redundant here; the service hunks stay a graft until the
snapshot service itself is upstreamed.
