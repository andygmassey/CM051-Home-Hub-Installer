#!/usr/bin/env bash
# cut_hygiene_gate.sh -- the fail-closed CUT-HYGIENE gate (Andy, 2026-07-25)
#
# WHY THIS EXISTS
#   The v1.0.10 recut audit found built work that would NOT have shipped. Six
#   failure classes (see CUT_HYGIENE_CHARTER.md), all mechanical, all missable
#   by eye:
#     1. WRONG BASE BRANCH   -- a PR based on `main` when the cut ships from an
#                               integration line (oa #228). Looks "done", cannot
#                               merge into the cut.
#     2. ORPHAN               -- a PR built for the cut but not in the declared
#                               merge set (rc #9). Nobody cross-checked authored
#                               PRs vs the cut manifest.
#     3. BUILT != SHIPPED     -- stale pin: a fix merged to a branch but the
#                               daemon / remote-capture binary / image never
#                               rebuilt from a SHA containing it.
#     4. VENDORED STALE       -- fix landed upstream; the vendored copy the DMG
#                               ships stayed old.
#     5. STALE DOC LINE       -- a cut doc lists an in-cut item as
#                               "deferred / NOT in this DMG"; a reader acts on
#                               the stale line and skips shipped work.
#     6. QUEUE-SIT            -- reviewed but neither executed nor escalated.
#
# WHAT IT DOES
#   Reads a DECLARATIVE CUT MANIFEST (TSV). For every row it mechanically
#   asserts, via `gh` + `git`:
#     (1) PR exists, state sane (OPEN or MERGED, never CLOSED-unmerged).
#     (2) baseRefName == expected_base           (kills class 1).
#     (3) mergeable != CONFLICTING && mergeStateStatus != DIRTY.
#     (4) path-to-artifact CLASS check           (kills classes 3+4):
#           install-sh-native -> PR touches install.sh          (light)
#           vendored          -> row declares a re-vendor pointer
#           pinned-binary     -> row declares a rebuild + re-pin step
#           pinned-image      -> defer to provenance_gate.sh
#           build-config      -> PR touches a build-config file  (light)
#           separate-release  -> WARN (agreed-for-cut with no ship path?)
#           ancestor          -> informational (already in base; no assertions)
#           <unset/unknown>   -> RED (never pass an unclassifiable item).
#   Then two sweeps:
#     (5) ORPHAN sweep  -- for each repo, list OPEN PRs; flag any that look
#                          cut-relevant (base == integration line, or branch/
#                          title matches a cut theme) but are NOT in the
#                          manifest. LOUD + human-confirm, not auto-RED.
#     (6) DOC-consistency grep -- grep the cut docs for a line marking a
#                          manifest in-cut item "deferred / not-in-DMG /
#                          fast-follow". RED (kills class 5). Reversal lines
#                          (~~struck~~ / "IN RECUT" / "NO LONGER") are ignored.
#
#   FAILS CLOSED: exits non-zero on ANY red or ANY unclassifiable item.
#   Runs alongside the content-provenance gate BEFORE ORM assembly. Complements,
#   does not replace, the provenance gate.
#
# USAGE
#   ./cut_hygiene_gate.sh <MANIFEST_TSV> --integration <BRANCH> [--docs FILE]...
#     MANIFEST_TSV  REQUIRED. The PR manifest for THIS cut.
#     --integration REQUIRED. This cut's integration line.
#     --docs        cut docs to grep for stale deferral lines. Repeat the flag
#                   per doc (paths may contain spaces).
#
#   There are NO defaults, deliberately -- see #661. The old defaults named
#   v1.0.10, and since that manifest is still on disk the gate validated a
#   six-version-old cut and printed "Cut-clear". A default that names a
#   version is a bug with a shelf life.
#
#   This gate reads the PR manifest (repo|pr|ebase|class|note|status): "is this
#   work item MERGED?". It is NOT the BOM reader. The MUST_CONTAIN BOM
#   (what|repo|landed|capability_id|verify|ref) asks "is this capability IN THE
#   ARTEFACT?" and is read by scripts/verify_must_contain.sh. Provenance is not
#   content; the two documents are not interchangeable and this gate refuses a
#   BOM rather than misparse it.
#
#   Exit 0 = every row PASS, no doc contradictions. Cut-clear on this gate.
#   Exit 1 = at least one RED. Do NOT cut.
#   Exit 2 = usage / environment error / wrong document. NOT a pass.
#
# British English. No dashes in output.

