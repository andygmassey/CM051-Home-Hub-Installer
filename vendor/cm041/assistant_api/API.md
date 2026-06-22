# Marvin API — endpoint reference

The unified Marvin API server (`ical-server.py`) runs on `localhost:8089`
and exposes calendar, email, and People Graph endpoints. It is consumed
by the CM031 PWG Companion iOS app and by the ZeroClaw assistant on the
Mac Mini.

LAN-only assumption applies for v1; no auth.

## Path versions

The server accepts both legacy unprefixed paths (`/people/search`) and
versioned paths (`/api/v1/people/search`). Versioned paths route to the
same handler. Prefer the versioned form for new clients.

| Versioned                      | Legacy alias       |
| ------------------------------ | ------------------ |
| `/api/v1/people/search`        | `/people/search`   |
| `/api/v1/people/context`       | `/people/context`  |
| `/api/v1/people/stale`         | `/people/stale`    |
| `/api/v1/people/recent`        | `/people/recent`   |
| `/api/v1/people/birthdays`     | `/people/birthdays`|
| `/api/v1/calendar`             | `/calendar`        |
| `/api/v1/calendar/today`       | `/calendar/today`  |

## Degraded-graceful contract

Endpoints that talk to Qdrant or Oxigraph degrade rather than 5xx when
their backend is unreachable. The response is still HTTP 200 and the
shape includes:

```json
{
  "<items_key>": [],
  "degraded": true,
  "reason": "<short backend error>",
  "error": "<same as reason, kept for backward compat>"
}
```

`<items_key>` is whatever key the endpoint normally returns
(`results`, `contacts`, `people`, `items`, etc.). Existing keys are
preserved so older clients keep working.

Clients SHOULD check `degraded` and surface a "data partially
unavailable" hint to the user; SHOULD NOT treat HTTP 200 + degraded as
success.

## Input validation

Integer query params (`days`, `months`, `limit`, `hours`) are parsed
with `_safe_int`. Bad values return HTTP 400 with `{"error": "Invalid
integer value for '<key>': '<raw>'"}` rather than 5xx.

Required string params (`q` for search, `name` for context) return HTTP
400 with `{"error": "Missing ?<key>= parameter"}` if absent.

## Endpoints

### `GET /api/v1/people/search?q=<query>&limit=<n>`

Semantic search across the Qdrant people collection (default `limit=5`).

The JSON surface uses British-English keys (`organisation`, `role`)
and always carries a `slug` the CM031 iOS companion uses as its
`Identifiable` id. Qdrant payload keys stay American English for
storage-compat; the rename happens at response time. See `#ARCH-01`
in `HR015/ARCHITECTURE_DRIFT.md` for the drift history.

```json
{
  "query": "fintech",
  "results": [
    {
      "name": "Jane Doe",
      "slug": "jane-doe",
      "score": 0.812,
      "wiki_url": "http://localhost:8044/People/jane-doe/",
      "organisation": "Example Corp",
      "role": "VP Product",
      "last_contact": "2026-02-14"
    }
  ],
  "count": 1
}
```

### `GET /api/v1/people/context?name=<slug-or-name>`

Full Person record: identifiers, facts, recent meetings, latest
relationship-signal observation. Single match returns
`{"person": {...}}` plus the same fields lifted to the top of the
envelope (so CM031's flat `PersonContextResponse` decodes cleanly);
multiple matches return `{"matches": [...], "count": N}` with no
flat lift.

Per-person fields use British-English keys (`organisation`,
`how_we_met`) and always include `slug`. Note the contrast with
`/people/search`: search uses `role` (short label for list rows),
context uses `title` (full job title for detail views) – this
mirrors the distinction in CM031's `PersonResult` vs `PersonDetail` /
`PersonContextResponse`.

```json
{
  "query": "Jane",
  "found": true,
  "name": "Jane Doe",
  "slug": "jane-doe",
  "organisation": "Example Corp",
  "title": "VP Product",
  "last_contact": "2026-02-14",
  "person": {
    "name": "Jane Doe",
    "slug": "jane-doe",
    "person_uri": "urn:pwg:person/jane-doe",
    "wiki_url": "http://localhost:8044/People/jane-doe/",
    "organisation": "Example Corp",
    "title": "VP Product",
    "relationship": "colleague",
    "how_we_met": "RISE 2024",
    "last_contact": "2026-02-14",
    "notes": "Co-founder of prior startup.",
    "birthday": "1985-06-12"
  }
}
```

### `GET /api/v1/people/{slug}/enrichment`

Per-slug enrichment payload for the iOS / Hub person card. Where
`/people/context?name=` is a fuzzy name search that can return several
matches, this endpoint resolves a single canonical person by wiki slug
(the stable identifier the People list, search results, and wiki URLs
already use) and returns the richer body the card wants beyond the list
basics: organisation, role/title, relationship, how-we-met, notes,
birthday, identifiers, recent meetings, the relationship signal, the
MAX `last_contact`, and the per-source `last_contact_by_source`
breakdown.

The slug is validated against the same pattern as
`POST /api/v1/people/{slug}/forget` (lowercase ASCII letters, digits,
hyphens, max 80 chars). Per-person fields use British-English keys and
the response mirrors `/people/context`'s dual shape (`{"person": {...}}`
plus the same fields lifted to the envelope top-level). `role` and
`title` both carry the job title so either CM031 client decodes a value.

