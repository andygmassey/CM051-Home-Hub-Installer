#!/usr/bin/env bash
# scripts/candidate_cut_freeze.sh <version> [--dry-run] [--refreeze] [--rc-build-commit SHA] [--defer-days N]
# (normally reached as: scripts/candidate.sh freeze <version>)
# ============================================================================
# THE CUT FREEZE AS ONE COMMAND. Every numbered step of launch/CUT_FREEZE_RUNBOOK.md
# that a script can do is DONE or VERIFIED here, in runbook order, and the run
# REFUSES (exit 1, naming the step) if one is unmet. Nothing is skipped quietly.
#
# Runbook step                                   What this does
#   1  RemoteCapture mirror tag + peel           VERIFY: tag exists on the mirror, peels to a commit
#                                                that is on the mirror's main (and equals
#                                                --rc-build-commit when given)
#   4  CM051= is the last product commit         VERIFY: cut.env pin == last commit on base to touch
#                                                install.sh, gui/, vendor/ or scripts/
#   5  version bump                              DO: Info.plist, project.yml, pbxproj (build = P*100)
#   6  rollforward registry sync                 DO: scripts/sync_rollforward_registry.sh, then re-check
#   7  48h PR-age deferrals                      DO: a cut-deferrals.yaml row per open PR over 48h
#      checklist registration                    DO: a deferred cut-manifests/<v>.yaml row per
#                                                unregistered open CM051 issue
#   8  the diff is only version/registry/rows    VERIFY: changed-path allow-list, install.sh blob equal
#                                                between the CM051= pin and the cut head
#   9  NEW draft "DO NOT MERGE" freeze PR        DO: push cut/<v> with --force-with-lease, open a NEW
#                                                draft PR (a closed one is never reused or reopened)
#
# NOT AUTOMATED (a person, a box or another repo; printed in the plan so they
# cannot be forgotten): 2 artefact diff, 3 OS003 BOM rows, 10 check results,
# 11 close the PR + workflow_dispatch, 12 deadline watcher, 13-14 artefact and walk.
# Also not automated: the [ledger-entry: <url>] marker on each PR in the chain.
#
# RULES THIS ENFORCES
#   * gh answers 404 with a JSON body on stdout. A 404 is ABSENT, never a value:
#     a sha is only ever a 40-hex string read from a successful call.
#   * The push is --force-with-lease only, with the lease pinned to the sha that
#     was just read. A refused or failed push STOPS the run and says so. No retry,
#     no other branch, no API write, no other route.
#   * A re-freeze (origin cut/<v> already exists at a different commit) needs
#     --refreeze; without it that is a refusal.
#   * Output never prints a credential: URLs are scrubbed before they are shown.
#
# --dry-run runs every read and every edit in a throw-away worktree, prints the
# plan and the resulting diff, and changes nothing in your tree, git or GitHub.
#
# Env: CANDIDATE_ROOT (checkout), CANDIDATE_BASE (default origin/main),
#      CANDIDATE_CM051_REPO, CANDIDATE_RC_REPO, OS003_DIR, CANDIDATE_GH (test stub).
# Exit: 0 done / already done, 1 refused (step named), 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"

SLUG="${CANDIDATE_CM051_REPO:-andygmassey/CM051-Home-Hub-Installer}"
RC_SLUG="${CANDIDATE_RC_REPO:-ostler-ai/ostler-remote-capture}"
BASE="${CANDIDATE_BASE:-origin/main}"
PR_RULE_DATE="${PR_RULE_EFFECTIVE_DATE:-2026-08-06}"

VER=""; REFREEZE=0; RC_BUILD=""; DEFER_DAYS=7
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) CAND_DRY=1; shift ;;
		--refreeze) REFREEZE=1; shift ;;
		--rc-build-commit) RC_BUILD="${2:-}"; shift 2 ;;
		--defer-days) DEFER_DAYS="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) cand_cannot "unknown argument: $1" ;;
		*) VER="$1"; shift ;;
	esac
