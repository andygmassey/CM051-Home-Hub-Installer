# meeting_syncer/brief.py output schema

Pinned wire shape that `pre_meeting_brief()` returns and the Hub
`GET /api/v1/meeting/upcoming` endpoint serves. Downstream consumers
(iOS Companion `MeetingBriefService`, CM051 cron sender for WhatsApp
delivery) must keep parity with this schema.

## Top-level

`pre_meeting_brief(days=N)` returns a list of meeting briefs, one
per upcoming calendar event with at least one non-operator attendee.

```jsonc
[
  {
    "meeting": "Discovery call with Alice",
    "start": "2026-05-30 10:30 BST",
    "start_iso": "20260530T103000",
    "end_iso": "20260530T113000",
    "uid": "cal-event-uid-abc123",
    "location": "Mortimer House, 37 Mortimer St, London",
    "maps_url": "https://www.google.com/maps/search/?api=1&query=Mortimer+House%2C+37+Mortimer+St%2C+London",
    "attendees": [
      {
        "name": "Alice Tester",
        "email": "alice@example.com",
        "wiki_url": "http://localhost:8044/People/alice-tester/",
        "organization": "Acme Ltd",
        "relationship": "Investor",
        "facts": [
          "Prefers async written communication before calls",
          "Working on a B2B saas in supply-chain visibility"
        ],
        "times_met": 4,
        "last_met": "2026-04-12",
        "last_discussion_id": "2026-04-12_alice_zoom",
        "last_discussion_url": "http://localhost:8044/Conversations/2026-04-12_alice_zoom/",
        "outstanding_todos": [
          {
            "text": "Send the pitch deck",
            "owner": "user",
            "owner_display": "Operator",
            "deadline": "2026-05-30",
            "priority": "high",
            "source_conversation_date": "2026-04-12",
            "days_overdue": 3
          }
        ]
      }
    ]
  }
]
```

## Field contracts

### Meeting level

| Field         | Type   | Required | Notes |
| ------------- | ------ | -------- | ----- |
| `meeting`     | string | yes      | Calendar event summary. `"(no title)"` when missing. |
| `start`       | string | yes      | Human-formatted start time from calendar source. May be empty. |
| `start_iso`   | string | yes      | iCal-style start (`YYYYMMDDTHHMMSS`). May be empty. |
| `end_iso`     | string | no       | iCal-style end / DTEND (`YYYYMMDDTHHMMSS`), mirroring `start_iso`. Present only when the calendar event carries an end. Consumed by the CM058 Notch for an in-progress "ends in N min" countdown. Absent (not empty) for all-day / open-ended events and older calendar payloads without an end. |
| `uid`         | string | yes      | Calendar event UID -- the idempotency key for the cron sender. May be empty for ad-hoc events. |
| `location`    | string | yes      | Raw location string from the calendar (may be empty for online meetings). |
| `maps_url`    | string | yes      | Google Maps deep link, or empty string when `location` is empty / whitespace. |
| `attendees`   | array  | yes      | At least one non-operator attendee (briefs with zero are filtered out at source). |

### Attendee level

| Field                  | Type    | Required | Notes |
| ---------------------- | ------- | -------- | ----- |
| `name`                 | string  | yes      | Display name (may be the email when no display name). |
| `email`                | string  | yes      | Calendar attendee email. |
| `wiki_url`             | string  | yes      | Pre-computed `People/<slug>/` URL. Always present (even for unknown attendees, so the operator can click into the wiki and create the page). Empty when both name and email are missing. |
| `organization`         | string  | no       | From People Graph; absent when attendee is unknown. |
| `relationship`         | string  | no       | From People Graph; absent when attendee is unknown. |
| `facts`                | array   | no       | Strings extracted from CM048 facts; absent when attendee is unknown. |
| `times_met`            | int     | no       | Count of past Meeting triples; absent when attendee is unknown. |
| `last_met`             | string  | no       | ISO date (`YYYY-MM-DD`) of the most recent past meeting. |
| `last_discussion_id`   | string  | no       | Conversation ID of the most recent ingested conversation referencing this person. |
| `last_discussion_url`  | string  | yes      | Wiki link to the most recent conversation page. Empty string when no conversation has been ingested for this person yet. |
| `outstanding_todos`    | array   | yes      | List of open `pwg:OutstandingTodo` triples cross-linked to this attendee (capped at 5 per attendee). Empty array when none. |
| `known`                | boolean | no       | Set to `false` only when the attendee was not resolved against the People Graph. Absent for resolved attendees. |

### Outstanding todo level

| Field                       | Type   | Required | Notes |
| --------------------------- | ------ | -------- | ----- |
| `text`                      | string | yes      | The action item itself, verbatim from the enrichment table. |
| `owner`                     | string | yes      | `"user"`, `"other:<slug>"`, or the unowned sentinel (em-dash). |
| `owner_display`             | string | yes      | Human-readable owner; may match `owner` when no resolved display. |
| `deadline`                  | string | yes      | ISO date string (`YYYY-MM-DD`) or empty. |
| `priority`                  | string | yes      | `"high"` / `"medium"` / `"low"` or empty. |
| `source_conversation_date`  | string | yes      | ISO date of the source conversation. |
| `days_overdue`              | int    | no       | Whole days the todo is past `deadline`. Present only when strictly overdue (a deadline of yesterday reads as `1`); absent for on-time, not-yet-due, undated, or unparseable deadlines. Consumed by the CM058 Notch as the overdue cue-card trigger. |

## Empty-state contract

- A meeting with zero non-operator attendees is dropped from the list
  (never returned as `attendees: []`).
- An attendee unknown to the People Graph has `known: false` and
  carries only `name`, `email`, `wiki_url`, `outstanding_todos: []`,
  `last_discussion_url: ""`.
- `outstanding_todos: []` and `last_discussion_url: ""` are the
  empty-state markers (not `null`); JSON decoders on the iOS side
  treat absent keys as decoding failures.
- `end_iso` (meeting level) and `days_overdue` (todo level) are
  OPTIONAL Notch cues: they are absent rather than empty / `null` /
  `0` when there is nothing to show, so a decoder that does not know
  them is unaffected and the Notch never lights up for a not-yet-due
  item or an open-ended event.

## Versioning

This schema is v1.0. Backwards-compatible additions (new OPTIONAL
fields, absent when not applicable):

- `end_iso` (meeting level) and `days_overdue` (todo level) added for
  the CM058 Notch cue card (CM058#1 producer half). Both optional and
  omitted when not applicable, so existing consumers are unaffected.

Future changes:

- `v1.0.1` may add a `closed_todos_count` summary alongside
  `outstanding_todos` once the v1.0.1 closure pass lands.
- `v1.1` may add per-attendee `recent_emails` if Andy locks the
  cross-channel surface.

Add new fields rather than renaming existing ones. Removing a field
requires a deprecation period of at least one minor version.
