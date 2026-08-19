#!/usr/bin/env bash
# tests/test_vendored_register_pii.sh
# ============================================================================
# The vendored defect register must not carry person-identifying strings.
#
# WHY THIS EXISTS, AND WHY IT LIVES IN CM051 RATHER THAN OS003
# ------------------------------------------------------------
# 2026-08-11. CM051 #569 vendored cuts/DEFECTS_ROLLFORWARD.md out of OS003 into
# THIS repo, which is the shipping repo. Both agents scanned it first. Both
# reported clean. Both were wrong, in two different ways, and the merge landed
# two real wiki People page slugs on CM051 main.
#
#   probe 1  grep -c Surname                -> 0    CASE-SENSITIVE. The
#                                                   surviving forms are
#                                                   lowercase slugs.
#   probe 2  \b[A-Z][a-z]{2,} [A-Z][a-z]{2,}\b -> no hit. A name-SHAPED regex
#                                                   CANNOT match a lowercase
#                                                   hyphenated page slug by
#                                                   construction: no capital, no
#                                                   space.
#
# Neither instrument was broken. The claim hung on them -- "there is no PII
# here" -- was a different question from the one they answered. Two blind
# probes, and the intersection was reported as evidence.
#
# It lives HERE, in the destination, on purpose. OS003 fixing its own register
# is necessary and is happening. But CM051 accepted whatever OS003 handed it,
# so a single source-side miss became a shipping-repo leak in one merge with no
# second opinion. Two repos, two independent guards, neither trusting the
# other's clean bill.
#
# THE PREDICATE, AND WHY IT IS THIS ONE
# -------------------------------------
# Measured on the register at 8e23140b before writing this:
#
#   hyphenated *.md slug tokens: 8, distinct: 4
#     3x + 3x a near-duplicate pair, 1x + 1x a family pair. All four real.
#
# Every single one is a wiki People page. Zero technical noise -- no
# README-style or kebab-cased tooling filename appears in that shape anywhere in
# the file. So `[a-z]+(-[a-z]+)+\.md` is a high-precision person-page detector
# for this document, which makes a permit-list tractable rather than
# theoretical: today it should be EMPTY, because all four should be gone.
#
# PERMIT-LIST, NOT DENYLIST (feedback_a_denylist_cannot_catch_a_leak_it_has_never_seen).
# Names are not banned by enumeration. Every candidate must be DECLARED in
# cuts/REGISTER_PII_REVIEWED.tsv with a reason recording why it is not a real
# person. Forgetting a row produces a RED, so you cannot forget one quietly.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTER="$HERE/cuts/DEFECTS_ROLLFORWARD.md"
REVIEWED="$HERE/cuts/REGISTER_PII_REVIEWED.tsv"

fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

scan() {   # $1 = file. Emits one candidate per line. CASE-INSENSITIVE by
           # lowercasing first, so a capitalised variant cannot slip past the
           # slug arm and a lowercase one cannot slip past the bigram arm.
	python3 - "$1" <<'PY'
import re, sys, unicodedata
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Fold anything that can break a word boundary between name parts. An
# emoji-decorated bigram defeated a previous sweep; that hole stays closed.
folded = "".join(
    ch if (unicodedata.category(ch)[0] in ("L", "N") or ch in " \t\n_-.'/\\\"(),:;=#+@[]{}<>|*&%$!?")
    else " "
    for ch in unicodedata.normalize("NFKC", raw)
)
low = folded.lower()
out = set()
# arm 1: wiki People page slugs. The form that leaked.
for m in re.finditer(r"\b([a-z][a-z0-9]*(?:-[a-z][a-z0-9]*)+)\.md\b", low):
    out.add("slug:" + m.group(1))
# arm 2: person-shaped bigrams, matched on the FOLDED+LOWERED text so
# capitalisation is irrelevant to detection.
#
# LOOKAHEAD, BECAUSE finditer DOES NOT OVERLAP. The plain form
#     r"\b([a-z]{3,})[ \t]+([a-z]{3,})\b"
# consumes both words, so scanning "and a plain Marigold Sputterhaven bigram"
# yields "plain marigold" and "sputterhaven bigram" and NEVER the actual name
# in the middle. A bigram scanner built that way misses any name that does not
# happen to land on an even word boundary -- about half of them, silently.
# Caught by this file's own positive control on 2026-08-11, which is the
# argument for making the control run before the verdict.
for m in re.finditer(r"(?=\b([a-z]{3,})[ \t]+([a-z]{3,})\b)", low):
    out.add("name:" + m.group(1) + " " + m.group(2))
print("\n".join(sorted(out)))
PY
}

