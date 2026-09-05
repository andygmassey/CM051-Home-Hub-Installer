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
#   - a row that CLAIMS fixed and has no gate    -> CLAIM ERROR, never a skip
#   - one gate per id                            -> duplicate id is a PARSE ERROR
#   - runs-on=repo carries the D028 freshness assertion, applied MECHANICALLY
#
# READ THIS BEFORE TIGHTENING LINE 12. It used to read "a defect section with no
# gate block -> PARSE ERROR", and that is NOT what this script does, deliberately.
# Owing a gate is decided by the ROW STATUS, not by the heading shape: a row that
# claims fixed_in_* must carry a gate, a row that is still open may carry none.
# The broad rule was enforced once and D018 -- an open row whose section honestly
# explains why it is ungated -- tripped it, and because one parse error refuses
# the whole run, writing that honest explanation disabled all 27 gates at once.
# Measured 2026-08-11. The long comment at the /^### / branch below is the full
# account. Tightening this back to "every ### v1018-Dxxx section owes a gate"
# reintroduces that outage.
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
REQUIRE_WALK_CLOSURE=0

# A value-taking option whose value is MISSING must be a usage error, never a
# spin.
#
# The previous form was `CUT="${2:-}"; shift 2`. When the option is the LAST
# argument there is no $2, so `${2:-}` quietly yields empty -- and then
# `shift 2` FAILS, because you cannot shift 2 off a 1-element list. A failed
# shift does not decrement $#, so `[ $# -gt 0 ]` stays true and the loop runs
# forever, re-reading the same $1.
#
# Measured 2026-08-11: `rollforward_gate.sh --cut` (no version) ran for 7m15s
# at 100.0% CPU with ZERO bytes of output and no child processes, and had to be
# killed. A `bash -x` trace showed the three-line cycle repeating without end:
#
#     + case "$1" in
#     + CUT=
#     + shift 2
#
# Three options were affected -- --cut, --only, --registry -- so any of them
# passed last-without-value hung the operator half of the gate. The
# `${2:-}` default is what hides it: it makes the missing value LOOK handled,
# which is why this survived review. Silence plus a default is not error
# handling.
#
# This matters beyond the typo: --cut is how the 15 runs-on=box gates are
# executed before a cut, so the one mode that could not report is the one that
# walks the box.
need_val() {   # $1 = option name, $2 = remaining arg count
	[ "$2" -ge 2 ] && return 0
	echo "error: $1 requires a value (e.g. $1 v1.0.23)" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--cut)      need_val --cut "$#";      CUT="$2"; shift 2 ;;
		--only)     need_val --only "$#";     ONLY="$2"; shift 2 ;;
		--list)     LIST_ONLY=1; shift ;;
		--verify-claims) VERIFY_CLAIMS=1; shift ;;
		--require-walk-closure) REQUIRE_WALK_CLOSURE=1; shift ;;
		--registry) need_val --registry "$#"; REGISTRY="$2"; shift 2 ;;
		-h|--help)
			sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

[ -f "$REGISTRY" ] || { red "PARSE ERROR: registry not found: $REGISTRY"; exit 2; }

