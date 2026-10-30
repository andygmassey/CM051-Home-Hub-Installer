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
