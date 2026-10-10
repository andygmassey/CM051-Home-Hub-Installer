# email_ingest — divergence NOT captured by the patch

**Hand-written 2026-10-10 (Archie, candidate #17, walk #16 console F8).**

`scripts/regenerate_divergence_patch.sh email_ingest --write` REFUSED, measured
2026-10-10 against an HR015 checkout holding the pinned sha 1bb0a0db: upstream
`email-ingest` has moved past the pin, and regenerating would fold those
upstream commits into the patch as if they were local edits. The pin has to
move first (`scripts/sync_vendor.sh`) and the graft be re-applied. Until then
this file records the edit, location and shape only.

## The edit

- `vendor/email_ingest/bin/email-ingest-tick.sh`, immediately after the
  `log "ingested $MBOX successfully"` line: a new block that counts the
  messages in this tick's mbox (`grep -c '^From '`) and calls
  `ostler_fda.settling_progress.report_settling_progress("emails", ...)` with
  the CUMULATIVE count (previous shard `done` + this tick) and a total
  measured once from `~/Library/Mail/**/*.emlx`. `needs_source` is always
  false. Best effort: a failure logs a WARNING and never fails the tick.

Why: the hourly agent is what reads the customer's mail, and it never wrote
the settling shard, so the panel kept the install-time pass's "nothing found"
while 12,339 emails were processed (walk #16 box).

Test: `tests/test_settling_emails_tells_the_truth.sh` arm 4 runs this tick for
real (two ticks of 3 messages -> done 6). Upstream port: HR015 email-ingest.