# ---------------------------------------------------------------------------
# --require-walk-closure -- #867 limb 3. THE ANTI-VACUITY LIMB.
#
# Andy's rule, 2026-08-23: THE NEXT DMG HE WALKS CONTAINS EVERY FIX FROM THE
# WALK BEFORE IT. The rest of this script already enforces the half that has
# teeth once a row EXISTS: a row claiming fixed must carry a gate, a gate must
# resolve, an unknown id is a parse error. What it could not see was the row
# that was never written.
#
# 🔴 MEASURED 2026-08-23, WITH THE MATCHER ALREADY UNPINNED BY LIMB 1:
#
#     bash bin/rollforward_gate.sh --verify-claims
#       rc=0   "0 unproven fixed-claims across 28 gate(s)"
#     versions the registry carries:     v1018 and nothing else
#     rows for any cut after v1.0.18:    0        (we are cutting v1.0.41)
#
# Green over an empty denominator, in the one gate whose whole job is stopping
# a defect riding forward into the next cut. Limb 1 made a later row VISIBLE;
# it could not make an ABSENT one fail.
#
# 🔴 AND "THE WALK BEFORE IT" IS NOT "THE CUT BEFORE IT". The first version of
# this mode derived the preceding walk from the newest directory in cuts/, i.e.
# the last cut MADE. The shipping ledger says the last cut actually WALKED was
# v1.0.36, four cuts back. A gate that assumes every cut was walked would have
# demanded closure of a walk that never happened, and -- worse -- would have
# said nothing at all about the three cuts in between. SILENTLY SKIPPING IS THE
# DEFECT; it cannot be part of the fix.
#
# So the table accounts for EVERY cut in scope, and a cut that was not walked
# says so over a name:
#
#   ## WALKS
#
#   walk_horizon: v1.0.41
#
#   | cut | walked_on | status | approver | findings |
#   |---|---|---|---|---|
#   | v1.0.41 | 2026-08-22 | closed |  | v1041-D001 v1041-D002 |
#
# WHY A HORIZON. Requiring a row for every cut ever made would mean writing 18
# rows of history nobody measured, which is fabrication wearing the format of a
# record. The horizon declares the first cut the table accounts for. Below it,
# nothing is claimed. From it upward, NOTHING MAY BE SILENT. The horizon is
# itself required: a missing one is RED, because "no horizon" and "horizon
# above everything" are the same vacuous pass.
#
# WHAT BLOCKS:
#   1. no ## WALKS table, no rows, or no walk_horizon   -> RED. Absence is not closure.
#   2. any cut in [horizon, CUT) with no row            -> RED, and names them.
#   3. status not closed / deferred / not_walked        -> RED. Unknown is never a pass.
#   4. deferred or not_walked with no named approver    -> RED. No anonymous waivers,
#                                                          the rule reconcile_gates.sh
#                                                          already applies to gates.
#   5. a row whose findings do not EQUAL the registry
#      sections for that walk                           -> RED, printing both sides.
#
# (5) is the limb that stops the other four being satisfied by typing the word
# closed. Row and sections verify each other: a section the row forgot is
# caught, and a finding with no section is caught. Retracted sections
# (### ~~vNNNN-Dxxx~~) are excluded deliberately -- the real registry carries
# one, v1018-D034, retracted 2026-08-09 when both dedupe fixes turned out to
# have shipped. A retraction is a finding WITHDRAWN, and counting it would
# force an operator to list a defect that does not exist.
#
# WHICH cuts/ DIRECTORY. Same trap the --cut binder documents above: this file
# runs in TWO repos and $HERE resolves differently in each. OS003's cuts/ is
# the operator record and is sparse (11 version dirs); CM051's is the pin
# record and is contiguous (18, v1.0.24 to v1.0.41). So the run PRINTS the
# directory it read, the horizon, and every cut in scope. A verdict whose
# denominator is invisible is the failure this mode exists to refuse, and it
# would be absurd to commit it here.
#
# EXIT: 0 every cut in scope is accounted for. 1 one or more is not, which is a
# cut blocker. 2 CANNOT-RUN: no cuts/ directory, no version directories. Nothing
# has been found wrong with the cut in the rc=2 case and it must not be reported
# as a defect -- but it still blocks, because a blind spot is not a pass.
# ---------------------------------------------------------------------------
if [ "$REQUIRE_WALK_CLOSURE" -eq 1 ]; then
	[ -n "$CUT" ] || {
		red "CANNOT-RUN: --require-walk-closure needs --cut <tag> to know which cuts are in scope"
		exit 2
	}

	_wc_compact() {  # v1.0.41 -> v1041, matching the vNNNN-Dxxx id convention
		printf 'v%s\n' "$(printf '%s' "${1#v}" | tr -d '.')"
	}

	# ROLLFORWARD_CUTS_DIR exists so the test can hand this mode a controlled
	# set of version directories, exactly as ROLLFORWARD_REGISTRY already does
	# for the registry. It is resolved HERE, per invocation, NOT at script load:
	# the CM051 BOM freshness gate shipped with its pin resolved at load, which
	# made every env override in its own self-test inert and all six cases pass
	# against the real files. A green that cannot be moved by its own fixture is
	# measuring nothing. The resolved path is printed on every run, so a
	# redirected scope is visible in the log rather than inferable from it.
	wc_cuts_dir="${ROLLFORWARD_CUTS_DIR:-$HERE/cuts}"
	[ -d "$wc_cuts_dir" ] || {
		red "CANNOT-RUN: no cuts/ directory at $wc_cuts_dir"
		dim "This mode derives the cuts in scope from the version directories there."
		exit 2
	}

	# ---------------------------------------------------------------------
	# THE STATUS COLUMN IS DERIVED FROM AN ARTEFACT, NOT TAKEN ON TRUST.
	#
	# CM051 #978 introduced walks/<version>.tsv, written by
	# scripts/post_walk_qa.sh after it has driven the box-walk probes against a
	# real installed box. That file is the only RUNTIME evidence in the release
	# pipeline: everything else measures the artefact, and all of it passes on a
	# DMG that installs to a broken machine.
	#
	# Until now this mode read `status` as typed. TWO REGISTERS OF ONE FACT is
	# this estate's signature failure, and the one an artefact writes must win.
	# So a record, where one exists, decides which statuses are LEGAL:
	#
	#   record verdict CLEAN   -> the row must say `closed`. It was walked and
	#                             it was clean; `not_walked` is now a false
	#                             statement contradicted by an artefact.
	#   FAILED or PARTIAL      -> `closed` or `deferred`. Not `not_walked`.
	#   no record for that cut -> `closed` is REFUSED. A walk claimed closed
	#                             with nothing written by the walker is exactly
	#                             the silence this mode exists to refuse.
	#
	# The row still carries the approver and the findings, because a record
	# cannot know either. What it can no longer do is CLAIM a walk that left no
	# trace, or deny one that did.
	#
	# WHERE THERE IS NO walks/ DIRECTORY AT ALL, the derivation is UNAVAILABLE
	# and every row says so, on every run. That is the honest state for the
	# OS003 operator half, which has no walks/; CM051 -- where the shipping cut
	# actually runs this gate -- has one. A reader must be able to tell a status
	# that was DERIVED from one that was taken on trust, so the verdict line
	# says which.
	# ---------------------------------------------------------------------
	wc_walks_dir="${OSTLER_WALKS_DIR:-$HERE/walks}"

	wc_versions="$(ls -1 "$wc_cuts_dir" 2>/dev/null | grep -E '^v[0-9]+(\.[0-9]+)+$' || true)"
	[ -n "$wc_versions" ] || {
		red "CANNOT-RUN: $wc_cuts_dir holds no version directories"
		dim "Nothing to scope against. Refusing rather than assuming the scope is empty."
		exit 2
	}

	# grep -c, NOT `printf '%s' ... | wc -l`. printf without a trailing newline
	# leaves the last line unterminated and wc -l counts TERMINATORS, so the
	# first version of this line said 10 against 11 real directories. A count
	# that is quietly one short is worse than no count: it is the number the
	# reader trusts to decide whether the gate looked in the right place.
	dim "walk-closure: registry   $REGISTRY"
	dim "walk-closure: cuts dir   $wc_cuts_dir ($(printf '%s\n' "$wc_versions" | grep -c . || true) version dirs)"
	dim "walk-closure: starting   $CUT"

	# --- the WALKS table ---------------------------------------------------
	wc_horizon="$(awk '
		/^##[[:space:]]+WALKS[[:space:]]*$/ { inw = 1; next }
		/^##[[:space:]]/                    { inw = 0 }
		inw && /^walk_horizon:/ { v = $0; sub(/^walk_horizon:[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit }
	' "$REGISTRY" || true)"

	wc_rows="$(awk '
		/^##[[:space:]]+WALKS[[:space:]]*$/ { inw = 1; next }
		/^##[[:space:]]/                    { inw = 0 }
		inw && /^\|/                        { print }
	' "$REGISTRY" | grep -vE '^\|[[:space:]]*-{2,}' | tail -n +2 || true)"

	if [ -z "$wc_rows" ] || [ -z "$wc_horizon" ]; then
		red "WALK CLOSURE RED -- the registry has no usable ## WALKS table."
		[ -n "$wc_horizon" ] || dim "  missing: walk_horizon"
		[ -n "$wc_rows" ]    || dim "  missing: any row"
		dim "An absent table is the vacuous pass this mode exists to refuse. Every"
		dim "cut from the horizon upward gets a row, including a cut nobody walked"
		dim "(status=not_walked over a name) and a walk that found nothing"
		dim "(findings=none). Add to $REGISTRY:"
		dim ""
		dim "  ## WALKS"
		dim ""
		dim "  walk_horizon: $CUT"
		dim ""
		dim "  | cut | walked_on | status | approver | findings |"
		dim "  |---|---|---|---|---|"
		exit 1
	fi

	dim "walk-closure: horizon    $wc_horizon"

	# Cuts in scope: horizon <= v < CUT. sort -V puts the ordering beyond doubt
	# for 1.0.9 against 1.0.10, which a lexical sort gets backwards.
	wc_scope="$(printf '%s\n' "$wc_versions" | sed 's/^v//' | sort -V | while IFS= read -r v; do
			# Ordering by sort -V, decided pairwise, because awk cannot compare
			# dotted versions and a numeric coercion turns 1.0.9 into 1.
			lo="$(printf '%s\n%s\n' "${wc_horizon#v}" "$v" | sort -V | head -1)"
			hi="$(printf '%s\n%s\n' "$v" "${CUT#v}" | sort -V | head -1)"
			[ "$lo" = "${wc_horizon#v}" ] || continue
			[ "$hi" = "$v" ] && [ "$v" != "${CUT#v}" ] || continue
			printf 'v%s\n' "$v"
		done)"

	if [ -z "$wc_scope" ]; then
		red "WALK CLOSURE RED -- no cut directory falls in [$wc_horizon, $CUT)."
		dim "Either the horizon is above every cut that exists, which makes this"
		dim "mode vacuous, or $CUT is not ahead of the horizon. Both are refusals:"
		dim "a scope of zero is the shape of the defect, not a clean bill."
		dim "Version dirs seen: $(printf '%s' "$wc_versions" | tr '\n' ' ')"
		exit 1
	fi

	dim "walk-closure: in scope   $(printf '%s\n' "$wc_scope" | grep -c . || true) cut(s): $(printf '%s' "$wc_scope" | tr '\n' ' ')"

	wc_field() {  # wc_field <row> <1-based cell index>
		printf '%s\n' "$1" | awk -F'|' -v n="$(( $2 + 1 ))" '{ v = $n; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v }'
	}

	wc_bad=0
	while IFS= read -r wc_cut; do
		[ -n "$wc_cut" ] || continue
		wc_id="$(_wc_compact "$wc_cut")"
		# 🔴 A HERE-STRING, NOT A PIPE, AND THE REASON IS A MEASURED FALSE RED.
		#
		# This was `printf '%s\n' "$wc_rows" | awk ... exit`. The awk EXITS on
		# the first match, which closes the pipe while printf is still writing.
		# printf takes EPIPE, returns non-zero, `pipefail` promotes it, and the
		# `||` below fires -- reporting NO ROW for a row awk had just FOUND and
		# PRINTED.
		#
		# MEASURED in CI on the v1.0.69 tag, twice, deterministically:
		#
		#   bin/rollforward_gate.sh: line 322: printf: write error: Broken pipe
		#     v1.0.41  NO ROW. A cut with no row is indistinguishable from...
		#
		# one such pair per failing row, eight of them, for rows that are
		# demonstrably present in the file.
		#
		# ⚠️ IT DID NOT REPRODUCE LOCALLY, on macOS OR in an ubuntu:24.04
		# container running this exact gate against this exact registry, where
		# it returns GREEN. The rows blob is ~55KB and a pipe buffer is 64KB, so
		# the producer usually finishes before the reader exits and there is no
		# EPIPE to take. THE BUG IS LATENT UNTIL THE REGISTER OUTGROWS THE PIPE
		# BUFFER, and it gets more likely with every walk row added -- which is
		# the worst possible failure mode for a gate that guards a release.
		#
		# This is the same defect as `grep -q` SIGPIPEing its producer, recorded
		# in CM051 #1131; `awk ... exit` is playing the part of `-q`. A
		# here-string has no producer process, so there is nothing to signal and
		# the early exit stays a pure optimisation.
		wc_row="$(awk -F'|' -v want="$wc_cut" '
			{ c = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); if (c == want) { print; found = 1; exit } }
			END { exit !found }
		' <<<"$wc_rows")" || {
			red "  $wc_cut  NO ROW. A cut with no row is indistinguishable from a cut nobody looked at."
			wc_bad=$((wc_bad + 1))
			continue
		}

		wc_status="$(wc_field "$wc_row" 3)"
		wc_approver="$(wc_field "$wc_row" 4)"
		wc_findings="$(wc_field "$wc_row" 5)"

		case "$wc_status" in
			closed) ;;
			deferred|not_walked)
				if [ -z "$wc_approver" ]; then
					red "  $wc_cut  status '$wc_status' with NO named approver. An anonymous waiver is one nobody signed."
					wc_bad=$((wc_bad + 1))
					continue
				fi ;;
			*)
				red "  $wc_cut  status '$wc_status' is neither closed, deferred nor not_walked. Unknown is never a pass."
				wc_bad=$((wc_bad + 1))
				continue ;;
		esac

		# --- derive against the walk record ---------------------------
		wc_rec="$wc_walks_dir/$wc_cut.tsv"
		wc_derived="UNVERIFIED"
		if [ ! -d "$wc_walks_dir" ]; then
			wc_derived="UNAVAILABLE(no $wc_walks_dir)"
		elif [ -f "$wc_rec" ]; then
			wc_rec_verdict="$(awk -F'\t' '$1=="verdict"{print $2; exit}' "$wc_rec" 2>/dev/null)"
			wc_rec_version="$(awk -F'\t' '$1=="version"{print $2; exit}' "$wc_rec" 2>/dev/null)"
			if [ "$wc_rec_version" != "$wc_cut" ]; then
				red "  $wc_cut  walk record names version '$wc_rec_version', not $wc_cut. A record's FILENAME is not evidence, its contents are."
				wc_bad=$((wc_bad + 1))
				continue
			fi
			case "$wc_rec_verdict" in
				CLEAN)
					if [ "$wc_status" != "closed" ]; then
						red "  $wc_cut  row says '$wc_status' but the walk record says CLEAN. It WAS walked; an artefact contradicts the row."
						wc_bad=$((wc_bad + 1))
						continue
					fi ;;
				FAILED|PARTIAL)
					if [ "$wc_status" = "not_walked" ]; then
						red "  $wc_cut  row says not_walked but a walk record exists with verdict $wc_rec_verdict."
						wc_bad=$((wc_bad + 1))
						continue
					fi ;;
				*)
					red "  $wc_cut  walk record carries verdict '$wc_rec_verdict', which is not CLEAN, FAILED or PARTIAL. Unknown is never a pass."
					wc_bad=$((wc_bad + 1))
					continue ;;
			esac
			wc_derived="DERIVED(record=$wc_rec_verdict)"
		else
			if [ "$wc_status" = "closed" ]; then
				red "  $wc_cut  row says closed and there is NO walk record at $wc_rec. A walk claimed closed with nothing written by the walker is the silence this mode refuses."
				wc_bad=$((wc_bad + 1))
				continue
			fi
			wc_derived="DERIVED(no record)"
		fi

		wc_sections="$(grep -E '^### ' "$REGISTRY" | grep -v '~~' | grep -oE "${wc_id}-D[0-9]+" | sort -u || true)"
		if [ "$wc_findings" = "none" ]; then
			wc_claimed=""
		else
			wc_claimed="$(printf '%s' "$wc_findings" | tr ', ' '\n\n' | grep -E "^${wc_id}-D[0-9]+$" | sort -u || true)"
		fi

		if [ "$wc_claimed" != "$wc_sections" ]; then
			red "  $wc_cut  the row and the registry sections disagree."
			dim "      row claims  : ${wc_claimed:-<none>}"
			dim "      registry has: ${wc_sections:-<none>}"
			dim "      only in the registry (a finding the row forgot):"
			comm -13 <(printf '%s\n' "$wc_claimed") <(printf '%s\n' "$wc_sections") | sed 's/^/        /'
			dim "      only in the row (a finding with no section):"
			comm -23 <(printf '%s\n' "$wc_claimed") <(printf '%s\n' "$wc_sections") | sed 's/^/        /'
			wc_bad=$((wc_bad + 1))
			continue
		fi

		green "  $wc_cut  $wc_status${wc_approver:+ (approver: $wc_approver)}, $(printf '%s\n' "$wc_sections" | grep -c . || true) finding(s), all listed  [$wc_derived]"
	done <<WC_SCOPE_EOF