echo "vendored register: person-identifying strings"

# ---------------------------------------------------------------------------
# CONTROL FIRST. An instrument that cannot show its reach has not earned a
# verdict. Canaries are written to a scratch file and never committed; each is
# a shape that actually defeated a real sweep on 2026-08-11.
# ---------------------------------------------------------------------------
probe="$(mktemp)"
{
	echo 'proposed predicate  3  <- zzzcanary-quillfeather.md, timeline.md'
	# A LITERAL emoji, not an escape. `echo` inside single quotes writes
	# \U0001F33C as six characters, so the first version of this canary
	# contained no emoji at all and "failed" against a working instrument.
	# A canary that does not carry the shape it is testing for proves nothing.
	echo 'a decorated value "🌼Vondelmar🌼 Thistlewick" appears here'
	echo 'and a plain Marigold Sputterhaven bigram'
} > "$probe"
got="$(scan "$probe")"
for want in "slug:zzzcanary-quillfeather" "name:vondelmar thistlewick" "name:marigold sputterhaven"; do
	case "$got" in
		*"$want"*) pass "control: detects ${want%%:*} form (${want#*:})" ;;
		*) fail "control: MISSED $want -- instrument is blind, no verdict is trustworthy" ;;
	esac
done
if grep -q "slug:zzzcanary-quillfeather" <<<"$got"; then :; fi
# NEGATIVE control: it must not invent hits.
case "$got" in
	*"never-written"*) fail "negative control fired -- the scanner invents matches" ;;
	*) pass "negative control: does not report what was never written" ;;
esac
rm -f "$probe"

if [ "$fails" -gt 0 ]; then
	echo ""
	echo "REFUSING to report a register verdict: the instrument failed its own controls."
	exit 1
fi

# ---------------------------------------------------------------------------
# SELF-SCAN. A gate whose positive control carries the thing it hunts IS the
# leak (feedback_a_gates_positive_control_must_not_carry_the_thing_it_hunts).
# Every slug in THIS file must be a declared canary.
# ---------------------------------------------------------------------------
self_slugs="$(scan "${BASH_SOURCE[0]}" | grep '^slug:' || true)"
stray_self="$(grep -v 'zzzcanary-quillfeather' <<<"$self_slugs" | grep -v '^$' || true)"
if [ -z "$stray_self" ]; then
	pass "self-scan: this file carries no undeclared person-page slug"
else
	fail "self-scan: THIS FILE carries a person-page slug -- the gate is the leak"
	sed 's/^/        /' <<<"$stray_self"
fi

# ---------------------------------------------------------------------------
# The register itself. Slug arm only is enforced as RED: it is high-precision
# here (4/4 measured) and it is the form that leaked. The bigram arm is
# reported for review rather than enforced, because English prose produces
# thousands of lowercase bigrams and an unusable gate gets deleted.
# ---------------------------------------------------------------------------
[ -f "$REGISTER" ] || { fail "vendored register not found at $REGISTER"; exit 1; }

declare_ok() {   # $1 = slug ; declared iff present with a non-empty reason
	[ -f "$REVIEWED" ] || return 1
	awk -F'\t' -v s="$1" '$1 == s && $2 != "" { found = 1 } END { exit !found }' "$REVIEWED"
}

undeclared=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	slug="${line#slug:}"
	if declare_ok "$slug"; then
		pass "declared fictional: $slug.md"
	else
		fail "UNDECLARED person-page slug in the register: $slug.md"
		undeclared=$((undeclared + 1))
	fi
done < <(scan "$REGISTER" | grep '^slug:' || true)

if [ "$undeclared" -eq 0 ]; then
	pass "register carries no undeclared person-page slug"
fi

echo ""
if [ "$fails" -gt 0 ]; then
	printf '\033[0;31mvendored register PII: %d FAILED\033[0m\n' "$fails"
	echo "Fix it in OS003 and re-sync (scripts/sync_rollforward_registry.sh)."
	echo "Do NOT edit the vendored copy -- the pin test will go red and the fix"
	echo "would be lost on the next sync."
	echo "If a slug is genuinely fictional, declare it WITH A REASON in"
	echo "  cuts/REGISTER_PII_REVIEWED.tsv"
	exit 1
fi
printf '\033[0;32mvendored register PII: clean\033[0m\n'
