# meeting_import (Lane 31)

Brings a new owner's existing meeting history across, locally, on day one.
Feature flag OFF: set `OSTLER_MEETING_IMPORT_ENABLED=1` to run. No network.
Not in the DMG payload (see "Not done").

Two ways in:
- `python -m meeting_import --loose ~/Downloads`: each file's source is
  detected from its documented name or content (`adapters.detect`);
  anything it cannot attribute is left alone. Generic VTT/SRT/DOCX are never
  guessed from a loose folder.
- `python -m meeting_import [--root DIR]`: a drop folder laid out as
  `<root>/<source>/` (`granola`, `otter`, `fireflies`, `fathom`,
  `transcripts`), default `~/Documents/Ostler/Imports`.

Output per meeting, via the existing CM048 writer:
`~/Documents/Ostler/Conversations/<date>/<slug>-<id>/` with `summary.md`,
`transcript.md`, `todos.md`, metadata as frontmatter on each. The CLI also
writes `~/.ostler/state/hydrate/meetings.done` (ok / no_data / error,
per-source counts) in the key=value shape the Doctor's source table reads.

## Behaviour
- Source summary / action items are kept and labelled ("From Granola: ...",
  topics end "(from Granola)", todo anchor "from Granola"). A source with no
  summary says so plainly; no LLM summary is generated on import.
- Privacy: `channel="spoken"` through `channel_adapter.make_bundle`, so L2 like
  CM042 calls; `--private` makes L3.
- Attendees are resolve-only (`people.py`): email exact, else full name exact
  and unique. A single first name or a "Speaker 1" label is never looked up and
  never minted. Linked person URIs go in frontmatter (`linked_person_N`).
- Action items are NOT queued for Reminders on import. `--push-reminders`
  opts in. Fathom items marked completed are not imported as open todos.
- Idempotent: id is the source's meeting id, else a hash of title, start and
  transcript head.

## Formats (each checked against the vendor's own docs on 2026-10-18)

| Source | How the owner gets the file | Parsed | Evidence |
|---|---|---|---|
| Granola | Settings > Profile > Generate CSV (every plan; emailed, 24 h link) | CSV | Export path CONFIRMED (docs.granola.ai/help-center/sharing/exporting-notes). Column NAMES not documented: matched by keyword, ASSUMED. |
| Granola | Public API `GET /v1/notes/{id}?include=transcript` (Business/Enterprise key) | JSON note or `{"notes": [...]}` | Schema CONFIRMED from docs.granola.ai/api-reference/openapi.json (speaker object, ISO start_time, calendar_event). |
| Otter | Conversation > three dots > Export (TXT on Basic; DOCX/SRT on paid), bulk ZIP on Business | TXT, DOCX, SRT | Layout CONFIRMED from the "Export Examples" image in help.otter.ai/hc/en-us/articles/360047733634. Otter summary export: layout not shown, NOT parsed. |
| Fireflies | API `transcript(id)` with the owner's key | JSON | Schema CONFIRMED (docs.fireflies.ai/schema/transcript, sentence, summary, meeting-attendee). Bold-assignee grouping of action_items ASSUMED. |
| Fireflies | Meeting > Download (Pro and up): PDF/DOCX/SRT/CSV/JSON/MD | SRT, DOCX, sentence-list JSON | Formats CONFIRMED (guide.fireflies.ai/articles/3319752033); layouts NOT documented: ASSUMED. CSV/MD/PDF not parsed. |
| Fathom | API key (User Settings > API Access), `GET /external/v1/meetings?include_transcript=true&include_summary=true&include_action_items=true` | JSON | Schema CONFIRMED from developers.fathom.ai/api-reference/openapi.yaml. No in-app file export is documented by Fathom. |
| Zoom / Teams / Meet | transcript file | VTT, SRT, DOCX | Speaker-label conventions ASSUMED. |

Every fixture is synthetic and built to the documented schema, so green tests
prove the parsers against the documented format, not against a real file. The
first real export from each vendor should be checked before the flag goes on.

## Not done
- Live-pipeline handoff: imports write the four artefacts directly. Routing
  them through CM048 `processor.process` would add graph facts, related-
  conversation links and lastContact, but its `_step_bundle` calls
  `write_conversation` with Reminders push ON, so every historical todo would
  be queued. Needs a CM048 change (a historical-import flag that keeps
  demo_mode on) before an import can use it.
- Packaging: not staged into the DMG (gui/Makefile) and no OS003 BOM row; no
  `ostler-import` arm; the Doctor does not yet SERVE a `meetings` row (the
  record is written; `vendor/doctor/agent/web_ui.py` `_FDA_EXTRACT_KINDS` and
  the canonical-source gate need the row added together with packaging).
- `OxigraphPersonDirectory` is not run against a live graph in CI.
