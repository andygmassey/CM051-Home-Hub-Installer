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
# EXIT: 0 all gates met expectation. 1 one or more failed. 2 registry is
# malformed -- which is a cut blocker in its own right, not a warning.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${ROLLFORWARD_REGISTRY:-$HERE/cuts/DEFECTS_ROLLFORWARD.md}"
CUT=""
ONLY=""
LIST_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--cut)      CUT="${2:-}"; shift 2 ;;
		--only)     ONLY="${2:-}"; shift 2 ;;
		--list)     LIST_ONLY=1; shift ;;
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

# ---------------------------------------------------------------------------
# Pass 1 -- parse. Nothing runs until the whole registry is known good, so a
# malformed row cannot hide behind twenty green ones that ran before it.
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

parse_errors=0
perr() { red "PARSE ERROR: $1"; parse_errors=$((parse_errors + 1)); }

awk -v outdir="$work" '
	/^### / {
		# Close any DEFECT section that ended without a gate. Narrative
		# headings ("From v1.0.18", table intros) are not defect entries and
		# must not be forced to carry a gate -- demanding one there would
		# generate false parse errors and get the whole check disabled, which
		# is how a strict gate becomes no gate at all.
		if (section != "" && is_defect && !seen_gate) print section > (outdir "/nogate.txt")
		section = $0; sub(/^### /, "", section); seen_gate = 0
		is_defect = (section ~ /^v[0-9]+-D[0-9]+/)
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
	END { if (section != "" && !seen_gate) print section > (outdir "/nogate.txt") }
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
if [ "$LIST_ONLY" -eq 1 ]; then
	printf '%-16s %-8s %-10s %s\n' ID EXPECT RUNS-ON SECTION
	while IFS=$'\t' read -r id expect runson section; do
		printf '%-16s %-8s %-10s %s\n' "$id" "$expect" "$runson" "$section"
	done < "$work/gates.tsv"
	exit 0
fi

echo "rollforward gate: $total gate(s), registry parsed clean${CUT:+, cut $CUT}"
echo ""

# ---------------------------------------------------------------------------
# Pass 2 -- run.
# ---------------------------------------------------------------------------
failed=0
ran=0
skipped_env=0

for_repo_freshness() {
	# v1018-D028, applied mechanically rather than trusted to gate authors.
	# A repo-scoped gate reading a stale tree draws confident conclusions about
	# code that moved. One checkout here was 78 commits behind with an entire
	# design system missing while `git status` said clean.
	local repo="${GATE_REPO:-$PWD}"
	git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
		echo "    freshness: $repo is not a git repo"; return 1; }
	git -C "$repo" fetch -q origin 2>/dev/null || true
	local behind
	behind="$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null || echo unknown)"
	[ "$behind" = "0" ] || {
		echo "    freshness: $repo is $behind commit(s) behind origin/main"; return 1; }
	return 0
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
		out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$GATE_BOX" 'sh -s' < "$body" 2>&1)"; rc=$?
	else
		out="$(GATE_ARTEFACT="${GATE_ARTEFACT:-}" sh "$body" 2>&1)"; rc=$?
	fi
	ran=$((ran + 1))

	if [ "$rc" -eq "$expect" ]; then
		green "GREEN (rc=$rc)"
	else
		red "RED (rc=$rc, expected $expect)"
		printf '%s\n' "$out" | sed 's/^/      /'
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