done
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || cand_cannot "usage: candidate.sh freeze <version like v1.0.108> [--dry-run] [--refreeze]"
[[ "$DEFER_DAYS" =~ ^[0-9]+$ ]] || cand_cannot "--defer-days wants a number"
[ -z "$RC_BUILD" ] || [[ "$RC_BUILD" =~ ^[0-9a-f]{40}$ ]] || cand_cannot "--rc-build-commit wants a full 40-hex sha"

STEP="0"; STEPNAME="setup"
step() { STEP="$1"; STEPNAME="$2"; cand_say ""; cand_say "[step $1] $2"; }
# The only way out of a failed check. Names the runbook step.
fz_refuse() { cand_red "REFUSED at runbook step $STEP ($STEPNAME): $*"; exit 1; }
fz_cannot() { cand_red "CANNOT-RUN at runbook step $STEP ($STEPNAME): $*"; exit 2; }
scrub() { sed -E 's#(https?://)[^/@[:space:]]*@#\1***@#g'; }

G=(git -C "$CAND_ROOT")
"${G[@]}" rev-parse --git-dir >/dev/null 2>&1 || fz_cannot "$CAND_ROOT is not a git checkout"
WT="$CAND_TMP/wt"
fz_cleanup() { [ -d "$WT" ] && "${G[@]}" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "${CAND_TMP:?}"; }
trap fz_cleanup EXIT

# ---- gh helpers --------------------------------------------------------------
# fz_api <var> <jq> <path...> : stores the jq result in $var. NEVER call it in a
# $(...) substitution: the flag and the exit below must reach this shell.
# Sets FZ_ABSENT=1 (and leaves $var empty) on a 404; any other failure is
# CANNOT-RUN. The body of an error response is NEVER stored as a value.
FZ_ABSENT=0
fz_api() {
	local var="$1" jqx="$2" out rc; shift 2
	FZ_ABSENT=0; printf -v "$var" '%s' ""
	out="$(cand_gh "$@" --jq "$jqx" 2>&1)"; rc=$?
	if [ "$rc" -eq 0 ]; then printf -v "$var" '%s' "$out"; return 0; fi
	if printf '%s' "$out" | grep -qE '"status" *: *"?404"?|HTTP 404|Not Found'; then FZ_ABSENT=1; return 0; fi
	fz_cannot "the GitHub API call failed ($1): $(printf '%s' "$out" | head -c 200 | tr '\n' ' ' | scrub)"
}
epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }
now_epoch="${CANDIDATE_NOW:-$(date -u +%s)}"
today="${CANDIDATE_TODAY:-$(date -u +%Y-%m-%d)}"
plus_days() { date -u -d "$today + $1 days" +%Y-%m-%d 2>/dev/null || date -j -u -v+"$1"d -f %Y-%m-%d "$today" +%Y-%m-%d 2>/dev/null; }

# ---- the plan -------------------------------------------------------------
cand_say "== candidate freeze $VER (runbook launch/CUT_FREEZE_RUNBOOK.md) =="
[ "$CAND_DRY" -eq 0 ] || cand_say "DRY RUN: nothing in your tree, git or GitHub is changed."
cand_say "  step  1  VERIFY  RemoteCapture mirror tag present, peels to a commit on the mirror's main"
cand_say "  step  2  PERSON  artefact diff against the previous shipped artefact"
cand_say "  step  3  PERSON  OS003 BOM rows (verify_bom_rows_are_in_the_pin.sh) and the re-cite"
cand_say "  step  4  VERIFY  cut.env CM051= is the last product-file commit on $BASE"
cand_say "  step  5  DO      version bump: Info.plist, project.yml, pbxproj"
cand_say "  step  6  DO      rollforward registry sync from OS003 main"
cand_say "  step  7  DO      cut-deferrals.yaml rows (PRs over 48h) + checklist rows (open issues)"
cand_say "  step  8  VERIFY  diff touches only version/registry/deferral/checklist files; install.sh identical"
cand_say "  step  9  DO      push cut/$VER (force-with-lease) and open a NEW draft DO NOT MERGE PR"
cand_say "  steps 10-14      PERSON/BOX  checks green, close PR + dispatch, watcher, artefact, walk"