Best-effort Qdrant top-up adds `phone` / `email` and a display
`last_contact` when the graph lacked them; a Qdrant failure is swallowed
(the graph fields are the source of truth). Additive keys
(`last_contact_by_source`, `identifiers`, `meetings`, `facts`,
`relationship_signal`) appear only when the graph has the data.

Status codes:

- `400` malformed slug
- `404` `{"found": false}` no person resolves to the slug
- `503` `{"degraded": true}` Oxigraph unreachable
- `200` `{"found": true, "person": {...}}`

```json
{
  "slug": "jane-doe",
  "found": true,
  "organisation": "Example Corp",
  "role": "VP Product",
  "last_contact": "2026-04-20",
  "person": {
    "name": "Jane Doe",
    "slug": "jane-doe",
    "person_uri": "urn:pwg:person/jane-doe",
    "wiki_url": "http://localhost:8044/People/jane-doe/",
    "organisation": "Example Corp",
    "title": "VP Product",
    "role": "VP Product",
    "relationship": "colleague",
    "last_contact": "2026-04-20",
    "last_contact_by_source": {
      "calendar": "2024-03-01",
      "whatsapp": "2026-04-20",
      "email": "2025-11-30",
      "imessage": "2026-01-05"
    },
    "phone": "+10000000000",
    "email": "jane@example.com",
    "identifiers": [
      {"type": "phone", "value": "+10000000000"},
      {"type": "email", "value": "jane@example.com"}
    ],
    "meetings": [
      {"summary": "Quarterly sync", "date": "2026-02-14", "location": "Room 1"}
    ],
    "relationship_signal": {"warmth": "0.7", "trust": "0.6", "observed_at": "2026-03-01T09:00:00Z"}
  }
}
```

### `GET /api/v1/people/stale?months=<n>&limit=<n>`

Contacts not interacted with for at least `months` months
(default 3, limit 5). Ordered by most-stale first. Reads
`last_contact_ts` from Qdrant.

```json
{
  "contacts": [
    {
      "name": "Pat Wong",
      "slug": "pat-wong",
      "wiki_url": "...",
      "last_contact": "2025-09-01",
      "months_since_contact": 7,
      "organization": "Bank Co"
    }
  ]
}
```

### `GET /api/v1/people/recent?days=<n>&limit=<n>`

People with meetings in the last `days` days (default 7, limit 5).
Ordered most-recent first. Sourced from `pwg:Meeting` in Oxigraph.

### `GET /api/v1/people/birthdays?days=<n>`

Upcoming birthdays within `days` days (default 7). Reads
`pwg:birthday` from Oxigraph.

```json
{
  "people": [
    {
      "name": "Pierre Dubois",
      "slug": "pierre-dubois",
      "birthday": "05-12",
      "days_until": 19
    }
  ]
}
```

### `GET /api/v1/calendar?days=<n>` / `GET /api/v1/calendar/today`

Calendar events for the next `days` days (default 7), merged from
iCloud (via `ical-query.sh`) and Google Calendar (via `gws`).
Deduplicated by `(summary, start)`.

Each event carries the legacy iCal-style fields plus iOS-friendly
aliases:

| Field | Notes |
|---|---|
| `summary`        | Legacy; matches Marvin / wiki tooling. |
| `title`          | Alias for `summary`; CM031 `CalendarEvent.title`. |
| `start`, `end`   | iCal local-time, e.g. `20260428T093000`. |
| `start_iso`, `end_iso` | ISO-8601, e.g. `2026-04-28T09:30:00`. |
| `attendees`      | List of `{name, email, role}` dicts. |
| `attendee_names` | List of plain strings; CM031 `[String]` shape. |
| `location`       | iCal `LOCATION:` value. |
| `source`         | `iCloud` or `Google Calendar`. |

