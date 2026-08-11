#!/usr/bin/env bash
# bin/rollforward_gate.sh -- addresses v1018-D026. Queue item 2.
#
# Reads the gate registry in cuts/DEFECTS_ROLLFORWARD.md and runs it. This is
# the thing .github/workflows/cut.yml calls before a single byte is signed.
#
# THE CONTRACT (Archie, 2026-08-09 03:38), enforced not documented:
#   ```gate id=<ledger-id> expect=<int> runs-on=<box|artefact|repo>
#   ...plain sh, read-only, idempotent...
#   ```
#   - id must resolve to a real ledger entry     -> unknown id is a PARSE ERROR
#   - a defect section with no gate block        -> PARSE ERROR, never a skip
#   - one gate per id                            -> duplicate id is a PARSE ERROR
#   - runs-on=repo carries the D028 freshness assertion, applied MECHANICALLY
#
# WHY PARSE ERRORS RATHER THAN SKIPS. A skipped gate reports the same colour as
# a passing one. That is how cut-freshness sat red for eight days across three
# NO-SHIPped cuts without anyone noticing (D029), and how v1.0.18 shipped 13/13
# green with 20 defects. Anything this script cannot positively evaluate is a
# failure, loudly, with the id that caused it.
#
# MODES, chosen by what the environment can honestly prove:
#   --verify-claims  parse + claim coverage, no gate body runs. The CI half.
#   --cut <tag>      everything, including box gates. Needs the sibling
#                    checkouts and GATE_BOX=user@host. The operator half.
#   --list           enumerate the gates. --only <id> run exactly one.
#
# EXIT: 0 all gates met expectation. 1 one or more failed. 2 registry is
# malformed -- which is a cut blocker in its own right, not a warning.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${ROLLFORWARD_REGISTRY:-$HERE/cuts/DEFECTS_ROLLFORWARD.md}"
CUT=""
ONLY=""
LIST_ONLY=0
VERIFY_CLAIMS=0

while [ $# -gt 0 ]; do
	case "$1" in
		--cut)      CUT="${2:-}"; shift 2 ;;
		--only)     ONLY="${2:-}"; shift 2 ;;
		--list)     LIST_ONLY=1; shift ;;
		--verify-claims) VERIFY_CLAIMS=1; shift ;;
		--registry) REGISTRY="${2:-}"; shift 2 ;;
		-h|--help)
			sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

[ -f "$REGISTRY" ] || { red "PARSE ERROR: registry not found: $REGISTRY"; exit 2; }

# The outbound redactor is what stands between a customer's graph and this
# script's output, so it is proved before a gate is allowed to produce any.
# Its first two versions were both wrong in opposite directions -- one ate
# every ISO date, the next stopped redacting `07700 900123` -- and neither
# had a test. A redactor that cannot pass its own suite means this script
# cannot report a failure safely, so that is a hard stop, not a warning.
# shellcheck source=bin/lib_redact.sh
. "$HERE/bin/lib_redact.sh"
if ! selftest_out="$(bash "$HERE/bin/redact_selftest.sh" 2>&1)"; then
	red "PARSE ERROR: the outbound redactor failed its own self-test"
	printf '%s\n' "$selftest_out"
	dim "Refusing to run gates: failure output cannot be redacted safely."
	exit 2
fi

