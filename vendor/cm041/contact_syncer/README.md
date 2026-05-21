# Contact Syncer — GDPR Import Pipeline

Import your social graph from GDPR data exports into the PWG people graph.
One command imports everything; missing exports are skipped gracefully.

## Quick Start

```bash
# 1. Install dependencies
pip install -r contact_syncer/requirements.txt

# 2. Set environment variables (or create contact_syncer/.env)
export OXIGRAPH_URL=http://localhost:7878
export QDRANT_URL=http://localhost:6333
export EMBED_OLLAMA_URL=http://localhost:11434
export USER_ID=your_user_id

# 3. Run
python -m contact_syncer.import_all \
    --exports-dir ~/gdpr-exports/ \
    --user-name "Your Name" \
    --verbose
```

## Requesting GDPR Exports

Request your data from each platform. Most take 1-3 days to arrive.

| Platform | Where to request | Format | Key files |
|----------|-----------------|--------|-----------|
| LinkedIn | Settings > Data Privacy > Get a copy | CSV | Connections.csv, Positions.csv, messages.csv |
| Facebook | Settings > Your information > Download | JSON | your_friends.json, event_invitations.json |
| Instagram | Settings > Your activity > Download | JSON | followers_and_following/ directory |
| Twitter/X | Settings > Your account > Download | JS | contact.js |
| WhatsApp | Settings > Account > Request account info | JSON | contacts.json |
| Google | takeout.google.com | ICS | Calendar/*.ics |

## Expected Directory Layout

```
gdpr-exports/
├── LinkedIn/
│   ├── Connections.csv
│   ├── Positions.csv
│   ├── Endorsement_Received_Info.csv
│   ├── Recommendations_Received.csv
│   └── messages.csv
├── Facebook/
│   ├── connections/friends/your_friends.json
│   └── events/event_invitations.json
├── Instagram/
│   └── followers_and_following/
│       ├── close_friends.json
│       ├── followers_1.json
│       └── following.json
├── Twitter/
│   └── data/contact.js
├── WhatsApp/
│   └── contacts.json
└── Google/
    └── Calendar/calendar.ics
```

File locations are detected automatically via recursive search, so
exact subfolder names don't matter — just put each platform's export
somewhere under the root directory.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OXIGRAPH_URL` | Yes | — | Oxigraph SPARQL endpoint (RDF graph store) |
| `QDRANT_URL` | Yes | — | Qdrant vector database endpoint |
| `EMBED_OLLAMA_URL` | Yes | — | Ollama server for embeddings |
| `EMBED_MODEL` | No | `nomic-embed-text` | Embedding model name |
| `USER_ID` | Yes | — | Your user identifier in the graph |
| `DEFAULT_COUNTRY_CODE` | No | `852` | Default phone country code for matching |
| `CARDDAV_URL` | No | — | CardDAV server URL (for iCloud enrichment) |
| `CARDDAV_USERNAME` | No | — | CardDAV username |
| `CARDDAV_PASSWORD` | No | — | CardDAV app-specific password |

Store these in `contact_syncer/.env` or export them in your shell.

## What Each Parser Does

| Parser | Data Source | Creates | Matches Against |
|--------|-----------|---------|-----------------|
| **LinkedIn Connections** | Connections.csv | Person nodes + connection signals | Existing graph (name + LinkedIn URL) |
| **LinkedIn Career** | Positions.csv, Endorsements, Recommendations | Career timeline facts | — |
| **LinkedIn Messages** | messages.csv | Relationship signals (message counts, date ranges) | Existing graph (name matching) |
| **Facebook Friends** | your_friends.json | Person nodes + friend signals | Existing graph (name matching) |
| **Facebook Events** | event_invitations.json | Timeline event facts | — |
| **Instagram Social** | followers_and_following/ | Person nodes + follow signals, close friend tags | Existing graph (username matching) |
| **Google Calendar** | *.ics | Timeline event facts + attendee matching | Existing graph (name + email) |
| **WhatsApp Contacts** | contacts.json | Phone cross-reference signals | Existing graph (phone matching) |
| **Twitter Contacts** | contact.js | Phone cross-reference signals | Existing graph (phone matching) |

## Running Individual Parsers

Each parser can be run standalone:

```bash
python -m contact_syncer.linkedin_connections --csv /path/to/Connections.csv --verbose
python -m contact_syncer.linkedin_career --dir /path/to/LinkedIn/ --verbose
python -m contact_syncer.linkedin_messages --csv /path/to/messages.csv --verbose
python -m contact_syncer.facebook_friends --json /path/to/your_friends.json --verbose
python -m contact_syncer.facebook_events --dir /path/to/events/ --verbose
python -m contact_syncer.instagram_social --dir /path/to/followers_and_following/ --verbose
python -m contact_syncer.google_calendar --ics /path/to/calendar.ics --verbose
python -m contact_syncer.whatsapp_contacts --json /path/to/contacts.json --verbose
python -m contact_syncer.twitter_contacts --js /path/to/contact.js --verbose
```

All parsers support `--dry-run` (parse and match without writing) and `--verbose`.

## Proxy Note

If your machine has an HTTP proxy configured (e.g. `HTTP_PROXY=127.0.0.1:8118`),
it will intercept LAN traffic to Oxigraph/Qdrant/Ollama. Run with proxies cleared:

```bash
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
    python -m contact_syncer.import_all --exports-dir ~/gdpr-exports/ --verbose
```

## Privacy

- All processing runs locally. No data is sent to cloud services.
- Phone numbers are matched by last 8 digits (no full numbers stored in logs).
- Email content is never stored — only metadata (sender, date, thread count).
- LinkedIn message bodies are not stored — only per-person signal counts.
- The `--dry-run` flag lets you preview what would be imported without writing.