# ============================================================================
step 1 "RemoteCapture mirror tag"
RCV="$("${G[@]}" show "$BASE:install.sh" 2>/dev/null | sed -n 's/^OSTLER_REMOTECAPTURE_VERSION="\${OSTLER_REMOTECAPTURE_VERSION:-\([0-9][0-9.]*\)}".*/\1/p' | head -1)"
[ -n "$RCV" ] || fz_cannot "could not read OSTLER_REMOTECAPTURE_VERSION from install.sh at $BASE."
RCTAG="remote-capture-v$RCV"
fz_api obj '.object.type + " " + .object.sha' "repos/$RC_SLUG/git/ref/tags/$RCTAG"
[ "$FZ_ABSENT" -eq 0 ] || fz_refuse "tag $RCTAG is ABSENT on $RC_SLUG (404). Publish the mirror tag first; the freshness gates read it there."
peel=""; i=0
while [ "$i" -lt 4 ]; do
	otype="${obj%% *}"; osha="${obj##* }"
	[[ "$osha" =~ ^[0-9a-f]{40}$ ]] || fz_refuse "tag $RCTAG answered '$obj', which is not a type and a 40-hex sha."
	case "$otype" in
		commit) peel="$osha"; break ;;
		tag) fz_api obj '.object.type + " " + .object.sha' "repos/$RC_SLUG/git/tags/$osha"
		     [ "$FZ_ABSENT" -eq 0 ] || fz_refuse "annotated tag object $osha is ABSENT on $RC_SLUG (404)." ;;
		*) fz_refuse "tag $RCTAG points at a $otype, not a commit." ;;
	esac
	i=$((i+1))
done
[ -n "$peel" ] || fz_refuse "tag $RCTAG did not peel to a commit."
fz_api rel '.status' "repos/$RC_SLUG/compare/main...$peel"
[ "$FZ_ABSENT" -eq 0 ] || fz_refuse "the tagged commit ${peel:0:8} is not on $RC_SLUG at all (404): the build commit was never mirrored."
case "$rel" in behind|identical) ;; *) fz_refuse "tag $RCTAG peels to ${peel:0:8}, which is '$rel' relative to $RC_SLUG main, not an ancestor of it. The mirror's main must be fast-forwarded to the build commit (never replaced)." ;; esac
if [ -n "$RC_BUILD" ] && [ "$RC_BUILD" != "$peel" ]; then
	fz_refuse "tag $RCTAG peels to ${peel:0:8} but the build commit is ${RC_BUILD:0:8}. The tag must peel to the build commit itself."; fi
[ -n "$RC_BUILD" ] && bnote="equals the build commit" || bnote="build commit not supplied (--rc-build-commit), peel NOT compared to it"
cand_say "  ok: $RCTAG -> ${peel:0:8}, on the mirror's main ($rel); $bnote"

# ============================================================================
step 4 "CM051= pin is the last product commit"
"${G[@]}" rev-parse --verify -q "$BASE^{commit}" >/dev/null || fz_cannot "base $BASE does not resolve here (git fetch origin main)."
ENVREL="cuts/$VER/cut.env"
"${G[@]}" cat-file -e "$BASE:$ENVREL" 2>/dev/null || fz_refuse "no $ENVREL on $BASE (scripts/new_cut.sh opens the cut)."
"${G[@]}" cat-file -e "$BASE:cut-manifests/$VER.yaml" 2>/dev/null || fz_refuse "no cut-manifests/$VER.yaml on $BASE."
pin="$("${G[@]}" show "$BASE:$ENVREL" | sed -n 's/^CM051=//p' | head -1)"
[ -n "$pin" ] || fz_refuse "$ENVREL has no CM051= value."
pinfull="$("${G[@]}" rev-parse --verify -q "$pin^{commit}" 2>/dev/null)" || fz_refuse "CM051=$pin does not resolve to a commit here."
lastprod="$("${G[@]}" log -1 --format=%H "$BASE" -- install.sh gui vendor scripts)"
[[ "$lastprod" =~ ^[0-9a-f]{40}$ ]] || fz_cannot "git could not name the last product-file commit on $BASE."
[ "$pinfull" = "$lastprod" ] || fz_refuse "CM051=$pin is ${pinfull:0:8}, but the last commit on $BASE to change install.sh, gui/, vendor/ or scripts/ is ${lastprod:0:8}. Run scripts/candidate_pin.sh $VER, merge it, and freeze again."
cand_say "  ok: CM051=$pin is the last product commit on $BASE"