# ---------------------------------------------------------------------------
# Pass 1 -- parse. Nothing runs until the whole registry is known good, so a
# malformed row cannot hide behind twenty green ones that ran before it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Pass 0 -- CLAIM COVERAGE. Every row that claims to be FIXED must have a gate.
#
# The parse below enforces section <-> gate pairing rigorously, and on
# 2026-08-10 it reported 20 sections and 20 gates with zero mismatches. It was
# still blind: the roll-forward TABLE carried 26 rows, 15 of them with no gate
# at all, and SEVEN of those claiming `fixed_in_v1.0.19`.
#
# Nothing was broken. The check simply did not cover the assertion anyone
# actually reads. A row saying "fixed" is the strongest claim in this file and
# it was the one thing nothing verified -- including D003, whose row claimed
# fixed while its own PR was still open and 23 commits behind main.
#
# The rule is deliberately ONE-SIDED, because the two cases are not alike:
#
#   a row claiming `fixed_in_*` / `measured_in_*`  -> MUST have a gate
#   a row that is `open`, or names an owner        -> may have none
#
# Nobody is asserting the second kind is done, so there is nothing to falsify.
# Requiring a gate there would only manufacture ceremony. Requiring one for a
# fixed-claim is the whole point: it is the difference between saying a thing
# is repaired and being able to show it.
# ---------------------------------------------------------------------------
claim_errors=0
# The set of ids that ACTUALLY claim to be fixed. Pass 1 needs the same set,
# because the two passes must not disagree about which rows owe a gate.
claiming_ids=""
while IFS=$'\t' read -r cid cstatus; do
	[ -n "$cid" ] || continue
	claiming_ids="$claiming_ids $cid"
	if ! grep -q "^\`\`\`gate id=$cid " "$REGISTRY"; then
		red "CLAIM ERROR: $cid says \"$cstatus\" and has no gate block"
		claim_errors=$((claim_errors + 1))
	fi