$wc_scope
WC_SCOPE_EOF

	if [ "$wc_bad" -gt 0 ]; then
		red "WALK CLOSURE RED -- $wc_bad cut(s) in [$wc_horizon, $CUT) are not accounted for."
		dim "Write the rows and the finding sections, then re-run. Do not raise the"
		dim "horizon to make this pass: the horizon exists so history nobody measured"
		dim "is not fabricated, not so a cut that WAS made can be stepped over."
		exit 1
	fi

	green "WALK CLOSURE GREEN -- every cut in [$wc_horizon, $CUT) is accounted for."
	dim "PROVEN HERE:     every cut directory from the horizon up to $CUT has a WALKS"
	dim "                 row; each row is closed, or deferred/not_walked over a NAME;"
	dim "                 and each row's findings EQUAL the registry sections for it."
	dim "NOT PROVEN HERE: that those findings are FIXED. That is --verify-claims"
	dim "                 (every fixed-claim carries a gate) and --cut (run the gates)."
	dim "                 Nor that anything BELOW $wc_horizon was ever walked."
	exit 0
fi

# ---------------------------------------------------------------------------
# --cut BINDS THE RUN TO THAT VERSION'S PINS. Until 2026-08-11 it bound nothing.
#
# `$CUT` was set at line 73 and read at exactly ONE place -- the header line, to
# print a label. No cut.env was ever sourced. Meanwhile the two repo-scoped
# gates that read a remote resolved their subject as `${OA_REF:-main}`, so they
# answered "is this fixed upstream today" while the cut needs "does this ship".
#
# Not theoretical. Measured on `06dda1b`, same script, three refs:
#
#   v1018-D038  oa main                       GREEN
#   v1018-D038  oa #299 base d6e141ac         RED   (all three limbs)
#   v1018-D038  daemon 782a6195  <- the pin   RED   (all three limbs)
#   v1018-D017  main / main                   GREEN
#   v1018-D017  782a6195 / af6d05b <- pins    RED   0 of 6 send paths scrub
#
# 782a6195 and af6d05b are the pins in cuts/v1.0.19/cut.env, whose own comment
# already said "this daemon predates oa #299 ... D038 therefore does NOT ship in
# v1.0.19". The gate went green anyway, because it never looked at the pin. The
# comment was correct and had no exit status.
#
# Population, so the size of this is not left to imagination: 27 gates, 12
# runs-on=repo, exactly 2 read a moving ref -- and those 2 were the only 2
# repo-scoped gates that passed.
#
# A VERSION THAT NAMES NO CUT IS A USAGE ERROR, not a label. The run records in
# cuts/gate-runs/ are named v1.0.23 and there is no cuts/v1.0.23/ to bind them
# to, which is precisely how a PASS came to be read as a statement about a cut.
# ---------------------------------------------------------------------------
if [ -n "$CUT" ]; then
	# -----------------------------------------------------------------------
	# WHICH cut.env. THIS RUNNER RUNS IN TWO REPOS AND ONLY ONE OF THEM HOLDS
	# THE PINS, so `$HERE/cuts/$CUT/cut.env` resolves a DIFFERENT DOCUMENT
	# depending on where it was invoked.
	#
	# This file is authored in OS003 and VENDORED into CM051 by CM051
	# scripts/sync_rollforward_registry.sh, which is where .github/workflows/
	# cut.yml invokes it before signing. So `$HERE` is the CM051 checkout for
	# the CI half and the OS003 checkout for the operator half.
	#
	# THE PINS DID NOT GO MISSING FROM v1.0.24. THEY MOVED, DELIBERATELY, ON
	# 2026-08-13, and this reader was not told. CM051's copy says so itself:
	#
	#     "the file the gate reads belongs in the repo the gate runs in,
	#      holding only the declared keys, beside the cut-manifest it is
	#      paired with. OS003's cuts/v1.0.24/cut.env stays as the operator's
	#      fuller record; this is the machine-readable half."
	#          -- CM051 cuts/v1.0.24/cut.env
	#
	# The same header records the alternative, tried and REVERTED: vendoring
	# OS003's cut.env files into CM051 worked and dragged 464 lines of operator
	# working-record across with them, four private box IPs and five
	# notarisation submission IDs included. The two copies are deliberately
	# different documents that happen to share a name, and OS003's carries local
	# paths (CM051_DIR, OSTLER_APP_PATH) that bin/cut.sh needs and this runner
	# must never adopt.
	#
	# So the count below is not "cuts that stopped pinning". Measured
	# 2026-08-21, both repos, which is the half a single-repo count cannot see:
	#
	#     cut            OS003 copy        CM051 copy
	#     v1.0.14.1      DAEMON_COMMIT     --            pre-split
	#     v1.0.15        DAEMON_COMMIT     --            pre-split
	#     v1.0.17        both              --            pre-split
	#     v1.0.18        both              --            pre-split
	#     v1.0.19        both              --            pre-split  <- worked example
	#     v1.0.24        NEITHER           both          split
	#     v1.0.25..37    no directory      both          split      <- 13 cuts
	#
	# Of the 14 cuts whose pins live in CM051, OS003 bound the correct pins for
	# ZERO. Thirteen it could not name at all -- `--cut v1.0.30` reported "names
	# no cut" about a cut that exists and has pins. The fourteenth it named and
	# bound nothing from.
	#
	# So the sources are ORDERED, and every bound key PRINTS THE FILE IT CAME
	# FROM. Authoritative first, local second: inside CM051 the two resolve to
	# the same file, and where they differ a stale operator record must never
	# outrank the pin the cut is actually made of.
	# -----------------------------------------------------------------------
	pin_sources=""   # newline-terminated, precedence order, files that EXIST
	pin_searched=""  # newline-terminated, every candidate considered
	_consider_pin_source() {
		local cand="${1:-}"
		[ -n "$cand" ] || return 0
		# De-dup: inside CM051, $CM051_DIR and $HERE name the same file, and
		# printing it twice would read as two independent confirmations.
		case "
$pin_searched" in
			*"
$cand
"*) return 0 ;;
		esac
		pin_searched="$pin_searched$cand
"
		if [ -f "$cand" ]; then
			pin_sources="$pin_sources$cand
"
		fi
		return 0
	}
	# An explicit override, for tests and for measuring a named pin file on
	# purpose.
	_consider_pin_source "${OSTLER_CUT_ENV:-}"
	# The authoritative half. CM051_DIR is NOT guessed: this repo's history is
	# full of gates that read a tree nobody named, and a wrong guess here binds
	# a real-looking pin from the wrong cut, which is worse than binding none.
	if [ -n "${CM051_DIR:-}" ]; then
		_consider_pin_source "$CM051_DIR/cuts/$CUT/cut.env"
	fi
	# The local copy. Authoritative when this runner IS the vendored copy in
	# CM051; the operator's record, and the only pin file that exists, for the
	# pre-split cuts (v1.0.14.1 .. v1.0.19) that predate CM051's series.
	_consider_pin_source "$HERE/cuts/$CUT/cut.env"

	# A version that names no cut is a usage error, not a label -- see the
	# banner above. It now takes ALL the candidate locations to earn that, so
	# `--cut v1.0.30` no longer reports "names no cut" about a cut that exists
	# and has pins, purely because they are in the other repo.
	if [ -z "$pin_sources" ]; then
		red "PARSE ERROR: --cut '$CUT' names no cut -- no cut.env for it in any known location."
		dim "A version label that binds no pins is how a repo gate ends up asserting main."
		dim "Searched, in precedence order:"
		while IFS= read -r _c; do
			[ -n "$_c" ] && dim "  $_c"
		done <<EOF