# ---- scratch worktree: every edit from here is on a copy ----------------------
"${G[@]}" worktree add --detach "$WT" "$BASE" >/dev/null 2>&1 || fz_cannot "could not create a scratch worktree at $BASE."
W=(git -C "$WT")
# Commit dates are pinned to the base commit's, so the same inputs give the same
# cut head: a re-run is a no-op instead of a different sha that would need a re-freeze.
BASE_DATE="$("${G[@]}" log -1 --format=%cI "$BASE")"
fz_commit() { "${W[@]}" add -A && GIT_AUTHOR_DATE="$BASE_DATE" GIT_COMMITTER_DATE="$BASE_DATE" "${W[@]}" commit -q -m "$1" || fz_cannot "git commit failed (is user.name/user.email set?)"; }

# ============================================================================
step 5 "version bump"
case "$VER" in v1.0.*) ;; *) fz_cannot "the build-number rule (VERSIONING.md) covers 1.0.P only; $VER needs a decision first." ;; esac
NEWV="${VER#v}"; P="${NEWV##*.}"; NEWB=$((P * 100))
PLIST="$WT/gui/OstlerInstaller/Info.plist"; YML="$WT/gui/project.yml"; PBX="$WT/gui/OstlerInstaller.xcodeproj/project.pbxproj"
for f in "$PLIST" "$YML" "$PBX"; do [ -f "$f" ] || fz_refuse "${f#"$WT"/} is missing."; done
curv="$(awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$PLIST")"
[[ "$curv" =~ ^1\.0\.[0-9]+$ ]] || fz_refuse "Info.plist CFBundleShortVersionString is '$curv'; not a 1.0.P version."
[ "${curv##*.}" -le "$P" ] || fz_refuse "Info.plist is at $curv, newer than $NEWV. A freeze never lowers the version."
if [ "$curv" != "$NEWV" ]; then
	awk -v v="$NEWV" -v b="$NEWB" '
		/<key>CFBundleShortVersionString<\/key>/ {print; getline; sub(/<string>[^<]*<\/string>/, "<string>" v "</string>"); print; next}
		/<key>CFBundleVersion<\/key>/ {print; getline; sub(/<string>[^<]*<\/string>/, "<string>" b "</string>"); print; next}
		{print}' "$PLIST" > "$CAND_TMP/plist" && cat "$CAND_TMP/plist" > "$PLIST"
	sed -E -e "s/^( *MARKETING_VERSION: *\")[^\"]*\"/\1$NEWV\"/" -e "s/^( *CURRENT_PROJECT_VERSION: *\")[^\"]*\"/\1$NEWB\"/" \
	    -e "s/^( *CFBundleShortVersionString: *\")[^\"]*\"/\1$NEWV\"/" -e "s/^( *CFBundleVersion: *\")[^\"]*\"/\1$NEWB\"/" "$YML" > "$CAND_TMP/yml" && cat "$CAND_TMP/yml" > "$YML"
	sed -E -e "s/(MARKETING_VERSION = )[0-9.]+;/\1$NEWV;/" -e "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\1$NEWB;/" "$PBX" > "$CAND_TMP/pbx" && cat "$CAND_TMP/pbx" > "$PBX"
	fz_commit "cut($VER): version bump to $NEWV (build $NEWB)"