done <<EOF
$(awk -F'|' '
  NF > 4 {
    # EXTRACT the id, do not require the cell to BE the id. Rows carry
    # bold markers and severity emoji, and an anchored full match silently
    # skipped three of the eight rows this check exists to catch -- the
    # same over-strict-pattern class as D001 and D014c.
    if (!match($2, /v1018-D[0-9]+/)) next
    id = substr($2, RSTART, RLENGTH)
    st = $NF; gsub(/^[ \t]+|[ \t]+$/, "", st)
    if (st == "") { st = $(NF-1); gsub(/^[ \t]+|[ \t]+$/, "", st) }
    if (st ~ /^(fixed_in|measured_in|verified_in)/) print id "\t" st
  }' "$REGISTRY")
EOF
if [ "$claim_errors" -gt 0 ]; then
	red "ROLLFORWARD RED -- $claim_errors row(s) claim to be fixed with nothing that could prove it"
	dim "Add a gate, or change the claim. A status is not evidence."
	dim "Rows that are open or owner-assigned are exempt: they assert nothing."
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

parse_errors=0
perr() { red "PARSE ERROR: $1"; parse_errors=$((parse_errors + 1)); }

awk -v outdir="$work" -v claiming="$claiming_ids" '
	/^### / {
		# Close any section that OWES a gate and ended without one. Narrative
		# headings ("From v1.0.18", table intros) are not defect entries and
		# must not be forced to carry a gate -- demanding one there would
		# generate false parse errors and get the whole check disabled, which
		# is how a strict gate becomes no gate at all.
		#
		# OWING A GATE IS DECIDED BY THE ROW STATUS, NOT BY THE HEADING SHAPE.
		# This pass used to flag every `### v1018-Dxxx` section, which
		# contradicted the rule Pass 0 states above in this same file:
		#
		#     a row claiming `fixed_in_*`  -> MUST have a gate
		#     a row that is `open`         -> may have none
		#
		# D018 is the case that exposed it. That row is open, it asserts
		# nothing, and it carries a narrative section explaining precisely why
		# it is deliberately ungated -- which is the behaviour we want to
		# encourage, not punish. Pass 1 called that a PARSE ERROR, and one
		# parse error refuses the whole run, so writing an honest explanation
		# for an open defect disabled all 27 gates at once. Measured
		# 2026-08-11: with the claim-coverage error cleared, the run died on
		# D018 alone.
		#
		# So the two passes now read the SAME set. A section owes a gate iff
		# its id is a row that claims to be fixed.
		if (section != "" && owes_gate && !seen_gate) print section > (outdir "/nogate.txt")
		section = $0; sub(/^### /, "", section); seen_gate = 0
		owes_gate = 0
		if (match(section, /v[0-9]+-D[0-9]+/)) {
			sid = substr(section, RSTART, RLENGTH)
			owes_gate = (index(" " claiming " ", " " sid " ") > 0)
		}
		next
	}
	/^```gate/ {
		seen_gate = 1
		hdr = $0
		id = ""; expect = ""; runson = ""
		n = split(hdr, parts, /[ \t]+/)
		for (i = 2; i <= n; i++) {
			split(parts[i], kv, "=")
			if (kv[1] == "id")      id = kv[2]
			if (kv[1] == "expect")  expect = kv[2]
			if (kv[1] == "runs-on") runson = kv[2]
		}
		printf "%s\t%s\t%s\t%s\n", id, expect, runson, section >> (outdir "/gates.tsv")
		body = (id == "" ? "__noid__" : id)
		infence = 1
		next
	}
	infence && /^```[ \t]*$/ { infence = 0; next }
	infence { print $0 >> (outdir "/body." body ".sh") }
	# Same condition as the /^### / branch above, and it MUST stay the same.
	# It did not: this END block omitted is_defect, so a narrative heading in
	# the LAST position -- an appendix, a closing note -- was reported as a
	# section missing its gate. One parse error refuses the whole run, so
	# adding an appendix to the register disabled every gate at once. That is
	# precisely the outcome the comment above warns about. Latent only
	# because the file happens to end on a defect that has a gate.
	END { if (section != "" && owes_gate && !seen_gate) print section > (outdir "/nogate.txt") }
' "$REGISTRY"

# A defect section with no gate is a parse error, never a silent skip.
if [ -s "$work/nogate.txt" ]; then
	while IFS= read -r s; do
		perr "section has no gate block: '$s' (a section without a gate reads as covered)"
	done < "$work/nogate.txt"
fi

[ -f "$work/gates.tsv" ] || { perr "no gate blocks found in $REGISTRY"; exit 2; }

# Structural validation of every header, plus id-resolves-to-a-ledger-entry.
seen_ids=""
while IFS=$'\t' read -r id expect runson section; do
	[ -n "$id" ]     || { perr "gate in section '$section' has no id="; continue; }
	[ -n "$expect" ] || perr "[$id] missing expect="
	[ -n "$runson" ] || perr "[$id] missing runs-on="
	case "$expect" in ''|*[!0-9]*) perr "[$id] expect must be an integer, got '$expect'" ;; esac
	case "$runson" in
		box|artefact|repo) : ;;
		*) perr "[$id] runs-on must be box|artefact|repo, got '$runson'" ;;
	esac
	case " $seen_ids " in
		*" $id "*) perr "[$id] duplicate gate -- one gate per ledger entry, so a row is binary" ;;
		*) seen_ids="$seen_ids $id" ;;
	esac
	# Unknown id = orphan gate. It would run forever against a defect nobody
	# tracks, and its colour would mean nothing.
	#
	# THE ID MUST RESOLVE SOMEWHERE OTHER THAN ITS OWN FENCE. The obvious
	# `grep -q "$id" "$REGISTRY"` is circular: the gate header contains the id,
	# so the search always succeeds and the check can never fail. That is the
	# always-passes defect this whole script exists to catch, and I wrote it
	# into the catcher. Caught by the negative control, which is the argument
	# for negative controls.
	#
	# Resolution means a defect SECTION heading or a ledger TABLE row.
	if ! grep -qE "^### ${id}([^0-9]|$)" "$REGISTRY" \
	   && ! grep -qE "^\| *\*{0,2}${id}\*{0,2} *\|" "$REGISTRY"; then
		perr "[$id] does not resolve to a ledger entry (no '### $id' section, no table row)"
	fi
	[ -s "$work/body.$id.sh" ] || perr "[$id] gate body is empty -- an empty gate always passes"
done < "$work/gates.tsv"

if [ "$parse_errors" -gt 0 ]; then
	echo ""
	red "REGISTRY MALFORMED: $parse_errors parse error(s). Refusing to run."
	dim "A gate we cannot evaluate is not a gate that passed."
	exit 2
fi

total=$(wc -l < "$work/gates.tsv" | tr -d ' ')