$pin_searched
EOF
		if [ -z "${CM051_DIR:-}" ]; then
			dim ""
			dim "CM051_DIR is UNSET, so the AUTHORITATIVE pin file was never looked for."
			dim "Cuts from v1.0.24 onward keep their machine-readable pins in CM051"
			dim "cuts/<tag>/cut.env, not here. Set CM051_DIR=/path/to/CM051 checkout."
		fi
		dim "Cuts with a cut.env in this checkout:"
		for d in "$HERE"/cuts/v*/cut.env; do
			[ -f "$d" ] || continue
			d="${d%/cut.env}"; dim "  ${d##*/}"
		done
		if [ -n "${CM051_DIR:-}" ]; then
			dim "Cuts with a cut.env in \$CM051_DIR:"
			for d in "$CM051_DIR"/cuts/v*/cut.env; do
				[ -f "$d" ] || continue
				d="${d%/cut.env}"; dim "  ${d##*/}"
			done
		fi
		exit 2
	fi

	# A file that exists and cannot be OPENED must not be read as a file that
	# declares nothing. Those are different facts with the same empty value.
	while IFS= read -r _c; do
		[ -n "$_c" ] || continue
		[ -r "$_c" ] || {
			red "PARSE ERROR: cut.env exists but is not readable: $_c"
			dim "An unreadable pin file binds empty, which is indistinguishable from a cut that pins nothing."
			exit 2
		}
	done <<EOF