set -u

# --- environment: gh + git must not go through the local proxy -------------
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# NO DEFAULTS. This is the #661 fix.
#
# These three used to default to v1.0.10 values:
#     MANIFEST    = $HERE/cut_manifest.v1010.tsv
#     INTEGRATION = integration/hub-v1.0.10-recut
#     DOCS        = BOX_WALK_V4_CHECKLIST.md ORM_ASSEMBLY_BRIEF_v1010_recut_...
#
# cut_manifest.v1010.tsv is still ON DISK, so the gate did not error -- it ran
# happily against a manifest six versions old and printed "GREEN. Cut-clear."
# That is worse than a broken gate: a broken gate gets fixed, a gate that
# validates the wrong document gets TRUSTED.
#
# A default that names a specific version is a bug with a shelf life. Require
# the caller to say which cut is being gated, every time.
# ---------------------------------------------------------------------------
MANIFEST=""
INTEGRATION=""
# Each --docs flag adds ONE path (space-safe; repeat the flag for several docs
# -- paths like "HR015 - Gaming PC" contain spaces).
DOCS_ARR=()

# --- arg parse -------------------------------------------------------------
POSITIONAL_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --integration) INTEGRATION="$2"; shift 2 ;;
    --docs)        DOCS_ARR+=("$2"); shift 2 ;;
    -h|--help)     grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             if [[ $POSITIONAL_SET -eq 0 ]]; then MANIFEST="$1"; POSITIONAL_SET=1; fi; shift ;;
  esac
done
die_usage() {
  echo "ERROR: $1" >&2
  echo "" >&2
  echo "  usage: cut_hygiene_gate.sh <MANIFEST_TSV> --integration <BRANCH> [--docs <FILE>]..." >&2
  echo "" >&2
  echo "  There are deliberately NO defaults. The previous defaults named" >&2
  echo "  v1.0.10, and because that manifest is still on disk the gate" >&2
  echo "  validated a six-version-old cut and reported 'Cut-clear'." >&2
  exit 2
}

[[ -n "$MANIFEST" ]]    || die_usage "no manifest given."
[[ -f "$MANIFEST" ]]    || die_usage "manifest not found: $MANIFEST"
[[ -n "$INTEGRATION" ]] || die_usage "no --integration branch given."

# ---------------------------------------------------------------------------
# SCHEMA REFUSAL.
#
# Two different TSVs live in this system and they are NOT interchangeable:
#
#   PR manifest (this gate)   repo | pr | ebase | class | note | status
#       asks: "is this work item MERGED into the integration line?"
#       -- provenance of WORK
#
#   MUST_CONTAIN BOM          what | repo | landed | capability_id | verify | ref
#       (read by scripts/verify_must_contain.sh)
#       asks: "is this capability PRESENT in the artefact, and verified how?"
#       -- content of the ARTEFACT
#
# They are not two versions of one document and must not be reconciled into
# one. Merging them would re-create the exact confusion this whole gate family
# exists to prevent: provenance is not content. A PR can be merged and the
# capability still absent from the artefact (stale vendor pin, unbuilt image);
# a capability can be present with no PR row at all (grafted, vendored).
#
# So: if someone points this gate at a BOM, say so loudly instead of marching
# through the rows emitting "class unknown" for every line -- which reads like
# a broken manifest rather than the wrong document entirely.
# ---------------------------------------------------------------------------
# Header-row match ONLY (Archie, 2026-08-08). Scanning the whole file would
# refuse a legitimate PR manifest whose free-text `note` column happens to say
# "landed" -- a false refusal, which costs exactly as much trust as a false
# pass. The header is the first non-comment, non-blank line.
_hdr="$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" 2>/dev/null | head -1)"
if printf '%s' "$_hdr" | grep -qE '(^|	)(capability_id|landed)(	|$)'; then
  echo "ERROR: this looks like a MUST_CONTAIN BOM, not a PR manifest." >&2
  echo "       $MANIFEST" >&2
  echo "" >&2
  echo "  It carries a 'capability_id'/'landed' column. That document asks" >&2
  echo "  whether a capability is PRESENT IN THE ARTEFACT; this gate asks" >&2
  echo "  whether a PR is MERGED INTO THE INTEGRATION LINE. Different" >&2
  echo "  questions, deliberately different documents." >&2
  echo "" >&2
  echo "  Read a BOM with:  scripts/verify_must_contain.sh <BOM>" >&2
  echo "  Refusing to guess -- a misparsed manifest reports tool faults as" >&2
  echo "  cut faults." >&2
  exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found on PATH" >&2
  exit 2