# THE TERMINAL MARKER, PRINTED BEFORE THE MODES DIVERGE.
#
# It used to sit below, after --list had already exited, so `--list` announced
# nothing. gates.yml's ratchet requires one of two markers as proof the script
# ran to completion -- "registry parsed clean" or "ROLLFORWARD RED" -- and in
# --list mode it only ever saw the second one, because Pass 0 was failing and
# printed it on the way past. The guard was reading a FAILURE message as proof
# of completion. Clear the claim error and the same guard false-REDs on a
# perfectly good run, which is what happened the moment D021 was corrected.
#
# A completion marker that is only emitted on the failure path is not a
# completion marker. Every mode that gets this far has parsed the registry, so
# every mode says so, once, here.
echo "rollforward gate: $total gate(s), registry parsed clean${CUT:+, cut $CUT}"
echo ""

if [ "$LIST_ONLY" -eq 1 ]; then
	printf '%-16s %-8s %-10s %s\n' ID EXPECT RUNS-ON SECTION
	while IFS=$'\t' read -r id expect runson section; do
		printf '%-16s %-8s %-10s %s\n' "$id" "$expect" "$runson" "$section"
	done < "$work/gates.tsv"
	exit 0
fi

# ---------------------------------------------------------------------------
# --verify-claims -- the half of this gate that a hosted CI runner can actually
# perform. It stops HERE, before a single gate body executes, and it says so.
#
# WHY THIS MODE EXISTS. `--cut` was wired into CM051's .github/workflows/cut.yml
# as the pre-signing gate. It can never pass there, by construction, and it
# never once did: measured 2026-08-11 on the v1.0.19 tag push, the first and
# only run of that workflow. Of 27 gates, 15 are `runs-on=box` and print
# UNRUNNABLE without a real Mini on the other end of GATE_BOX, and 8 more go RED
# purely because CM051_DIR / OA_DIR / CM044_DIR / OS003_DIR name sibling
# checkouts that do not exist on a hosted runner. A gate that cannot pass is not
# strict, it is decorative, and a decorative gate is what v1018-D026 exists to
# abolish.
#
# So the work is split by what each environment can honestly prove:
#
#   CI, on every tag push      --verify-claims  registry parses; no row claims
#                                               to be fixed without a gate
#   Operator, before tagging   --cut            the gate bodies actually run
#   Box-walk, on the Mini      --cut GATE_BOX=  the 15 box gates actually run
#
# The first is cheap, total, and catches the exact failure that let v1.0.18 ship
# 13/13 green with 20 open defects: a status standing in for evidence. It does
# NOT claim the defects are fixed, and it prints that limitation every run so no
# reader can mistake a green here for a green product.
# ---------------------------------------------------------------------------
if [ "$VERIFY_CLAIMS" -eq 1 ]; then
	green "rollforward claims: 0 unproven fixed-claims across $total gate(s)"
	dim "PROVEN HERE:     every row claiming fixed_in_*/measured_in_*/verified_in_*"
	dim "                 carries a gate block, and every gate header is well-formed."
	dim "NOT PROVEN HERE: whether those gates PASS. No gate body ran."
	dim "                 Run '$(basename "${BASH_SOURCE[0]}") --cut <tag>' with the sibling"
	dim "                 checkouts present, and GATE_BOX=user@host for the box gates."
	exit 0
fi

# --only must resolve, for the same reason a gate id must. Line 11 of this file
# already says "unknown id is a PARSE ERROR" -- that rule was applied to ids
# found IN the registry and not to the id passed ON THE COMMAND LINE. A typo, a
# renamed row or a stale invocation selected nothing, ran nothing, and printed
#
#     ROLLFORWARD GREEN -- 0 gate(s) met expectation      exit 0
#
# It even printed the zero. That is the vacuous pass this script exists to
# prevent, in the script itself. Measured 2026-08-10 with a synthetic registry:
# --only on a real id exits 0/1 correctly; --only on an unknown id exits 0 green.
if [ -n "$ONLY" ] && ! cut -f1 "$work/gates.tsv" | grep -qxF "$ONLY"; then
	red "PARSE ERROR: --only '$ONLY' matches no gate in the registry."
	dim "Running nothing and reporting green is how a skipped gate becomes a passing one."
	dim "Known ids:"
	cut -f1 "$work/gates.tsv" | sed 's/^/  /'
	exit 2
fi

# ---------------------------------------------------------------------------
# Pass 2 -- run.
# ---------------------------------------------------------------------------
failed=0
ran=0
skipped_env=0

