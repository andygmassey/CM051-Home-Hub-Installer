# cm041/meeting_syncer: unrecorded divergence

## Nineteenth graft: forgotten attendee (Lane 18)

Tree `cm041/meeting_syncer`, file `vendor/cm041/meeting_syncer/syncer.py`,
function `MeetingSyncer._resolve_attendee`: when `resolver.resolve` returns
match_type `forgotten` the attendee is neither linked nor re-created and the
function returns None (the caller already skips a None). Grafted from CM041
#200 (`cb98e00`) with the diff applied unchanged; not yet on CM041 main, so it
is not in `meeting_syncer.patch`. See the Nineteenth graft in
cm041_assistant_api.UNRECORDED.md. Retire by landing CM041 #200 and re-pinning.

---

## Calendar source points at the real, token-gated API (status-honesty sweep V20)

`vendor/cm041/meeting_syncer/config.py`: `CALENDAR_API_URL` defaults to
`http://127.0.0.1:8090/api/v1` (the ical-server), not the Doctor on :8089 which
does not serve the calendar. `vendor/cm041/meeting_syncer/calendar_client.py`:
`fetch_events` sends the loopback service token (`PWG_SERVICE_TOKEN`,
`OSTLER_SERVICE_TOKEN`, or `~/.ostler/secrets/service_token`) and raises a
`CANNOT-RUN` error naming the URL on a 401/403, instead of an opaque HTTP error.

### What a future sync must preserve

The :8090 default, the bearer header and the named refusal. Guarded by
`tests/test_meeting_briefs_say_when_they_cannot_run.py` (workflow
`status-honesty-meetings-doctor.yml`).