fi

# --- repo alias -> owner/slug + gh account ---------------------------------
# ORIGIN is the single source of truth; the account gates the token (403/404
# otherwise). See reference_repo_clone_and_gh_account_map.
repo_slug() {
  case "$1" in
    hr015)  echo "andygmassey/HR015-Gaming-PC" ;;
    pwg)    echo "andygmassey/personal-world-graph" ;;
    cm051)  echo "andygmassey/CM051-Home-Hub-Installer" ;;
    oa)     echo "ostler-ai/ostler-assistant" ;;
    rc)     echo "ostler-ai/ostler-remote-capture" ;;
    *)      echo "" ;;
  esac
}
repo_account() {
  case "$1" in
    oa|rc)  echo "ostler-ai" ;;
    *)      echo "andygmassey" ;;
  esac
}

# Per-repo token (do NOT switch the active account globally; export the token
# for the account that owns the repo). CM051/HR015/PWG=andygmassey, oa/rc=ostler-ai.
use_account() {
  local acct tok
  acct="$(repo_account "$1")"
  tok="$(gh auth token --user "$acct" 2>/dev/null)"
  if [[ -z "$tok" ]]; then
    echo "WARN: no gh token for account '$acct' (repo alias '$1'); gh calls may 404" >&2
  fi
  export GH_TOKEN="$tok"
}

# --- orphan-sweep heuristics ----------------------------------------------
# A cut-relevant OPEN PR = base is the integration line, OR its branch/title
# matches a cut theme. Explicit no-merge / draft / next-cut markers exclude it.
CUT_THEME_RE='bw3-9|bw3_9|bw4|recovery.?counter|consent.?gate|record.?.?.?(transcribe|capture)|v1\.0\.10|hub-v1\.0\.10|recut|menu.?bar|menubar|product.?identity|cm042|doctor.?proxy|self.?handle|fda.?auto|re-?vendor|provenance.?gate'
EXCLUDE_RE='\[no-merge\]|no-merge|nomerge|next-cut|\[next-cut\]|\[draft\]|draft|\bwip\b'

# --- accumulators ----------------------------------------------------------
declare -a ROW_REPO ROW_PR                 # manifest membership index
RED=0; WARN=0; PASS=0
declare -a RED_LINES WARN_LINES

red()  { RED=$((RED+1));  RED_LINES+=("$1");  printf "  \033[31mRED \033[0m %s\n" "$1"; }
warn() { WARN=$((WARN+1)); WARN_LINES+=("$1"); printf "  \033[33mWARN\033[0m %s\n" "$1"; }
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }

# ---------------------------------------------------------------------------
# THE MERGEABILITY DECISION, AS A PURE FUNCTION (#888).
#
# Pure so it can be exercised directly, with no network, no token and no real
# PR -- see tests/test_mergeable_unknown_is_not_clean.sh. Three states, and the
# third is the one that was missing:
#
#   conflicting  CONFLICTING or DIRTY   -> a real defect, red
#   unmeasured   UNKNOWN, empty, null   -> GitHub has not computed it, red,
#                                          but said differently so a re-run is
#                                          the remedy rather than a rebase
#   clean        anything else          -> pass
#
# Case-insensitive on purpose: the field is an API enum today, and a predicate
# that only matches one spelling is how a gate goes quietly inert.
mergeability_verdict() {  # $1 mergeable  $2 mergeStateStatus -> prints verdict
  local m s
  m="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  s="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"
  if [[ "$m" == "CONFLICTING" || "$s" == "DIRTY" ]]; then printf 'conflicting'; return; fi
  if [[ -z "$m" || "$m" == "UNKNOWN" || "$m" == "NULL" ]]; then printf 'unmeasured'; return; fi
  printf 'clean'
}