_tree_is_current() {
	# One checkout. $1 is the env-var name, for a message that says which
	# knob to turn; $2 is the path.
	local name="$1" repo="$2" head behind
	git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
		echo "    freshness: \$$name ($repo) is not a git repo"; return 1; }
	git -C "$repo" fetch -q origin 2>/dev/null || true
	# Derive the default branch rather than assume main -- a wrong guess
	# here yields "unknown", which used to be treated as a pass.
	head="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
	[ -n "$head" ] || head="origin/main"
	git -C "$repo" rev-parse --verify -q "$head" >/dev/null 2>&1 || {
		echo "    freshness: \$$name ($repo) has no $head to compare against"; return 1; }
	behind="$(git -C "$repo" rev-list --count "HEAD..$head" 2>/dev/null)"
	case "$behind" in
		''|*[!0-9]*)
			echo "    freshness: \$$name ($repo) -- could not count commits behind $head"
			return 1 ;;
	esac
	[ "$behind" -eq 0 ] || {
		echo "    freshness: \$$name ($repo) is $behind commit(s) behind $head"; return 1; }
	return 0
}

for_repo_freshness() {
	# v1018-D028, applied mechanically rather than trusted to gate authors.
	# A repo-scoped gate reading a stale tree draws confident conclusions
	# about code that moved. One checkout here was 78 commits behind with an
	# entire design system missing while `git status` said clean.
	#
	# 2026-08-10: this checked ONLY ${GATE_REPO:-$PWD} -- the OS003 repo that
	# holds the ledger. The trees the repo gates actually READ are named by
	# CM051_DIR / CM044_DIR / OS003_DIR, and none of them were checked. So
	# the guard confirmed the ledger was current and then let D027, D032 and
	# D034 issue verdicts -- two of them GREEN -- about a CM051 checkout five
	# commits behind origin/main. Demonstrated before this change.
	#
	# Every tree a repo gate can reach is checked now. Unset variables are
	# skipped: a gate that does not read CM044 must not be blocked by
	# CM044_DIR being absent, and a body that needs one says so itself via
	# ${CM044_DIR:?...}.
	# Checked ONCE per run, not once per gate: this fetches, and eight repo
	# gates across four trees is 32 network round-trips for one answer that
	# cannot change mid-run.
	#
	# The memo lives in a FILE, not a shell variable. The caller invokes this
	# as `msg="$(for_repo_freshness 2>&1)"` -- a command substitution, which
	# is a SUBSHELL -- so any variable this function sets is discarded the
	# moment it returns. The first version memoised into `_FRESHNESS_VERDICT`
	# and the cache therefore never hit once: every repo gate re-fetched all
	# four trees, exactly the cost the memo existed to avoid, while looking
	# like it worked. Caught re-reading my own diff.
	local memo="$work/.freshness" ok=0 name path detail="" msg
	if [ -f "$memo" ]; then
		ok="$(head -1 "$memo")"
		[ "$ok" = "0" ] || tail -n +2 "$memo"
		return "$ok"
	fi
	# OA_DIR added 2026-08-10 for v1018-D002, whose stated acceptance is a
	# test in ostler-assistant. Unset is SKIPPED, same as the others, so
	# adding it cannot break a run that does not need it -- and a gate that
	# does need it says so itself via ${OA_DIR:?...}.
	for name in GATE_REPO CM051_DIR CM044_DIR OS003_DIR OA_DIR; do
		eval "path=\${$name:-}"
		[ -n "$path" ] || continue
		if ! msg="$(_tree_is_current "$name" "$path")"; then
			ok=1; detail="${detail}${msg}
"
		fi
	done
	# The ledger repo itself, always, whether or not GATE_REPO is set.
	if ! msg="$(_tree_is_current PWD "$PWD")"; then
		ok=1; detail="${detail}${msg}
"
	fi
	{ printf '%s\n' "$ok"; printf '%s' "$detail"; } > "$memo"
	[ "$ok" = "0" ] || printf '%s' "$detail"
	return "$ok"
}

