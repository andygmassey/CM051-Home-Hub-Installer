# cm041/meeting_syncer: unrecorded divergence

## Nineteenth graft: forgotten attendee (Lane 18)

Tree `cm041/meeting_syncer`, file `vendor/cm041/meeting_syncer/syncer.py`,
function `MeetingSyncer._resolve_attendee`: when `resolver.resolve` returns
match_type `forgotten` the attendee is neither linked nor re-created and the
function returns None (the caller already skips a None). Grafted from CM041
#200 (`cb98e00`) with the diff applied unchanged; not yet on CM041 main, so it
is not in `meeting_syncer.patch`. See the Nineteenth graft in
cm041_assistant_api.UNRECORDED.md. Retire by landing CM041 #200 and re-pinning.