$pin_sources
EOF

	# Read in a SUBSHELL, one key at a time.
	#
	# cut.env legitimately sets CM051_DIR, OSTLER_APP_PATH, GATE_BOX and others.
	# Sourcing it into THIS shell would silently redefine the runner's own
	# environment -- including the very *_DIR variables the freshness check
	# reads -- so a cut.env could quietly re-point the gates at other trees.
	# That is sharper now than when it was written: CM051_DIR is what LOCATES
	# the authoritative pin file, so a sourced cut.env could redirect the very
	# lookup that read it.
	#
	# Sourcing rather than grepping is deliberate: several pins carry a trailing
	# `# comment` on the assignment line (`CM051=af6d05b  # main tip ...`), which
	# the shell discards correctly and a cut -d= would hand back as part of the
	# value. `set +u` because cut.env is written for a permissive environment.
	#
	# Sets PIN_VALUE and PIN_SOURCE. rc 0 = bound; rc 1 = every source was read
	# and none declares this key, which is a real measurement and not the same
	# thing as not having looked.
	_cut_pin() {
		local key="$1" f v
		PIN_VALUE=""; PIN_SOURCE=""
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			v="$( set +u; . "$f" >/dev/null 2>&1; eval "printf '%s' \"\${$key:-}\"" )"
			if [ -n "$v" ]; then
				PIN_VALUE="$v"; PIN_SOURCE="$f"; return 0
			fi
		done <<EOF