in_manifest() {  # $1 repo alias, $2 pr -> 0 if present
  local i
  for i in "${!ROW_REPO[@]}"; do
    [[ "${ROW_REPO[$i]}" == "$1" && "${ROW_PR[$i]}" == "$2" ]] && return 0
  done
  return 1
}

echo "=================================================================="
echo " CUT-HYGIENE GATE"
echo "   manifest    : $MANIFEST"
echo "   integration : $INTEGRATION"
echo "   docs        : ${DOCS_ARR[*]}"
echo "=================================================================="

# ==========================================================================
# PASS 1 -- per-row assertions
# ==========================================================================
echo
echo "-- Per-row assertions ---------------------------------------------"
# read TSV: repo  pr  expected_base  class  note  status   (# = comment)
while IFS=$'\t' read -r repo pr ebase class note status _rest; do
  [[ -z "${repo// }" ]] && continue
  [[ "${repo:0:1}" == "#" ]] && continue
  # skip a bare column-header line (repo == "repo")
  [[ "$(echo "$repo" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" == "repo" ]] && continue
  # normalise
  repo="$(echo "$repo" | tr -d '[:space:]')"
  pr="$(echo "$pr" | tr -d '[:space:]')"
  ebase="$(echo "$ebase" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  class="$(echo "$class" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  note="${note:-}"
  status="${status:-}"

  tag="[$repo #$pr | class=$class]"

  # record membership (only real repo rows participate in the orphan sweep)
  if [[ "$repo" != "—" && "$repo" != "-" ]]; then
    ROW_REPO+=("$repo"); ROW_PR+=("$pr")
  fi

  # ---- unclassifiable = RED (fail closed) --------------------------------
  case "$class" in
    install-sh-native|vendored|pinned-binary|pinned-image|build-config|separate-release|ancestor) ;;
    ""|unset|unknown|*) red "$tag class is unset/unknown -- unclassifiable item, cannot pass"; continue ;;
  esac

  # ---- ancestor rows: informational, no PR assertions --------------------
  if [[ "$class" == "ancestor" ]]; then
    ok "$tag ancestor/no-merge -- $note (informational, already in base)"
    continue
  fi

  slug="$(repo_slug "$repo")"
  if [[ -z "$slug" ]]; then
    red "$tag unknown repo alias '$repo' -- cannot resolve owner/slug"
    continue
  fi
  use_account "$repo"

  # ---- (1) PR exists + state sane ----------------------------------------
  meta="$(gh pr view "$pr" --repo "$slug" --json state,baseRefName,mergeable,mergeStateStatus \
            -q '.state+"\t"+.baseRefName+"\t"+(.mergeable//"")+"\t"+(.mergeStateStatus//"")' 2>/dev/null)"
  if [[ -z "$meta" ]]; then
    red "$tag PR not found on $slug (or auth failed for its account)"
    continue
  fi
  IFS=$'\t' read -r state abase mergeable mstate <<<"$meta"
  case "$state" in
    OPEN|MERGED) : ;;
    *) red "$tag state=$state (expected OPEN or MERGED) on $slug"; continue ;;
  esac

  # ---- (2) base branch correct -------------------------------------------
  if [[ "$abase" != "$ebase" ]]; then
    red "$tag base=$abase but manifest expects $ebase  <-- wrong-base (the #228 class)"
    continue
  fi

  # ---- (3) not conflicting -- AND NOT UNMEASURED -------------------------
  # #888. This tested ONLY for CONFLICTING/DIRTY, so UNKNOWN fell straight
  # through and the row passed. GitHub computes mergeability LAZILY: for a
  # window after any push -- to the PR or to its base -- `gh pr view` answers
  # UNKNOWN, and line 289's `(.mergeable//"")` turns a null into "" which also
  # falls through. Both read as clean. Measured live on 2026-08-27: the same
  # three PRs polled seconds apart gave UNKNOWN, then MERGEABLE.
  #
  # 🔴 WHY THIS IS WORSE HERE THAN ANYWHERE ELSE. A human who acts on an
  # UNKNOWN has a backstop: the merge API refuses a real conflict with 405, so
  # the mistake surfaces. Andy hit exactly that merging #1103 an hour before
  # this was written and got away with it for that reason. A CUT GATE HAS NO
  # SUCH BACKSTOP -- nothing downstream re-asks. An UNKNOWN it waves through is
  # simply never checked by anything, ever.
  #
  # CANNOT-RUN, not FAIL and not PASS: the answer is that GitHub had not
  # computed one yet. The row is refused and NAMED so a re-run resolves it,
  # rather than being recorded as a defect in the PR.
  verdict="$(mergeability_verdict "$mergeable" "$mstate")"
  case "$verdict" in
    conflicting)
      red "$tag CONFLICTING (mergeable=$mergeable mergeState=$mstate)"
      continue ;;
    unmeasured)
      red "$tag CANNOT-RUN: mergeability not computed yet (mergeable=${mergeable:-<null>} mergeState=${mstate:-<null>}). GitHub resolves this lazily after a push to the PR or its base. This is NOT a pass -- re-run the gate once it settles. Waving it through is #888."
      continue ;;
    clean) : ;;
    *)
      red "$tag internal: mergeability_verdict returned '$verdict' for (${mergeable:-<null>}, ${mstate:-<null>})"
      continue ;;
  esac

  # ---- (4) path-to-artifact class check ----------------------------------
  case "$class" in
    install-sh-native)
      files="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null)"
      if echo "$files" | grep -Eq '(^|/)install\.sh$'; then
        ok "$tag install-sh-native: PR touches install.sh; base=$abase state=$state"
      elif echo "$files" | grep -Eq 'install\.sh'; then
        ok "$tag install-sh-native: PR touches install.sh*; base=$abase state=$state"
      else
        warn "$tag install-sh-native but diff shows no install.sh -- confirm ship path (files: $(echo "$files" | tr '\n' ',' | head -c 120))"
      fi
      ;;
    vendored)
      if echo "$note" | grep -Eqi 're-?vendor|revendor|vendor|→ *cm051|cm051 *#|meta\.py|consent_strings'; then
        ok "$tag vendored: re-vendor pointer declared ($note); base=$abase state=$state"
      else
        red "$tag vendored but NO re-vendor pointer in note -- the copy the DMG ships may stay stale"
      fi
      ;;
    pinned-binary)
      if echo "$note" | grep -Eqi 'rebuild|re-?pin|bump *pin|release|daemon|0\.4\.|remote-?capture'; then
        ok "$tag pinned-binary: rebuild+re-pin step declared ($note); base=$abase state=$state"
      else
        red "$tag pinned-binary but NO rebuild/re-pin step declared -- built != shipped risk"
      fi
      ;;
    build-config)
      files="$(gh pr view "$pr" --repo "$slug" --json files -q '.files[].path' 2>/dev/null)"
      if echo "$files" | grep -Eq 'project\.yml|Makefile|\.pbxproj|Package\.swift|Cargo\.toml|\.xcconfig|project\.pbxproj'; then
        ok "$tag build-config: PR touches a build-config file; base=$abase state=$state"
      else
        warn "$tag build-config but diff shows no recognised build file -- confirm ($(echo "$files" | tr '\n' ',' | head -c 120))"
      fi
      ;;
    pinned-image)
      ok "$tag pinned-image: deferred to provenance_gate.sh (image digest/build); base=$abase state=$state"
      ;;
    separate-release)
      warn "$tag separate-release: agreed-for-cut? confirm a ship path exists (OS001/CM031 have no DMG path)"
      ;;
  esac