### `GET /api/v1/timeline?days=<n>`

Chronological merge of upcoming calendar events + past meetings within
the window. Each `items[]` entry carries `kind` (`calendar` | `meeting`)
plus the fields appropriate to that kind.

For the CM031 PWG Companion (which decodes a flat `entries: [...]`
shape) the same data is also surfaced under `entries`, mapped to the
iOS vocabulary:

```json
{
  "items": [...legacy shape...],
  "entries": [
    {
      "type": "calendar",
      "timestamp": "2026-04-28T09:30:00",
      "title": "Stand-up",
      "subtitle": "Zoom",
      "attendees": ["Alice", "bob@example.com"]
    }
  ],
  "days": 7,
  "count": 1
}
```

`entries[].timestamp` is normalised to ISO-8601 where parseable;
unparseable strings flow through unchanged so the client can render
them rather than silently nilling.

### `GET /api/v1/meeting/upcoming?within_minutes=<n>`

Enriched pre-meeting briefs for events starting within the next
``within_minutes`` (default 120). Read side of the pre-meeting brief
wiring -- the CM048 conversation processing pipeline writes
``pwg:OutstandingTodo`` triples to Oxigraph; the
``meeting_syncer/brief.py`` generator gathers calendar + People
Graph + TODO context; this endpoint exposes the result.

```json
{
  "meetings": [
    {
      "meeting": "Discovery call with Alice",
      "start": "2026-05-30 10:30 BST",
      "start_iso": "20260530T103000",
      "uid": "cal-event-uid-abc123",
      "location": "Mortimer House",
      "maps_url": "https://www.google.com/maps/search/?api=1&query=Mortimer+House",
      "attendees": [
        {
          "name": "Alice Tester",
          "email": "alice@example.com",
          "wiki_url": "http://localhost:8044/People/alice-tester/",
          "organization": "Acme Ltd",
          "facts": ["Prefers async communication"],
          "times_met": 4,
          "last_met": "2026-04-12",
          "last_discussion_url": "http://localhost:8044/Conversations/2026-04-12_alice_zoom/",
          "outstanding_todos": [
            {
              "text": "Send the pitch deck",
              "owner": "user",
              "owner_display": "Operator",
              "deadline": "2026-05-30",
              "priority": "high",
              "source_conversation_date": "2026-04-12"
            }
          ]
        }
      ]
    }
  ],
  "within_minutes": 120,
  "count": 1
}
```

Full schema in `meeting_syncer/SCHEMA.md`.

Consumers:

- **CM051 LaunchAgent cron sender** polls every ~10 min with
  `within_minutes=20` and ships a WhatsApp message for each unsent
  meeting (idempotency via UID + sent-briefs DB).
- **CM031 iOS Companion `MeetingBriefService`** polls every 5 min
  with `within_minutes=120` and posts a local notification 15-20
  min before each meeting.

Degraded-graceful: People Graph failure returns
`{"meetings": [], "degraded": true, "reason": "..."}` + HTTP 200
rather than 5xx so callers can keep polling without raising the
Hub-offline pill.

### `GET /api/v1/suggestions`

Composite for the iOS Today view. Three sections:

```json
{
  "birthdays": [...],
  "stale_contacts": [...],
  "recent_meetings": [...],
  "reconnect": [...same as stale_contacts...],
  "follow_up": [...same as recent_meetings...]
}
```

`reconnect` and `follow_up` are aliases for `stale_contacts` and
`recent_meetings` respectively – CM031's `SuggestionsResponse` keys
on those names; the Marvin / wiki tools use the legacy keys. Both
clients work without coordination.

Per-section failure capture: a section that fails will have its array
present-but-empty plus a sibling `<section>_error` field. Aliases
mirror the legacy section, so they too will be empty in that case.

### `GET /api/v1/email/recent?hours=<n>&limit=<n>`

Recent emails from Gmail via `gws`. Returns subject + from + date +
snippet only — never full body.

### `GET /api/v1/coach/recent?hours=<n>&limit=<n>`

Recent coaching observations from the CM048 SQLite DB. Defaults to
the last 168 hours (7 days).

### `POST /api/v1/conversation/process`

Submit a conversation transcript for CM048 processing. Returns 202
with a `job_id`. Status via `GET /api/v1/conversation/status/{id}`.

### `POST /api/v1/ingest/ios`