$pin_sources
EOF
		return 1
	}

	# The mapping is DECLARED, not inferred from variable names. cut.env speaks
	# in artefacts (DAEMON_COMMIT); gate bodies speak in refs (OA_REF). Anything
	# not listed here is not a pin and must not be treated as one.
	OSTLER_PIN_OA=""; pin_src_oa=""
	if _cut_pin DAEMON_COMMIT; then OSTLER_PIN_OA="$PIN_VALUE"; pin_src_oa="$PIN_SOURCE"; fi
	OSTLER_PIN_CM051=""; pin_src_cm051=""
	if _cut_pin CM051; then OSTLER_PIN_CM051="$PIN_VALUE"; pin_src_cm051="$PIN_SOURCE"; fi
	export OSTLER_PIN_OA OSTLER_PIN_CM051

	# Print what actually bound, and WHERE FROM. "Which sha did this measure"
	# and "which file said so" are the two questions a cut record has to answer,
	# and this runner reads two files that share a name.
	echo "cut $CUT pins: DAEMON_COMMIT=${OSTLER_PIN_OA:-<absent>} CM051=${OSTLER_PIN_CM051:-<absent>}"
	[ -z "$pin_src_oa" ]    || dim "  DAEMON_COMMIT <- $pin_src_oa"
	[ -z "$pin_src_cm051" ] || dim "  CM051         <- $pin_src_cm051"

	# -------------------------------------------------------------------------
	# 🔴 A cut.env THAT BINDS NOTHING IS THE SAME DEFECT AS NO cut.env AT ALL.
	#
	# The check above catches a --cut naming no cut.env anywhere. It does not
	# catch a --cut that resolved one and got nothing out of it, and that is not
	# hypothetical: it is what `--cut v1.0.24` did from OS003 every time. Two
	# empty strings, printed as `<unset>`, and the run carried on against
	# whatever the working trees happened to be -- reporting the result as a
	# statement about that cut.
	#
	# `<unset>` IS THE PART THAT MATTERS. It reads as a measurement -- this cut
	# pins nothing -- and D017 and D038 then tell an operator who passed
	# `--cut v1.0.24` to "Run with --cut <version>". Line 134 already said "A
	# version label that binds no pins is how a repo gate ends up asserting
	# main", as a dim note under a condition this case never reached. Same
	# sentence, now load-bearing.
	#
	# AND THE REMEDY IS NOT "ADD THE KEYS HERE". Across the 20 cut.env files
	# that exist for this runner -- 6 in OS003, 14 in CM051 -- exactly ONE
	# declares neither pin, and it is OS003's v1.0.24: the operator's record for
	# the one cut whose machine-readable half moved. Pasting DAEMON_COMMIT and
	# CM051 into it would make this message go away and create a SECOND copy of
	# the pins, free to drift from the one the DMG is actually cut from. That is
	# the divergence CM051's header calls the fix that was not the fix.
	#
	# exit 2 = CANNOT-RUN, not 1: nothing has been found wrong with the cut. We
	# failed to look at it. Reporting that as a defect would send someone
	# hunting a problem that may not exist.
	if [ -z "$OSTLER_PIN_OA" ] && [ -z "$OSTLER_PIN_CM051" ]; then
		red "CANNOT RUN: --cut '$CUT' bound NO pins. Nothing was measured; this is neither RED nor GREEN."
		dim "A cut.env that declares neither DAEMON_COMMIT nor CM051 is not a cut"
		dim "that pins nothing -- it is the wrong copy. OS003's cuts/<tag>/cut.env"
		dim "is the operator's working record; the machine-readable pins live in"
		dim "CM051's cuts/<tag>/cut.env, beside the cut-manifest they pair with."
		dim "Running on would assert whatever the working trees happen to be and"
		dim "report it as a statement about $CUT."
		dim ""
		while IFS= read -r _c; do
			[ -n "$_c" ] || continue
			dim "Keys $_c DOES define:"
			( set +u; grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$_c" 2>/dev/null | tr -d '=' | sed 's/^/    /' )
		done <<EOF
$pin_sources
EOF
		dim ""
		if [ -z "${CM051_DIR:-}" ]; then
			dim "CM051_DIR is UNSET, so the authoritative file was never opened."
			dim "Set CM051_DIR=/path/to/CM051 checkout and re-run. Do NOT paste the"
			dim "keys into the file above: that is a second copy of the pins, free to"
			dim "drift from the one the DMG is cut from."
		else
			dim "Neither the authoritative copy nor the local one declares a pin for"
			dim "$CUT. Write them into CM051 cuts/$CUT/cut.env, where the cut reads"
			dim "them, or drop --cut and accept that the run says nothing about any"
			dim "particular cut."
		fi
		exit 2
	fi

	# ONE pin absent is a real outcome and a DIFFERENT one: the key is declared
	# nowhere for this cut. v1.0.14.1 and v1.0.15 are honestly like this. Say so
	# here rather than leave the reader to infer it from a CANNOT-RUN twenty
	# lines down whose advice the operator has already followed.
	if [ -z "$OSTLER_PIN_OA" ] || [ -z "$OSTLER_PIN_CM051" ]; then
		dim "  one pin is ABSENT -- declared in no cut.env read for $CUT. The gates"
		dim "  that need it will declare CANNOT-RUN: coverage you do not have,"
		dim "  not a finding about the product."
	fi
fi

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
    # THE VERSION IS A WILDCARD, DELIBERATELY. This read /v1018-D[0-9]+/
    # until 2026-08-23, which pinned the whole claim check to ONE cut. A row
    # from any later walk -- v1019-, v1041- -- was stepped over by next
    # before its status was ever read, so the registry could be fed rows for
    # every cut since and this check would still report zero claim errors.
    # Same over-strict-pattern class the comment above names: the predicate
    # was widened for bold markers and emoji and left pinned on the VERSION,
    # one layer up. A check that can only see one cut of rows cannot enforce
    # that the next DMG carries the previous walk fixes. HR015 task 867.
    #
    # ONLY the version part is widened. The id shape after it is byte-for-
    # byte what it was, so every existing row extracts exactly as before:
    # v1018-D012b still yields v1018-D012, because no gate block declares a
    # lettered id -- measured, 28 gate ids, 0 lettered.
    #
    # NOTE FOR THE NEXT EDITOR: this awk program is inside a single-quoted
    # $(...) block. An apostrophe here CLOSES that quote, the substitution
    # dies, and the loop reads ZERO rows -- which prints as 0 claim errors
    # and PASSES. Adding one cost exactly that on 2026-08-23. No apostrophes,
    # no double quotes, in this comment block.
    if (!match($2, /v[0-9]+-D[0-9]+/)) next
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
failed=0          # blocks the cut: measured failures PLUS cannot-runs
measured_fail=0   # gates that RAN and did not meet expectation
ran=0
skipped_env=0     # gates that could not run at all

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

	# CANNOT-RUN, declared BY THE BODY. rc=97 is the vocabulary a gate uses to
	# say "I could not look", as opposed to "the defect is present".
	#
	# WHY THIS EXISTS. Until now the runner decided cannot-run ONLY before the
	# body ran -- no GATE_BOX, no GATE_ARTEFACT, stale checkout. Once a body
	# executed, the sole test was `rc == expect`, so EVERY body-side refusal
	# scored as a measured failure. That is not a corner case; measured
	# 2026-08-11 on one walk:
	#
	#   D001 D027 D029 D032 D034  died on `CM051_DIR: CM051_DIR unset`
	#   D030                      died on `CM044_DIR unset`
	#   D033                      died on `OS003_DIR unset`
	#   D002                      printed "TOOLING, not D002 ... Nothing here
	#                             says anything about the product" AND exit 1
	#   D006                      `: "${GATE_D006_SLUG_A:?...}"`, chosen to
	#                             refuse rather than silently pass
	#
	# Nine gates, two authors, one missing concept. Every one of them was
	# reported as a defect in the product. D002 and D006 both SAID they were
	# not, in English, in the log -- and the harness had no way to hear it.
	#
	# 97 is outside the range a gate body plausibly returns on its own: 0-1 are
	# verdicts, 2 is usage, 126/127 are exec failures, 128+N are signals.
	if [ "$rc" -eq 97 ]; then
		red "CANNOT-RUN (rc=97, declared by the gate)"
		printf '%s\n' "$out" | redact | sed 's/^/      /'
		skipped_env=$((skipped_env + 1)); failed=$((failed + 1))
		ran=$((ran - 1))
		continue
	fi

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
		failed=$((failed + 1)); measured_fail=$((measured_fail + 1))
	fi
done < "$work/gates.tsv"

echo ""
if [ "$failed" -eq 0 ]; then
	green "ROLLFORWARD GREEN -- $ran gate(s) met expectation"
	exit 0
fi
# SPLIT, because these are not the same claim and the old line merged them.
#
# It read "$failed of $total gate(s) failed ($skipped_env unrunnable)", and
# $failed ALREADY INCLUDED $skipped_env -- an unrunnable gate increments both
# counters. On the first completed --cut run (2026-08-11) that printed
#
#     ROLLFORWARD RED -- 19 of 27 gate(s) failed (12 unrunnable)
#
# Nineteen reads as nineteen defects. Seven were measured; twelve were gates
# that could not run at all. The parenthetical was doing all the correcting
# and nobody reads a parenthetical as a subtraction.
#
# The same walk with the sibling *_DIR vars unset said "18 of 27 failed
# (0 unrunnable)" while gate bodies were aborting on an unbound variable. So
# the number also MOVED with the environment, in the direction that flatters:
# fewer declared unrunnable, more implied defects.
#
# What does NOT change: a cannot-run still BLOCKS. Failing closed is right.
# Only the sentence changes, so the operator can tell a defect from a blind
# spot without re-reading the log.
# $ran counts gates that EXECUTED, not gates that passed -- it increments
# before the expectation is checked. I wrote "${ran} passed" in the split I
# shipped earlier today and it printed, on the first full run that had no
# cannot-runs left:
#
#     12 measured failure(s), 0 CANNOT-RUN, 27 passed (27 gates)
#
# 12 + 0 + 27 = 39 against 27 gates. The arithmetic is what exposed it; the
# wording alone reads fine, which is exactly the shape of every other defect
# found today. Passed is executed minus failed.
passed=$((ran - measured_fail))
red "ROLLFORWARD RED -- ${measured_fail} measured failure(s), ${skipped_env} CANNOT-RUN, ${passed} passed (${total} gates, ${ran} ran)"
if [ "$skipped_env" -gt 0 ]; then
	dim "CANNOT-RUN is not a finding about the product. Those gates measured"
	dim "nothing; treat them as coverage you do not have, not as defects."
fi
dim "A cut does not proceed past this. Fix the defect or fix the gate; do not"
dim "edit the expectation to match the failure."
exit 1