while IFS=$'\t' read -r id expect runson section; do
	[ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue

	printf '  %-16s %-9s ' "$id" "[$runson]"

	# Environment preconditions. A gate that cannot run must say so as a
	# FAILURE of the run, not as a pass -- but we distinguish it in the
	# summary so "no box" is not confused with "defect present".
	case "$runson" in
		box)
			if [ -z "${GATE_BOX:-}" ]; then
				red "UNRUNNABLE (set GATE_BOX=user@host)"
				skipped_env=$((skipped_env + 1)); failed=$((failed + 1)); continue
			fi ;;
		artefact)
			if [ -z "${GATE_ARTEFACT:-}" ]; then
				red "UNRUNNABLE (set GATE_ARTEFACT=/path/to/mounted.dmg)"
				skipped_env=$((skipped_env + 1)); failed=$((failed + 1)); continue
			fi ;;
		repo)
			if ! msg="$(for_repo_freshness 2>&1)"; then
				red "UNRUNNABLE (stale checkout, v1018-D028)"
				printf '%s\n' "$msg"
				skipped_env=$((skipped_env + 1)); failed=$((failed + 1)); continue
			fi ;;
	esac

	body="$work/body.$id.sh"
	if [ "$runson" = "box" ]; then
		# A NON-INTERACTIVE ssh shell does not source the login profile, so it
		# has no Homebrew PATH. `docker` is a Homebrew binary on the Hub, so
		# every box gate that shells out to it was running "command not
		# found" instead of its check. What each one then REPORTED depended
		# only on which boolean operator it happened to use:
		#
		#   v1018-D010  ... && { echo FAIL; exit 1; }  -> command fails,
		#               the && never fires, falls through to `exit 0`.
		#               GREEN. It could not report its defect at ALL.
		#   v1018-D016  ... || { echo FAIL; exit 1; }  -> RED always, with a
		#               product message it had not earned.
		#
		# D010 is the one the registry cites as the model negative control
		# ("pre-fix -> RED, fixed -> GREEN, shown in CM044 #171"). That was
		# demonstrated in a shell that HAD docker on PATH. The control was
		# real; the environment it was proved in was not the one it runs in.
		#
		# Prepending the two standard Homebrew prefixes is not an inferred
		# host fact: they are Homebrew's documented locations (Apple Silicon
		# and Intel), both appended to whatever the box already has, and
		# nothing hard-fails if either is absent.
		out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$GATE_BOX" \
			'PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" sh -s' < "$body" 2>&1)"; rc=$?
	else
		out="$(GATE_ARTEFACT="${GATE_ARTEFACT:-}" sh "$body" 2>&1)"; rc=$?
	fi
	ran=$((ran + 1))

	if [ "$rc" -eq "$expect" ]; then
		green "GREEN (rc=$rc)"
	else
		red "RED (rc=$rc, expected $expect)"
		# v1018-D658 follow-up. THIS LINE IS A PII AMPLIFIER.
		#
		# A runs-on=box gate executes on a CUSTOMER's machine and can read
		# their graph. Whatever it prints, this echoes verbatim into the cut
		# log, the CI log and any pasted diagnostic. The D658 gate did print
		# contact phone numbers next to real names until it was fixed -- and
		# this line is what would have carried them off the box.
		#
		# Fixing the gate was necessary; relying on every future gate author
		# to remember is not a control. Redact identifier-shaped strings on
		# the way out, so a careless gate cannot leak through the harness.
		# Gate authors should still print shape, not values -- this is the
		# second line of defence, not permission to skip the first.
		#
		# The predicate lives in bin/lib_redact.sh and is proved by
		# bin/redact_selftest.sh, which this script runs at startup. It is
		# not inlined here because a leak guard written in the middle of an
		# error path is a leak guard nobody tests.
		printf '%s\n' "$out" | redact | sed 's/^/      /'
		failed=$((failed + 1))
	fi
done < "$work/gates.tsv"

echo ""
if [ "$failed" -eq 0 ]; then
	green "ROLLFORWARD GREEN -- $ran gate(s) met expectation"
	exit 0
fi
red "ROLLFORWARD RED -- $failed of $total gate(s) failed ($skipped_env unrunnable)"
dim "A cut does not proceed past this. Fix the defect or fix the gate; do not"
dim "edit the expectation to match the failure."
exit 1