Batch upload from the iOS companion. Body shape: `{"items": [...]}`.
Max 1000 items per batch, max 1 MB body. Writes to `INGEST_DIR` for
downstream pickup.

### `GET /health` / `GET /health?detailed=1`

`/health` returns `{"status": "ok"}` cheaply. `?detailed=1` runs
reachability checks against Qdrant, Oxigraph, Ollama, the `gws` CLI,
and the iCloud query script; returns `degraded` if any check fails.

### `GET /api/v1/hub/health`

Source of truth for the iOS Companion's Hub status pill
(Online / Catching up / Offline). Contract is defined in
`HR015/HUB_PORTABILITY_PLAN.md`.

Derives `hub_status` from service health plus queue depth:

- `online` – all services healthy and queue empty
- `catching_up` – at least one service healthy, but one is down or
  `queue_depth > 0`
- `offline_local` – no upstream service reachable (Hub is awake but
  its own upstreams, e.g. Google / iCloud / Docker, are down). Distinct
  from the iOS-side "Hub unreachable", which is inferred from a timeout.

Every sub-check is capped at `HUB_CHECK_TIMEOUT_SECONDS` (default 2 s)
and runs in parallel so one slow dependency cannot block the response.
The endpoint itself never 5xxs; catastrophic failures return
`hub_status: "offline_local"` with an `error` field.

```json
{
  "hub_status": "online",
  "hub_version": "0.5.9",
  "last_sync": "2026-04-24T15:32:01Z",
  "queue_depth": 0,
  "power_state": "ac",
  "services": {
    "zeroclaw": { "healthy": true, "pid": 48466 },
    "ollama":   { "healthy": true, "model": "qwen3.5:9b" },
    "pwg":      { "healthy": true, "containers_up": 9, "containers_expected": 9 },
    "caldav":   { "healthy": true, "last_refresh": "2026-04-24T15:31:58Z" }
  },
  "degraded_features": []
}
```

When a service is unhealthy, `degraded_features` carries the union of
feature keys the iOS side should grey out. The current mapping:

| Service down | Features unavailable                                 |
| ------------ | ---------------------------------------------------- |
| `ollama`     | `assistant_chat`, `it_guy`                              |
| `zeroclaw`   | `assistant_chat`, `it_guy`, `email_triage`              |
| `pwg`        | `people_search`, `timeline`, `wiki_live`             |
| `caldav`     | `calendar_live`                                      |

Known follow-ups (not blockers for v1):

- `queue_depth` currently reads from a
  `~/.zeroclaw/sync-state/queue_depth` marker file. A proper ZeroClaw
  HTTP endpoint will supersede this once it exposes one.
- `last_sync` and CalDAV `last_refresh` read from marker files under
  `~/.zeroclaw/sync-state/` written by the sync paths. Missing markers
  are treated as "never synced" rather than errors.

## Configuration

The four backend URL defaults below assume a single-machine deploy where
the API server, the storage backends (Qdrant, Oxigraph), the embedding
Ollama, and the wiki all run on the same host. For a networked Hub +
compute split – where the storage and compute live on a separate
machine on the LAN – set each variable to the compute machine's
hostname or LAN IP. There is no implicit network topology baked into
the defaults; every customer override is explicit.

| Env var               | Default                      | Notes                              |
| --------------------- | ---------------------------- | ---------------------------------- |
| `QDRANT_URL`          | `http://localhost:6333`      | Vector store. Override for Hub+compute splits. |
| `OXIGRAPH_URL`        | `http://localhost:7878`      | RDF triple store. Override for Hub+compute splits. |
| `EMBED_OLLAMA_URL`    | `http://localhost:11434`     | Embedding model host. Override for Hub+compute splits. |
| `WIKI_BASE_URL`       | `http://localhost:8044`      | Used for wiki link generation. Override for Hub+compute splits. |
| `EMBED_MODEL`         | `nomic-embed-text`           |                                    |
| `MAX_POST_BYTES`      | `1048576` (1 MB)             | POST body cap.                     |
| `TIMEZONE`            | `UTC`                        | IANA name; override for non-UTC users. |
| `INGEST_DIR`          | `~/.zeroclaw/ingest`         | iOS batch landing zone.            |
| `OSTLER_DB_KEY`       | unset                        | Required to read encrypted coach DB. |
| `OSTLER_PYTHON`       | unset (skips Ostler bridge)  | Path to Ostler venv python; unset disables the bridge. |
| `OSTLER_PROJECT_DIR`  | unset (skips Ostler bridge)  | Path to Ostler project root; unset disables the bridge. |
