# cm041/meeting_syncer: one edit the patch tool REFUSED to record

**2026-10-30, v1.0.121 second batch. Location and shape only, never content.**

Tree `cm041/meeting_syncer`, pin `f2ef7891`. Pin HELD. The tree otherwise stays
described by `cm041_meeting_syncer.patch`; this file covers ONE edit that the
patch does not contain.

## The edit

`vendor/cm041/meeting_syncer/brief.py`, function `_get_outstanding_todos`
(and its docstring): the SPARQL gains `OPTIONAL { ?todo urn:ostler:privacyLevel ?plevel }`
and `FILTER (!BOUND(?plevel) || REGEX(STR(?plevel), "^[ \\t]*[Ll][0-2][ \\t]*$"))`, so a todo is
returned to the emailed brief only if it has NO privacyLevel (legacy, kept as
before) or its level is exactly L0, L1 or L2 (trim, case insensitive). L3 and
anything unparseable or unexpected (an IRI, "3", garbage) is withheld, the same
fail-closed rule as the commitments API. The filter is in the query so `LIMIT`
counts only surviving rows.

Why: CM048's writer already refuses to store L3 todos, but the reader did not
check, so L3 safety rested on one writer. This is the second line of defence.

## The refusal

`CM041=<worktree at f2ef7891> scripts/regenerate_divergence_patch.sh cm041/meeting_syncer`
(dry run) printed the proposed change. The `--write` run with
`VENDOR_PATCH_REGEN_CONFIRM=cm041/meeting_syncer` then refused: "the new patch
does not APPLY to source@f2ef7891", and restored the previous patch
byte for byte. The cause was NOT diagnosed in this change. Nothing was
published, no shipped byte depends on the patch.

## Upstream

Canonical CM041 `origin/main` has the same reader
(`meeting_syncer/brief.py:371 _get_outstanding_todos`, no privacyLevel in the
query) and the same `commitments_list` in `assistant_api/ical-server.py`. No
canonical PR is raised now. Retire this record by re-pinning past an upstream
fix, or by regenerating the patch once the apply failure is understood.

Test: `tests/cm048_vendored_sweep/test_l3_todo_readers_defence.py`.

## 2026-11-03 v1.0.122 (fix122_l3out): brief meeting history and last conversation withhold L3

Tree `cm041/meeting_syncer`. Pin HELD.

- `brief.py` `_get_meeting_history`: selects the meeting's `pwg:privacyLevel` and the attendee's, and drops a row when `pwg_privacy.is_l3` says hide (most-restrictive of the two; nothing parseable on either axis is hidden). Same rule as `_get_person_facts`.
- `brief.py` `_get_last_conversation_id`: selects the fact's `urn:ostler:privacyLevel`, drops L3 / untagged / unparseable facts IN PYTHON, then takes the newest. The `LIMIT 1` is removed so an L3 fact cannot mask a visible one. The vendored query is the plain default-graph form (the allow-list scope is applied by `_sparql_query`'s caller path); upstream's wraps the same body in `read_across_graphs`.
- Why: the brief is emailed; both readers fed it with no filter (audit scratch/p1_scoped.evidence.txt).
- Proof: `tests/test_vendored_brief_outbound_l3.py` (stock brief.py: 8 fail, 1 pass; fixed: 9 pass).
- Upstream: CM041 PR for the same change (branch fix122/l3-outbound). Retire this section when a re-pin brings it in.