fi
# Read ALL three back; one stale file is exactly the miss this step exists for.
pv="$(awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$PLIST")"
pb="$(awk '/<key>CFBundleVersion<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$PLIST")"
[ "$pv" = "$NEWV" ] && [ "$pb" = "$NEWB" ] || fz_refuse "Info.plist reads $pv/$pb after the bump, wanted $NEWV/$NEWB."
ybad="$(grep -E '^ *(MARKETING_VERSION|CFBundleShortVersionString): ' "$YML" | grep -vcF "\"$NEWV\"" || true)"
ybad2="$(grep -E '^ *(CURRENT_PROJECT_VERSION|CFBundleVersion): ' "$YML" | grep -vcF "\"$NEWB\"" || true)"
yn="$(grep -cE '^ *(MARKETING_VERSION|CFBundleShortVersionString|CURRENT_PROJECT_VERSION|CFBundleVersion): ' "$YML" || true)"
[ "$yn" -ge 4 ] && [ "$ybad" -eq 0 ] && [ "$ybad2" -eq 0 ] || fz_refuse "project.yml does not carry $NEWV/$NEWB on all four version keys ($yn found, $((ybad+ybad2)) wrong)."
pn="$(grep -cE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ' "$PBX" || true)"
pbad="$(grep -E 'MARKETING_VERSION = ' "$PBX" | grep -vcF "= $NEWV;" || true)"
pbad2="$(grep -E 'CURRENT_PROJECT_VERSION = ' "$PBX" | grep -vcF "= $NEWB;" || true)"
[ "$pn" -ge 2 ] && [ "$pbad" -eq 0 ] && [ "$pbad2" -eq 0 ] || fz_refuse "project.pbxproj does not carry $NEWV/$NEWB everywhere ($pn found, $((pbad+pbad2)) wrong)."
cand_say "  ok: Info.plist, project.yml and project.pbxproj all read $NEWV / $NEWB"

# ============================================================================
step 6 "rollforward registry sync"
[ -f "$WT/scripts/sync_rollforward_registry.sh" ] || fz_refuse "scripts/sync_rollforward_registry.sh is missing at $BASE."
sout="$(bash "$WT/scripts/sync_rollforward_registry.sh" 2>&1)"; src=$?
[ "$src" -eq 0 ] || fz_refuse "the registry sync stopped with exit $src (it refuses a stale, dirty or non-main OS003 checkout, or a destination ahead of the source): $(printf '%s' "$sout" | tail -3 | tr '\n' ' ' | scrub)"
if [ -n "$("${W[@]}" status --porcelain)" ]; then fz_commit "cut($VER): sync rollforward registry from OS003 main"; cand_say "  synced"; else cand_say "  already in sync"; fi
bash "$WT/scripts/sync_rollforward_registry.sh" --check >/dev/null 2>&1 || fz_refuse "the registry is STILL stale after the sync (--check failed)."
cand_say "  ok: registry matches OS003 main"