done < "$MANIFEST"

# ==========================================================================
# PASS 2 -- orphan sweep
# ==========================================================================
echo
echo "-- Orphan sweep (OPEN cut-relevant PRs not in the manifest) --------"
# unique repos from the manifest
declare -a SWEEP_REPOS
for r in "${ROW_REPO[@]}"; do
  seen=0; for s in "${SWEEP_REPOS[@]:-}"; do [[ "$s" == "$r" ]] && seen=1; done
  [[ $seen -eq 0 ]] && SWEEP_REPOS+=("$r")
done

ORPHANS=0
for repo in "${SWEEP_REPOS[@]}"; do
  slug="$(repo_slug "$repo")"; [[ -z "$slug" ]] && continue
  use_account "$repo"
  # tab-separated: number  base  branch  title
  opens="$(gh pr list --repo "$slug" --state open --limit 200 \
             --json number,baseRefName,headRefName,title \
             -q '.[] | (.number|tostring)+"\t"+.baseRefName+"\t"+.headRefName+"\t"+.title' 2>/dev/null)"
  [[ -z "$opens" ]] && continue
  while IFS=$'\t' read -r num base branch title; do
    [[ -z "$num" ]] && continue
    in_manifest "$repo" "$num" && continue
    hay="$branch $title"
    # excluded (explicit no-merge/draft/next-cut) -> skip quietly
    echo "$hay" | grep -Eqi "$EXCLUDE_RE" && continue
    relevant=0; why=""
    if [[ "$base" == "$INTEGRATION" ]]; then relevant=1; why="based on integration line"; fi
    if echo "$hay" | grep -Eqi "$CUT_THEME_RE"; then relevant=1; why="${why:+$why; }branch/title matches cut theme"; fi
    if [[ $relevant -eq 1 ]]; then
      ORPHANS=$((ORPHANS+1))
      warn "ORPHAN? $repo #$num ($why) -- '$title' [$branch] NOT in manifest. Route it or mark out-of-cut."
    fi
  done <<< "$opens"
