# ostler_fda – macOS Full Disk Access Data Extraction

Extracts personal data from macOS-native databases that require
Full Disk Access permission. These are SQLite databases that Apple
protects behind TCC (Transparency, Consent, and Control).

## Data sources

| Source | Database path | What we extract |
|--------|--------------|-----------------|
| iMessage | `~/Library/Messages/chat.db` | Conversations, participants, timestamps, message text |
| Safari History | `~/Library/Safari/History.db` | URLs, visit timestamps, visit counts |
| Safari Bookmarks | `~/Library/Safari/Bookmarks.plist` | Bookmarked URLs, folder structure |
| Apple Notes | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | Note titles, text content, creation/modification dates |
| Calendar | `~/Library/Calendars/` | Events, attendees, locations, dates |
| Photos | `~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite` | Face labels, locations, dates, albums (NOT photo content) |
| Reminders | `~/Library/Reminders/` | Tasks, completion status, dates |
| Apple Mail | `~/Library/Mail/V*/MailData/` | Email metadata, subjects, senders, dates (if Mail.app used) |

## Architecture

Each extractor is a standalone Python module that:
1. Opens the SQLite database read-only
2. Extracts structured data into a common format
3. Outputs JSON ready for the PWG import pipeline
4. Handles schema changes gracefully (Apple updates these between macOS versions)

## Permission model

- FDA must be granted to the process running the extraction
- During install: the installer binary/Terminal needs FDA
- Post-install: the Ostler launchd service needs FDA
- User grants FDA once in System Settings > Privacy & Security

## Privacy

- All extraction is local – nothing leaves the machine
- Each data source respects the user's privacy levels
- iMessage extraction honours conversation-level sensitivity
- Photo face data is metadata only – no image content is read
- Notes can be excluded by the user

## Status

- [x] Safari History extractor (safari_history.py)
- [x] Safari Bookmarks extractor (safari_bookmarks.py)
- [x] iMessage extractor (imessage.py)
- [x] Apple Notes extractor (apple_notes.py)
- [x] Calendar extractor (calendar.py)
- [x] Photos metadata extractor (photos_metadata.py)
- [x] Master extraction runner (extract_all.py)
- [x] Reminders extractor (reminders.py)
- [x] Apple Mail extractor (apple_mail.py)
- [x] 93 automated tests (ostler_fda/tests/)
- [x] Integrated into installer Phase 3
- [x] Integration with PWG import pipeline (pwg_ingest.py + 24 tests)
- [x] macOS version fallback schemas (6/8 extractors have version-aware code)
- [ ] Test on Mac Studio with FDA granted
- [ ] Safari history enrichment (re-fetch top pages through LLM)