# ============================================================================
step 7 "PR-age deferrals and checklist rows"
DEFS="$WT/cut-deferrals.yaml"; MAN="$WT/cut-manifests/$VER.yaml"
[ -f "$DEFS" ] || fz_refuse "cut-deferrals.yaml is missing."
grep -q '^pr_exemptions:' "$DEFS" || fz_refuse "cut-deferrals.yaml has no pr_exemptions: block."
HEADSHA="$("${W[@]}" rev-parse HEAD)"
fz_api prs '.[] | [.number, .created_at, .draft, .head.ref, (.title | gsub("[\t\n\r]"; " "))] | @tsv' "repos/$SLUG/pulls?state=open&per_page=100" --paginate
[ "$FZ_ABSENT" -eq 0 ] || fz_cannot "the pull request list answered 404; the repo slug $SLUG is wrong or not readable."
rows_added=0; newrows="$CAND_TMP/newrows"; : > "$newrows"
existing() { sed -n '/^pr_exemptions:/,$p' "$DEFS" | awk '
	/^[[:space:]]*-[[:space:]]*ref:/ { if (ref != "") print ref "\t" rv; ref=$0; sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?/,"",ref); sub(/"?[[:space:]]*$/,"",ref); rv=""; next }
	/^[[:space:]]*review_by:/ { rv=$0; sub(/^[[:space:]]*review_by:[[:space:]]*"?/,"",rv); sub(/"?[[:space:]]*$/,"",rv) }
	END { if (ref != "") print ref "\t" rv }'; }
review_by="$(plus_days "$DEFER_DAYS")"; [[ "$review_by" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fz_cannot "could not compute a review_by date."
rule_epoch="$(epoch_of "${PR_RULE_DATE}T00:00:00Z")"
while IFS=$'\t' read -r num created draft headref title; do
	[ -n "$num" ] || continue
	[ "$headref" != "cut/$VER" ] || continue   # the freeze PR itself is step 9's, never a deferral
	ce="$(epoch_of "$created")"; [ -n "$ce" ] || fz_cannot "could not read the creation time of PR #$num ('$created')."
	[ "$ce" -ge "${rule_epoch:-0}" ] || continue
	[ $((now_epoch - ce)) -gt 172800 ] || continue
	ref="${SLUG#*/}#$num"
	cur="$(existing | awk -F'\t' -v r="$ref" '$1==r {print $2; found=1} END{if(!found) print "NONE"}' | head -1)"
	case "$cur" in
		NONE) ;;
		'') fz_refuse "$ref is over 48h and its exemption has no review_by date. Decide it; this script does not renew a person's row." ;;
		*) if [ "$cur" \< "$today" ]; then fz_refuse "$ref is over 48h and its exemption EXPIRED on $cur. Re-decide it (merge, close, or re-date with a reason); this script does not renew a person's row."; fi; continue ;;
	esac
	printf '  - ref: "%s"\n    reason: "Not in %s: cut/%s is frozen on its own branch, so under LAUNCH DIRECTIVE ITEM 4 this open PR cannot change one byte of that DMG. Written by candidate.sh freeze at the freeze, because the PR-age gate refuses any PR over 48h without a row. Triage by review_by: merge, close or re-argue. NOT A JUDGEMENT ON MERIT."\n    review_by: %s\n' "$ref" "$VER" "$VER" "$review_by" >> "$newrows"
	rows_added=$((rows_added+1)); cand_say "  deferral row: $ref (open over 48h), review_by $review_by"
done <<EOF
$prs
EOF
if [ "$rows_added" -gt 0 ]; then
	awk -v f="$newrows" '{print} /^pr_exemptions:/ && !d { while ((getline l < f) > 0) print l; d=1 }' "$DEFS" > "$CAND_TMP/defs" && cat "$CAND_TMP/defs" > "$DEFS"
fi

# Checklist: every open CM051 issue must be registered in the same step. The
# alarm label is the watchdog's, not a work item (tests/test_the_cut_checklist_is_complete.py).
fz_api issues '.[] | select(.pull_request == null) | select(([.labels[].name] | index("main-red")) == null) | [.number, (.title | gsub("[\t\n\r]"; " "))] | @tsv' "repos/$SLUG/issues?state=open&per_page=100" --paginate
[ "$FZ_ABSENT" -eq 0 ] || fz_cannot "the issue list answered 404; the repo slug $SLUG is wrong or not readable."
[ -n "$issues" ] || fz_cannot "the open-issue list came back EMPTY. A register checked against nothing is not checked; an empty list and a broken query print identically."
grep -q '^open_issues:' "$MAN" || fz_refuse "cut-manifests/$VER.yaml has no open_issues: key."
lasttop="$(grep -E '^[A-Za-z_]+:' "$MAN" | tail -1)"
case "$lasttop" in open_issues:*) ;; *) fz_refuse "open_issues: is not the last top-level key of cut-manifests/$VER.yaml, so a row cannot be appended safely. Add the rows by hand." ;; esac
registered="$(awk '/^[[:space:]]*-[[:space:]]+issue:[[:space:]]*[0-9]+/ {n=$0; sub(/.*issue:[[:space:]]*/,"",n); sub(/[^0-9].*/,"",n); cur=n; next} /^[[:space:]]+repo:/ && cur!="" {r=$0; sub(/.*repo:[[:space:]]*/,"",r); gsub(/["'"'"' ]/,"",r); if (r=="CM051") print cur; cur=""}' "$MAN")"
NEXTV="v1.0.$((P+1))"; irows=0
while IFS=$'\t' read -r inum ititle; do
	[ -n "$inum" ] || continue
	printf '%s\n' "$registered" | grep -qx "$inum" && continue
	t="$(printf '%s' "$ititle" | LC_ALL=C tr -cd '[:print:]' | sed "s/'/''/g")"
	printf "\n  - issue: %s\n    repo: CM051\n    title: '%s'\n    gate: 'NOT BLOCKING for %s; DEFERRED to %s. Registered by candidate.sh freeze in the same step the issue was found open, because the preflight checklist gate refuses any unregistered open issue. Not triaged: no proof is written and none is claimed. Whoever owns the issue replaces this row with its real gate.'\n" "$inum" "$t" "$VER" "$NEXTV" >> "$MAN"
	irows=$((irows+1)); cand_say "  checklist row: #$inum (deferred to $NEXTV)"