done
[[ $ORPHANS -eq 0 ]] && echo "  (none -- every cut-relevant OPEN PR is accounted for)"

# ==========================================================================
# PASS 3 -- doc-consistency grep
# ==========================================================================
echo
echo "-- Doc-consistency (in-cut item marked 'deferred' in a cut doc) ----"
DEFER_RE='defer|not in (this )?dmg|not-in-dmg|fast.?follow|out.?of.?cut'
REVERSAL_RE='IN RECUT|NO LONGER|STALE.?LINE|~~|already in|hard.?gate|do not skip|don.t skip'
DOC_CONFLICTS=0
for doc in "${DOCS_ARR[@]}"; do
  path="$HERE/$doc"
  [[ -f "$path" ]] || path="$doc"
  if [[ ! -f "$path" ]]; then
    warn "doc not found, skipped: $doc"
    continue
  fi
  # candidate deferral lines (excluding reversal/correction lines)
  while IFS= read -r line; do
    echo "$line" | grep -Eqi "$REVERSAL_RE" && continue
    # does this deferral line name a manifest in-cut PR token?
    for i in "${!ROW_REPO[@]}"; do
      rp="${ROW_REPO[$i]}"; pn="${ROW_PR[$i]}"
      # token forms: "rc #9", "rc#9", "#9", "CM051 #434"
      if echo "$line" | grep -Eqi "(^|[^0-9])#?$pn([^0-9]|$)"; then
        # require the repo alias nearby OR the bare number to reduce false hits
        if echo "$line" | grep -Eqi "\b$rp\b|#$pn\b|$rp *#$pn"; then
          DOC_CONFLICTS=$((DOC_CONFLICTS+1))
          red "DOC-CONFLICT in $doc: in-cut $rp #$pn appears on a deferral line -> '$(echo "$line" | sed 's/^[[:space:]]*//' | head -c 140)'"
          break
        fi
      fi
    done
  done < <(grep -inE "$DEFER_RE" "$path")
done
[[ $DOC_CONFLICTS -eq 0 ]] && echo "  (none -- no cut doc defers an in-cut manifest item)"

# ==========================================================================
# VERDICT
# ==========================================================================
echo
echo "=================================================================="
echo "  $PASS pass  |  $WARN warn  |  $RED red"
if [[ $RED -gt 0 ]]; then
  echo "  RESULT: RED. Cut hygiene FAILED -- do NOT assemble the DMG."
  echo "  Red items:"
  for l in "${RED_LINES[@]}"; do echo "    - $l"; done
  echo "=================================================================="
  exit 1
fi
if [[ $WARN -gt 0 ]]; then
  echo "  RESULT: GREEN with WARNINGS. Human must confirm each WARN before cut:"
  for l in "${WARN_LINES[@]}"; do echo "    - $l"; done
fi
echo "  RESULT: GREEN. Cut-clear on the hygiene gate (warnings, if any, need sign-off)."
echo "=================================================================="
exit 0
