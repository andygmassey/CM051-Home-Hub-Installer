# meeting_import (Lane 31)

Brings a new owner's existing meeting history across, locally, on day one.
Feature flag OFF: set `OSTLER_MEETING_IMPORT_ENABLED=1` to run. No network.
Not yet in the DMG payload (see "Not done").

Drop files in `~/Documents/Ostler/Imports/<source>/` (`granola`, `otter`,
`fireflies`, `transcripts`; override with `OSTLER_MEETING_IMPORT_DIR`), then
`python -m meeting_import`. Output per meeting, via the existing CM048 writer:
`~/Documents/Ostler/Conversations/<date>/<slug>-<id>/` with `summary.md`,
`transcript.md`, `todos.md`, metadata as frontmatter on each.

Note: CM052's ChatGPT drop folder is lowercase `imports/`; this uses the
`Imports/` the Lane 31 brief names.

## Behaviour
- Source summary / action items are kept and labelled ("From Granola: ...",
  topic names end "(from Granola)", todo anchor "from Granola").
- Privacy: `channel="spoken"` through `channel_adapter.make_bundle`, so L2 like
  CM042 calls; `--private` makes L3.
- Attendees are resolve-only (`people.py`): email exact, else full name exact
  and unique. A single first name or a "Speaker 1" label is never looked up and
  never minted. Linked person URIs go in frontmatter (`linked_person_N`).
- Action items are NOT queued for Reminders on import (`demo_mode=True` skips
  the mapping DB). `--push-reminders` opts in; the normal gate then applies.
  Items with no assignee get owner `unassigned`, which the gate skips.
- Idempotent: id is the source's meeting id, else a hash of title, start and
  transcript head. The folder slug uses raw attendee names, so linking a person
  later does not move the folder.

## Formats: confirmed vs assumed
Web fetch of the vendors' docs failed from the build sandbox; vendor facts come
from search summaries, so none are "read first-hand".

| Source | Path | Parsed | Status |
|---|---|---|---|
| Otter | Conversation menu > Export (help.otter.ai/hc/en-us/articles/360047733634) | TXT, SRT, DOCX | Export path and formats: confirmed by Otter help (via search). TXT/DOCX line layout: ASSUMED. Bulk export is Business plans and up. Summary/action items are a separate Otter export: not parsed (TODO). |
| Fireflies | GraphQL API, owner's own key (docs.fireflies.ai/graphql-api/query/transcript) | JSON the owner saves | Fields via search of official schema; snake_case spellings from community samples: ASSUMED. `participants` are emails and may omit external guests. Web-UI downloads not researched. |
| Granola | Official API (`GET /v1/notes`, `grn_` key, Business/Enterprise) | JSON note, Markdown note | Field names from a community reference: ASSUMED. Transcript endpoint reports conflict. |
| Granola local cache | `~/Library/Application Support/Granola/` | NOT read | Reportedly encrypted on current builds (community). Not attempted. |
| Zoom | Cloud transcript `.vtt` (Zoom support KB0064927) | VTT | File type confirmed; `Name: text` cue line ASSUMED. |
| Teams | Recap > download `.docx` / `.vtt` | DOCX, VTT | One secondary source; layout ASSUMED. |
| Meet | Google Doc in Drive; File > Download `.docx` | DOCX | Location confirmed; layout ASSUMED. |

Every fixture in `tests/test_meeting_import.py` is synthetic and written to
match these assumptions, so green tests prove the parsers, not the vendors'
real files. First real-file sample from each vendor should be checked.

## Not done / TODO
- Universal-import detection: `ostler_fda/universal_import.py` has an ordered
  `_DETECTORS` list (line 570) and `_DISPATCH`. Registering a meeting detector
  there edits a pinned vendor tree and needs a recorded divergence, so it is
  left for a deliberate graft. The drop folder works without it.
- Packaging: no `gui/Makefile` payload input, so it does not ship; shipping it
  also needs an OS003 BOM row. Not authored here.
- `OxigraphPersonDirectory` is not run against a live graph in CI.
- Graph edges (`hasParticipant`) and `lastContact` bumps are not written.
- No LLM summary for sources that supply none; the summary says so plainly.