done <<EOF
$issues
EOF
if [ "$rows_added" -gt 0 ] || [ "$irows" -gt 0 ]; then fz_commit "cut($VER): cut-deferrals and checklist rows written at the freeze ($rows_added PR, $irows issue)"; fi
cand_say "  ok: $rows_added PR deferral row(s) and $irows checklist row(s) written; the rest were already covered"

# ============================================================================
step 8 "the diff is only version, registry, deferral and checklist files"
HEADSHA="$("${W[@]}" rev-parse HEAD)"
bad=""
for f in $("${W[@]}" diff --name-only "$BASE" HEAD); do
	case "$f" in
		gui/OstlerInstaller/Info.plist|gui/project.yml|gui/OstlerInstaller.xcodeproj/project.pbxproj) ;;
		cuts/REGISTRY_PIN|cuts/DEFECTS_ROLLFORWARD.md|bin/rollforward_gate.sh|bin/lib_redact.sh|bin/redact_selftest.sh) ;;
		cut-deferrals.yaml|"cut-manifests/$VER.yaml") ;;
		*) bad="$bad $f" ;;
	esac
done
[ -z "$bad" ] || fz_refuse "the cut head differs from $BASE in files that are not version, registry, deferral or checklist files:$bad"
[ "$("${W[@]}" rev-parse "$pinfull:install.sh")" = "$("${W[@]}" rev-parse HEAD:install.sh)" ] || fz_refuse "install.sh at the CM051= pin ${pinfull:0:8} is NOT byte-identical to install.sh at the cut head."
cand_say "  ok: $("${W[@]}" diff --name-only "$BASE" HEAD | wc -l | tr -d ' ') file(s) differ from $BASE, all on the allow-list; install.sh identical to the pin"

# ============================================================================
step 9 "push cut/$VER and open a NEW draft DO NOT MERGE PR"
BR="cut/$VER"
rem="$("${G[@]}" ls-remote origin "refs/heads/$BR" 2>/dev/null)"; lsrc=$?
[ "$lsrc" -eq 0 ] || fz_cannot "could not read origin's refs (network or auth)."
remsha="${rem%%[[:space:]]*}"
if [ "$CAND_DRY" -eq 1 ]; then
	cand_say "  would push $BR at ${HEADSHA:0:8} with --force-with-lease=refs/heads/$BR:${remsha:-<must not exist>}"
	cand_say "  would open a NEW draft PR 'DO NOT MERGE: $BR freeze (CI surface only)' against main"
	cand_say ""; cand_say "== the whole change set, exactly as a real run would commit it =="
	"${W[@]}" diff "$BASE" HEAD | scrub
	cand_say ""; cand_say "== DRY RUN complete: every runbook step this script owns passed its check =="
	exit 0
