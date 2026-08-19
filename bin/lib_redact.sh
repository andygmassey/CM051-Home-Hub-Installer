# bin/lib_redact.sh -- the outbound redactor for gate output. Sourced, not run.
#
# WHY THIS EXISTS. A `runs-on=box` gate executes on a CUSTOMER's machine and
# can read their graph. Whatever it prints is echoed verbatim by
# rollforward_gate.sh into the cut log, the CI log, and any pasted diagnostic.
# The D658 gate really did print contact phone numbers next to real names.
# Gate authors should print shape, not values -- this is the second line of
# defence, not permission to skip the first.
#
# THE PREDICATE, and why it is shaped this way.
#
# The first cut of this redacted any run of 8+ characters drawn from
# `[0-9 ()._-]`, which ate `2026-08-10` and turned every date in a failure
# report into `<number-redacted>`. Four separate over-matching regexes were
# written across this cut before anyone tested one against an ISO date.
#
# The obvious repair -- require a literal `+`, or require 7+ CONSECUTIVE
# digits -- fixes the dates and silently opens a hole: `07700 900123` and
# `(020) 7946 0958` both stop being redacted. In a leak guard a false
# negative is a leak and a false positive is a cosmetic annoyance, so trading
# the first for the second is the wrong direction.
#
# The rule that satisfies both:
#
#   A SEPARATED group of digits is redacted only when it carries a telephone
#   prefix -- a leading `+`, or a national trunk `0` followed by a digit.
#   An UNSEPARATED run of 7 or more digits is always redacted.
#
# A date is separated and carries neither prefix (`2026-` starts with `2`,
# and its longest unbroken digit run is 4), so it survives all four rules by
# construction rather than by luck. A version (`0.4.50`), a clock
# (`02:31:00`), a loopback (`127.0.0.1`) and a row count (`42`) survive for
# the same reason.
#
# The digit-run rule needs a boundary on BOTH sides, not just the left. With
# only a left boundary it redacted the leading seven characters of the short
# SHA `8076740a` and left the `a` dangling. Its own SURVIVE case caught that
# on the first run of the suite below.
#
# The known cost: an unseparated 8-digit datestamp such as `20260810`, and a
# short commit SHA that happens to be all digits, are over-redacted. Those
# are genuinely indistinguishable from a tightly-formatted number, so they
# are the deliberate side of the trade -- see redact_selftest.sh, which
# asserts them rather than leaving them to be rediscovered as a defect.
#
# Any change to these four rules must be accompanied by a new case in
# bin/redact_selftest.sh, which rollforward_gate.sh runs before it will
# evaluate a single gate.

redact() {
	sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email-redacted>/g' \
	    | sed -E 's/(^|[^0-9A-Za-z+])\+[0-9][0-9 ()._-]{6,}[0-9]/\1<number-redacted>/g' \
	    | sed -E 's/(^|[^0-9A-Za-z])0[0-9][0-9 ().-]{5,}[0-9]/\1<number-redacted>/g' \
	    | sed -E 's/(^|[^0-9A-Za-z])[0-9]{7,}([^0-9A-Za-z]|$)/\1<number-redacted>\2/g'
}