fi
if [ -n "$remsha" ] && [ "$remsha" != "$HEADSHA" ] && [ "$REFREEZE" -eq 0 ]; then
	fz_refuse "origin $BR is at ${remsha:0:8} and this freeze is ${HEADSHA:0:8}. That is a RE-freeze: pass --refreeze to replace it with --force-with-lease. Nothing was pushed."; fi
"${G[@]}" branch -f "$BR" "$HEADSHA" >/dev/null 2>&1 || fz_cannot "could not create the local branch $BR (is it checked out in another worktree?)"
if [ "$remsha" = "$HEADSHA" ]; then
	cand_say "  origin $BR is already at ${HEADSHA:0:8}; nothing to push"
else
	pout="$("${G[@]}" push --force-with-lease="refs/heads/$BR:${remsha}" origin "$BR:refs/heads/$BR" 2>&1)"; prc=$?
	if [ "$prc" -ne 0 ]; then
		cand_red "PUSH DENIED OR FAILED at runbook step 9 (exit $prc). STOPPED."
		printf '%s\n' "$pout" | scrub | tail -6 >&2
		cand_red "Not retrying, not pushing anywhere else, not using the API to write the branch. Report this to whoever owns the remote and re-run once it is resolved."
		exit 1
	fi
	cand_say "  pushed $BR at ${HEADSHA:0:8} (force-with-lease against ${remsha:-absent})"
fi
owner="${SLUG%%/*}"
fz_api existing_prs '.[] | [.number, .state, .head.sha] | @tsv' "repos/$SLUG/pulls?state=all&head=$owner:$BR&per_page=100" --paginate
[ "$FZ_ABSENT" -eq 0 ] || existing_prs=""
have=""
while IFS=$'\t' read -r pn pst psha; do
	[ -n "$pn" ] || continue
	if [ "$pst" = "open" ]; then
		[ "$psha" = "$HEADSHA" ] || fz_refuse "open PR #$pn for $BR is at ${psha:0:8}, not the cut head ${HEADSHA:0:8}. Close it and re-run; a stale PR does not run the checks on this head."
		have="$pn"
	else
		cand_say "  ignoring CLOSED PR #$pn: a closed freeze PR is never reused (GitHub pins it to its old head)"
	fi
done <<EOF
$existing_prs
EOF
if [ -n "$have" ]; then
	cand_say "  ok: open freeze PR #$have is already at the cut head"
else
	body="DO NOT MERGE. This draft exists only so the checks run on the frozen head of $BR (a branch push alone yields zero check-runs, and the cut reads zero as CANNOT-RUN). Close it as soon as the checks are green and before dispatching; it counts against the 48h PR-age gate if left open. Written by scripts/candidate.sh freeze."
	newpr="$(cand_gh "repos/$SLUG/pulls" -X POST -f "title=DO NOT MERGE: $BR freeze (CI surface only)" -f "head=$BR" -f base=main -f "body=$body" -F draft=true --jq .number 2>&1)" || fz_cannot "opening the draft PR failed: $(printf '%s' "$newpr" | head -c 200 | tr '\n' ' ' | scrub)"
	[[ "$newpr" =~ ^[0-9]+$ ]] || fz_cannot "the PR API answered '$(printf '%s' "$newpr" | head -c 80 | tr '\n' ' ')', not a PR number."
	cand_say "  ok: opened NEW draft PR #$newpr at ${HEADSHA:0:8}"
fi
cand_say ""
cand_say "== FREEZE $VER DONE through step 9 at ${HEADSHA:0:8} =="
cand_say "Next (a person): step 10 every check green, step 11 close the PR then dispatch cut.yml on $BR (no tag), step 12 deadline watcher."
exit 0
