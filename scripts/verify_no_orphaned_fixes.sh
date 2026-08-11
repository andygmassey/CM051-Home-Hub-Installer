#!/usr/bin/env bash
#
# verify_no_orphaned_fixes.sh -- fail the cut when a FIX EXISTS but is not in it.
#
# =============================================================================
# WHY THIS GATE EXISTS
# =============================================================================
# The v1.0.15 box-walk (2026-08-06) found nine defects. SIX of them were
# ALREADY FIXED and had simply never reached main:
#
#   CM044  7f1dc59  dup-decision buttons + settling-card ETA   unmerged branch
#   CM044  1ef16a5  hydration weighted % bar (Option B)        unmerged branch
#   CM051  #632     Back/Continue footer                       LOCAL-ONLY worktree,
#                                                              parent clone deleted
#   CM051  browsing self-create collection                     unmerged branch
#   CM031  #154     hardcoded $24.99 paywall price             OPEN **DRAFT** PR,
#                                                              all checks green,
#                                                              sat 4 days
#
# Andy walked a DMG and hit every one of them. That is not six bugs. It is one
# habit: work gets written, then abandoned before the merge. Every existing cut
# gate passed, because every existing gate asks "is what we pinned present?" --
# never "does a fix exist that we FORGOT to pin?".
#
# Andy, 2026-08-06: "put safe guards in place to not allow shit git hygiene
# like this, as well as against cuts."
#
# =============================================================================
# WHAT IT CHECKS
# =============================================================================
# For every repo that feeds the cut, against the ref actually being shipped:
#
#   1. OPEN PRs (INCLUDING DRAFTS) whose head is not an ancestor  -> RED
#      Drafts are checked LOUDEST: #154 was a green draft for four days.
#   2. Remote branches matching fix/ hotfix/ feat/ carrying commits
#      not in the shipping ref                                    -> RED
#   3. LOCAL-ONLY branches (not on origin at all)                 -> RED
#      This is the #632 class: work that exists on one machine and is one
#      `rm -rf` from gone. It is invisible to every other gate.
#   4. Dirty or untracked work in the cut checkout                -> RED
#
# =============================================================================
# HOW TO DEFER SOMETHING DELIBERATELY
# =============================================================================
# You may absolutely decide a fix is not for this cut. What you may NOT do is
# decide it SILENTLY. Add it to cut-deferrals.yaml with a reason:
#
#   deferrals:
#     - ref: "CM044:feat/wiki-reskin"
#       reason: "Reskin lands in v1.0.17, exemplar signed off but not propagated"
#       until_cut: "v1.0.17"
#
# The deferral file is tracked, so `git log cut-deferrals.yaml` is the history
# of every conscious "not yet". Silence is the bug; a recorded decision is fine.
#
# Usage:  scripts/verify_no_orphaned_fixes.sh [--json]
# Exit:   0 = clean, 1 = orphaned work found, 3 = cannot verify (fail closed)
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFERRALS_FILE="${OSTLER_CUT_DEFERRALS:-${REPO_ROOT}/cut-deferrals.yaml}"

red=0
warn=0
checked=0
unchecked=0          # declared unverifiable in THIS environment
unverifiable=0       # undeclared and unreachable -- fails closed
unchecked_labels=""

say()  { printf '%s\n' "$*"; }
bad()  { printf '  [RED]  %s\n' "$*" >&2; red=$((red + 1)); }

# Run gh with an EXPLICIT token when we resolved one, and with the AMBIENT
# environment when we did not.
#
# The previous form was `GH_TOKEN="$tok" gh ...` at both call sites, which
# looks equivalent and is not: when $tok is empty it exports GH_TOKEN as the
# empty string, and an empty GH_TOKEN does not mean "fall back", it means
# "unauthenticated". So the assignment intended to ADD credentials actively
# STRIPPED the ones the environment already had.
#
# Measured on the v1.0.22 cut (run 31478119136). `gh auth token -u <owner>`
# returns nothing on a hosted runner -- there is no `gh auth login` there --
# so every PR lookup ran unauthenticated and answered:
#
#   gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN
#       environment variable
#
# branch_landed() treats a failed lookup as "not landed", so that produced a
# RED naming a BRANCH for what was actually a missing credential. The branch
# it named did turn out to be genuinely unmerged, which is the dangerous part:
# a blind instrument returned the right answer, and would have been believed.
#
# The consequence worth spelling out: setting GH_TOKEN in the workflow would
# NOT have fixed this on its own. The script would have overwritten it.
gh_as() {
    local t="$1"; shift
    if [[ -n "$t" ]]; then GH_TOKEN="$t" gh "$@"; else gh "$@"; fi
}
note() { printf '  [warn] %s\n' "$*"; warn=$((warn + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Deferrals. A ref listed here is a CONSCIOUS decision and does not fail the
# cut -- but it is always PRINTED, so nothing is ever silently absent.
# ---------------------------------------------------------------------------
is_deferred() {
    local ref="$1"
    [[ -f "$DEFERRALS_FILE" ]] || return 1
    grep -qE "^[[:space:]]*-?[[:space:]]*ref:[[:space:]]*[\"']?${ref}[\"']?[[:space:]]*$" \
        "$DEFERRALS_FILE"
}

deferral_reason() {
    local ref="$1"
    awk -v want="$ref" '
        $0 ~ /ref:/ {
            line = $0; gsub(/.*ref:[[:space:]]*/, "", line)
            gsub(/["'"'"']/, "", line); gsub(/[[:space:]]*$/, "", line)
            cur = (line == want)
        }
        cur && /reason:/ {
            r = $0; gsub(/.*reason:[[:space:]]*/, "", r)
            gsub(/["'"'"']/, "", r); print r; exit
        }
    ' "$DEFERRALS_FILE" 2>/dev/null
}

# until_cut is written on nearly every deferral and, until now, was read by
# NOTHING. is_deferred() matches on `ref:` alone, so a row saying "defer to
# v1.0.20" kept deferring at v1.0.21, v1.0.22 and v1.0.23. Every deferral in
# the file is, in practice, permanent.
#
# Reported and not enforced, deliberately. Roughly a hundred rows currently
# carry an until_cut at or before v1.0.20, so enforcing expiry in the same
# change would turn every one of them RED and block the cut outright -- fixing
# the ledger by burning the release. The warning makes the debt visible now;
# making it blocking is a post-launch change, once the backlog is worked down.
deferral_until() {
    local ref="$1"
    awk -v want="$ref" '
        $0 ~ /ref:/ {
            line = $0; gsub(/.*ref:[[:space:]]*/, "", line)
            gsub(/["'"'"']/, "", line); gsub(/[[:space:]]*$/, "", line)
            cur = (line == want)
        }
        cur && /until_cut:/ {
            u = $0; gsub(/.*until_cut:[[:space:]]*/, "", u)
            gsub(/["'"'"']/, "", u); print u; exit
        }
    ' "$DEFERRALS_FILE" 2>/dev/null
}

# The version being cut, for expiry comparison only. GITHUB_REF_NAME is the
# tag on a tag-triggered run; empty elsewhere, in which case expiry is simply
# not evaluated rather than guessed at.
CUT_VERSION="${OSTLER_CUT_VERSION:-${GITHUB_REF_NAME:-}}"
expired_deferrals=0

deferred_note() {
    local ref="$1" why="$2" until_v suffix=""
    until_v="$(deferral_until "$ref")"
    # Compare only the leading vX.Y.Z; several rows carry trailing prose such as
    # "v1.0.20 -- PRIORITY, first into the next wiki rebuild".
    local u_num c_num
    u_num="$(printf '%s' "${until_v:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    c_num="$(printf '%s' "${CUT_VERSION:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -n "$u_num" && -n "$c_num" && "$u_num" != "$c_num" ]]; then
        # Expired iff until_cut sorts strictly BEFORE the version being cut.
        if [[ "$(printf '%s\n%s\n' "${u_num#v}" "${c_num#v}" | sort -V | head -1)" == "${u_num#v}" ]]; then
            suffix="  [EXPIRED: said ${u_num}, cutting ${c_num}]"
            expired_deferrals=$((expired_deferrals + 1))
        fi
    fi
    note "DEFERRED  ${ref} -- ${why}${suffix}"
}

report_orphan() {
    local ref="$1" detail="$2"
    if is_deferred "$ref"; then
        local why; why="$(deferral_reason "$ref")"
        deferred_note "$ref" "${why:-no reason recorded}"
    else
        bad "${ref}"
        printf '         %s\n' "$detail" >&2
        printf '         Merge it, or record the deferral in %s\n' \
            "$(basename "$DEFERRALS_FILE")" >&2
    fi
}

# ---------------------------------------------------------------------------
# ANCESTRY IS NOT LANDING. DO NOT REINTRODUCE `merge-base --is-ancestor` AS
# THE ANSWER TO "DID THIS BRANCH LAND".
#
# CM051 has allow_squash_merge=true. A squash merge creates a NEW commit, so
# the branch head is never reachable from main -- for a FULLY MERGED branch,
# forever. `ostler-ai/ostler-assistant` is rebase-merge-only, which has the
# same consequence. Measured 2026-08-11 against three merged CM051 PRs:
#
#     PR #559  merged   main..head ahead_by = 1   -> ancestry says "unmerged"
#     PR #556  merged   main..head ahead_by = 6   -> ancestry says "unmerged"
#     PR #555  merged   main..head ahead_by = 1   -> ancestry says "unmerged"
#
# The old predicate therefore produced SIX false REDs on the v1.0.19 preflight
# and `git fetch --prune` gave 15 before and 15 after: structural, not stale.
# The only sanctioned way past this gate is cut-deferrals.yaml, so a
# false-positive blocker asks the operator to attest to fifteen untrue things
# -- while its own error text says "Do NOT bypass this gate. Bypassing it is
# the habit it exists to stop." A broken blocker manufactures the habit it
# forbids. That is worse than no gate.
#
# Ancestry survives ONLY as a cheap pre-filter: if the branch IS an ancestor
# it certainly landed, so we can skip the network call. A non-ancestor proves
# nothing and must be escalated to PR merge state.
#
# Returns: 0 = landed (reason on stdout)
#          2 = an OPEN PR exists (the PR loop reports it; do not double-report)
#          1 = not landed, or could not be determined -- FAIL CLOSED
# ---------------------------------------------------------------------------
branch_landed() {
    local gh_repo="$1" path="$2" branch="$3" rev="$4" ship_sha="$5" tok="${6:-}"

    # `rev` and `branch` are DIFFERENT THINGS and conflating them cost an hour.
    #
    # `branch` is the NAME GitHub knows ("fix/foo") -- what `gh pr list --head`
    # needs. `rev` is something git can resolve HERE, which for a branch that
    # exists only on the remote is "origin/fix/foo". Passing the bare name as
    # the rev makes merge-base fail to resolve, which is indistinguishable from
    # "not an ancestor", which escalates to a PR lookup, which for a branch
    # pushed without a PR answers NONE -- a RED for work sitting on main.
    #
    # Measured while building this: four CM051 branches (fix/632-button-footer-
    # baseline, fix/install-grep-c-arith-leak, fix/strings-emdash-gate-green,
    # fix/wiki-pin-orphan-blob-lines-v1.0.3) are all ancestors of origin/main
    # and all four went RED on my first draft. A rewrite of a blocking gate can
    # introduce false positives just as easily as it removes them; that is what
    # the "remote-only branch that IS an ancestor" self-test case is for.
    if [[ -n "$rev" ]] && \
       git -C "$path" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null && \
       git -C "$path" merge-base --is-ancestor "$rev" "$ship_sha"; then
        printf 'commits are ancestors of the shipping ref\n'; return 0
    fi

    # No repo or no gh means we CANNOT answer. Say so and fail closed; do not
    # let an unanswerable question read as "landed".
    if [[ -z "$gh_repo" ]] || ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    local js verdict num
    # NO 2>/dev/null. A usage error, an auth failure and a genuinely empty
    # result all look identical once stderr is discarded, and every one of
    # those reads as "no PR" -- which here means RED, but on the next edit
    # could just as easily mean GREEN. Fourth stderr-suppression incident of
    # 2026-08-10/11; the rule is now: never suppress a probe's stderr.
    if ! js="$(gh_as "$tok" pr list --repo "$gh_repo" --head "$branch" \
                 --state all --limit 20 --json number,state,mergedAt 2>&1)"; then
        printf '  [warn] gh pr list failed for %s#%s: %s\n' \
            "$gh_repo" "$branch" "$(printf '%s' "$js" | head -1)" >&2
        return 1
    fi

    verdict="$(printf '%s' "$js" | python3 -c '
import json,sys
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(3)
merged = [p for p in prs if p.get("mergedAt")]
if merged:
    p = merged[0]; print("MERGED %s %s" % (p["number"], p["mergedAt"])); raise SystemExit
op = [p for p in prs if p.get("state") == "OPEN"]
if op:
    print("OPEN %s" % op[0]["number"]); raise SystemExit
if prs:
    print("CLOSED %s" % prs[0]["number"]); raise SystemExit
print("NONE")
')" || { printf '  [warn] unparseable gh output for %s\n' "$branch" >&2; return 1; }

    case "$verdict" in
        MERGED*)
            printf 'PR #%s merged %s\n' "$(awk '{print $2}' <<<"$verdict")" \
                                        "$(awk '{print $3}' <<<"$verdict")"
            return 0 ;;
        OPEN*)
            printf 'open PR #%s\n' "$(awk '{print $2}' <<<"$verdict")"
            return 2 ;;
        CLOSED*)
            # A closed-unmerged PR is normally real orphaned work. The one
            # honest exception is a REPLACEMENT merge: #542 was closed, and
            # main carries 4467e49 "(replaces #542) (#543)". The content
            # landed by another route, and the convention is machine-readable.
            num="$(awk '{print $2}' <<<"$verdict")"
            local hit
            hit="$(git -C "$path" log --extended-regexp \
                      --grep="replaces #${num}([^0-9]|\$)" \
                      --format='%h %s' "$ship_sha" 2>/dev/null | head -1)"
            if [[ -n "$hit" ]]; then
                printf 'PR #%s closed but replaced on the shipping ref: %s\n' "$num" "$hit"
                return 0
            fi
            return 1 ;;
        *)
            return 1 ;;
    esac
}

# Report a branch UNLESS it is deferred, or it demonstrably landed, or an open
# PR already covers it. Every outcome is PRINTED -- silence is the bug this
# gate exists to stop, so "landed" is stated, not assumed.
maybe_orphan_branch() {
    local ref="$1" branch="$2" rev="$3" detail="$4" \
          gh_repo="$5" path="$6" ship_sha="$7" tok="${8:-}"

    if is_deferred "$ref"; then
        local why; why="$(deferral_reason "$ref")"
        deferred_note "$ref" "${why:-no reason recorded}"
        return
    fi

    local why rc
    why="$(branch_landed "$gh_repo" "$path" "$branch" "$rev" "$ship_sha" "$tok")"; rc=$?
    case "$rc" in
        0) ok "${ref}: landed -- ${why}" ; return ;;
        2) ok "${ref}: ${why} -- reported once, by the PR check below" ; return ;;
    esac

    bad "${ref}"
    printf '         %s\n' "$detail" >&2
    printf '         Merge it, or record the deferral in %s\n' \
        "$(basename "$DEFERRALS_FILE")" >&2
}

# ---------------------------------------------------------------------------
# 1 + 2 + 3: per-repo branch and PR checks.
#   $1 repo label   $2 checkout path   $3 shipping ref   $4 gh "owner/name" ("" to skip PRs)
# ---------------------------------------------------------------------------
check_repo() {
    local label="$1" path="$2" ship_ref="$3" gh_repo="${4:-}"

    # An unverifiable repo is a FAILURE, not a note.
    #
    # On the v1.0.16 cut this gate printed "4 repo(s) checked" and went GREEN
    # while CM044 and the daemon were both silently skipped -- their *_DIR
    # variables defaulted to the empty string, so "$path/.git" was "/.git" and
    # the -d test simply failed. The daemon was 162 commits ahead of its own
    # origin/main at the time and nothing said a word. That is the same shape
    # as the ships-dark writer bug: the check exists, reports success, and
    # inspects nothing.
    #
    # If a repo genuinely is not on this machine, say so explicitly via
    # OSTLER_ORPHAN_GATE_SKIP="label1,label2" -- a deliberate, visible act.
    if [[ -z "$path" ]]; then
        if [[ ",${OSTLER_ORPHAN_GATE_SKIP:-}," == *",${label},"* ]]; then
            note "${label}: skipped by OSTLER_ORPHAN_GATE_SKIP"
            return
        fi
        bad "${label}: no checkout path configured -- cannot verify"
        printf '         Set %s_DIR (or cut.env), or skip deliberately with\n' "$label" >&2
        printf '         OSTLER_ORPHAN_GATE_SKIP=%s\n' "$label" >&2
        return
    fi

    # `.git` is a FILE, not a directory, inside a git worktree. Testing for a
    # directory makes this gate worktree-blind (same defect as #649), so ask
    # git itself rather than guessing at the layout.
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        if [[ ",${OSTLER_ORPHAN_GATE_SKIP:-}," == *",${label},"* ]]; then
            note "${label}: NOT CHECKED HERE (declared in OSTLER_ORPHAN_GATE_SKIP)"
            unchecked_labels="${unchecked_labels}${unchecked_labels:+, }${label}"
            unchecked=$((unchecked + 1))
            return
        fi
        # "I could not look" is NOT "there is abandoned work", and this line
        # used to say the second while meaning the first.
        #
        # On the v1.0.22 cut every one of CM044, CM041, CM059, CM031 and the
        # daemon reported here, because their default paths are $HOME/Developer
        # and $HOME/Documents/Projects -- the OPERATOR's Mac. On a hosted
        # runner $HOME is /Users/runner and none of them can exist. The gate
        # then printed five [RED]s and "6 orphaned", which reads as six
        # abandoned fixes and was in fact one real finding plus five absent
        # directories.
        #
        # That is the shape this whole gate exists to prevent, turned inward:
        # a check reporting a verdict it never measured. It is also why
        # check-orphans could never have passed in hosted CI on any tag --
        # a hard gate encoding an environmental assumption
        # (feedback_dont_invent_environmental_facts_in_hard_gates).
        #
        # Still fails closed when UNDECLARED: silence is the bug, and an
        # unreachable repo nobody has thought about is exactly the silence.
        # Declaring it in OSTLER_ORPHAN_GATE_SKIP is a conscious "this
        # environment cannot see this repo", the same contract as a deferral.
        bad "${label}: CANNOT VERIFY -- ${path} is not a git checkout here"
        printf '         This is NOT a finding of orphaned work. Nothing was measured.\n' >&2
        printf '         Point %s_DIR at a checkout, or declare it unverifiable in\n' "$label" >&2
        printf '         this environment with OSTLER_ORPHAN_GATE_SKIP=%s\n' "$label" >&2
        unverifiable=$((unverifiable + 1))
        return
    fi
    checked=$((checked + 1))
    say ""
    say "-- ${label} (${ship_ref})"
    # Per-repo, because the closing "nothing orphaned" line used to read the
    # GLOBAL counter: once ANY repo went red, no later clean repo could ever
    # say it was clean. Cosmetic, but it is the same class of bug as the rest
    # of this file -- a status line that does not describe what it names.
    local red_at_entry="$red"

    # Per-repo credentials. The cut spans TWO GitHub accounts (andygmassey
    # owns CM0xx, ostler-ai owns the daemon), and `gh auth switch` is GLOBAL --
    # whichever account is active, the other account's repos answer 404
    # "Repository not found", which reads like a permissions bug.
    #
    # On the first honest run of this gate that is exactly what happened:
    # switching to ostler-ai so the daemon could be checked made CM044, CM041,
    # CM031 and CM059 all report "fetch failed; results may be stale". A gate
    # whose answer depends on ambient shell state is not a gate.
    #
    # So resolve the token for the repo's OWNER and use it explicitly.
    local _owner="" _tok="" _auth=""
    _owner="${gh_repo%%/*}"
    if [[ -n "$_owner" ]] && command -v gh >/dev/null 2>&1; then
        _tok="$(gh auth token -u "$_owner" 2>/dev/null || true)"
    fi
    # On a hosted runner there is no `gh auth login`, so the per-owner lookup
    # above returns nothing and the ONLY credential available is the workflow's
    # own. Fall back to it. It reaches THIS repo and no other -- a repo-scoped
    # GITHUB_TOKEN cannot read a sibling repo even under the same owner -- so
    # this makes the cut repo's own PR check work in CI and changes nothing for
    # the siblings, which is exactly the true division of what CI can see.
    if [[ -z "$_tok" ]]; then
        _tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    fi

    _timeout=""; command -v gtimeout >/dev/null 2>&1 && _timeout="gtimeout 30"
    if [[ -n "$_tok" ]]; then
        # base64 wraps at 76 columns on macOS; an embedded newline corrupts the
        # header and the fetch fails in a way that looks like a bad token.
        _auth="$(printf 'x-access-token:%s' "$_tok" | base64 | tr -d '\n')"
        $_timeout git -c "http.extraheader=AUTHORIZATION: basic ${_auth}" \
            -C "$path" fetch -q origin --prune 2>/dev/null || \
            note "${label}: fetch failed; results may be stale"
    else
        $_timeout git -C "$path" fetch -q origin --prune 2>/dev/null || \
            note "${label}: fetch failed; results may be stale"
    fi

    local ship_sha
    ship_sha="$(git -C "$path" rev-parse --verify "$ship_ref" 2>/dev/null)" || {
        bad "${label}: shipping ref '${ship_ref}' does not resolve"
        return
    }

    # -- 3. LOCAL-ONLY branches (the #632 class) ----------------------------
    #
    # "No remote-tracking ref" does NOT mean "never pushed". Every repo here
    # has delete_branch_on_merge, so the remote branch is REMOVED at merge and
    # the local one is left behind. Four of the six false REDs on 2026-08-11
    # were exactly this: merged work described as "One rm -rf from gone".
    # branch_landed() settles it against PR merge state.
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        [[ "$b" == "HEAD" ]] && continue
        if ! git -C "$path" show-ref -q --verify "refs/remotes/origin/$b" 2>/dev/null; then
            local n; n="$(git -C "$path" rev-list --count "${ship_sha}..$b" 2>/dev/null || echo '?')"
            maybe_orphan_branch "${label}:${b}" "$b" "$b" \
                "LOCAL-ONLY branch, no remote ref and no merged PR, ${n} commit(s) not in ${ship_ref}. One rm -rf from gone." \
                "$gh_repo" "$path" "$ship_sha" "$_tok"
        fi
    done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)

    # -- 2. remote fix/feat branches not in the shipping ref ----------------
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        local short="${b#origin/}"
        [[ "$short" == "HEAD" || "$short" == "main" || "$short" == "master" ]] && continue
        case "$short" in
            fix/*|hotfix/*|feat/*|feature/*) ;;
            *) continue ;;
        esac
        local n; n="$(git -C "$path" rev-list --count "${ship_sha}..$b" 2>/dev/null || echo '?')"
        maybe_orphan_branch "${label}:${short}" "$short" "$b" \
            "unmerged branch, ${n} commit(s) not in ${ship_ref}" \
            "$gh_repo" "$path" "$ship_sha" "$_tok"
    done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)

    # -- 1. OPEN PRs, drafts included ---------------------------------------
    if [[ -n "${OSTLER_ORPHAN_GATE_SKIP_PR:-}" ]]; then
        note "${label}: PR check SKIPPED (OSTLER_ORPHAN_GATE_SKIP_PR set)"
    elif [[ -n "$gh_repo" ]] && command -v gh >/dev/null 2>&1; then
        local prs
        # GH_TOKEN for the repo's OWNER, not whichever account `gh auth switch`
        # last left active -- see the fetch block above for why that matters.
        prs="$(gh_as "${_tok:-}" pr list --repo "$gh_repo" --state open --limit 100 \
                 --json number,title,headRefName,isDraft 2>/dev/null)" || prs=""
        if [[ -n "$prs" ]]; then
            local line
            while IFS=$'\t' read -r num title head draft; do
                [[ -z "${num:-}" ]] && continue
                git -C "$path" merge-base --is-ancestor "origin/$head" "$ship_sha" 2>/dev/null \
                    && continue
                local tag="OPEN PR"
                [[ "$draft" == "true" ]] && tag="OPEN **DRAFT** PR"
                report_orphan "${label}:#${num}" \
                    "${tag} '${title}' (head ${head}) is NOT in ${ship_ref}"
            done < <(printf '%s' "$prs" | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    print("\t".join([str(p["number"]), p["title"].replace("\t"," "),
                     p["headRefName"], str(p["isDraft"]).lower()]))
' 2>/dev/null)
        else
            note "${label}: could not list PRs (auth/billing?) -- PR check NOT performed"
        fi
    elif [[ -n "$gh_repo" ]]; then
        note "${label}: gh not installed -- PR check NOT performed"
    fi

    # -- 4. dirty tree -------------------------------------------------------
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
        report_orphan "${label}:working-tree" \
            "uncommitted or untracked changes in the cut checkout"
    fi

    [[ "$red" -eq "$red_at_entry" ]] && ok "${label}: nothing orphaned"
}

# ---------------------------------------------------------------------------
say "== verify_no_orphaned_fixes: is any FIX written but not shipping? =="
[[ -f "$DEFERRALS_FILE" ]] \
    && say "   deferrals: $(basename "$DEFERRALS_FILE")" \
    || say "   deferrals: none recorded"

# cut.env names every input; source it so this gate and the cut agree.
if [[ -f "${REPO_ROOT}/cut.env" ]]; then
    set -a; . "${REPO_ROOT}/cut.env"; set +a
fi

# Repo set. Injectable so the gate is testable in isolation and so an
# operator can narrow a run: OSTLER_ORPHAN_GATE_REPOS="label|path|ref|ghrepo;..."
if [[ -n "${OSTLER_ORPHAN_GATE_REPOS:-}" ]]; then
    IFS=';' read -ra _entries <<< "$OSTLER_ORPHAN_GATE_REPOS"
    for _e in "${_entries[@]}"; do
        [[ -z "$_e" ]] && continue
        IFS='|' read -r _l _p _r _g <<< "$_e"
        check_repo "${_l}" "${_p}" "${_r:-origin/main}" "${_g:-}"
    done
else
check_repo "CM051" "$REPO_ROOT" "origin/main" "andygmassey/CM051-Home-Hub-Installer"
check_repo "CM044" "${CM044_DIR:-$HOME/Developer/CM044-PWG-Personal-Wiki}" "origin/main" "andygmassey/CM044-PWG-Personal-Wiki"
check_repo "CM041" "${CM041_DIR:-$HOME/Developer/cm041-fresh}" "origin/main" "andygmassey/CM041-People-Graph"
check_repo "CM059" "${CM059_DIR:-$HOME/Documents/Projects/CM059 - Ostler Editor}" "origin/main" "andygmassey/CM059-Ostler-Editor"
check_repo "CM031" "${CM031_DIR:-$HOME/Documents/Projects/CM031 - PWG Companion}" "origin/main" "andygmassey/CM031-PWG-Companion"
check_repo "daemon" "${OSTLER_ASSISTANT_DIR:-$HOME/Developer/ostler-assistant}" "origin/main" "ostler-ai/ostler-assistant"
fi

say ""
say "== summary: ${checked} repo(s) checked, ${red} orphaned, ${warn} warning(s), ${unchecked} NOT CHECKED =="

# A gate that goes quiet about its own coverage gets read as covering
# everything. Name the unchecked repos every run, not only when something is
# wrong -- a green line saying "5 repos not checked" is the whole point.
if [[ "$expired_deferrals" -gt 0 ]]; then
    say ""
    say "   ${expired_deferrals} deferral(s) are marked [EXPIRED]: their until_cut named a"
    say "   version older than the one being cut, so they are still deferring past"
    say "   their own stated deadline. Not blocking (yet). Work them down."
fi

if [[ "$unchecked" -gt 0 ]]; then
    say ""
    say "   NOT CHECKED IN THIS ENVIRONMENT: ${unchecked_labels}"
    say "   These were declared unverifiable here, so this run says NOTHING about"
    say "   them either way. They are covered by the OPERATOR run of this script"
    say "   on the build machine, where all three gh accounts resolve. If that run"
    say "   did not happen, these repos went unexamined."
fi

if [[ "$red" -gt 0 ]]; then
    if [[ "$unverifiable" -gt 0 ]]; then
        printf '\n' >&2
        printf 'NOTE: %d of the %d RED(s) above are CANNOT-VERIFY, not orphaned work.\n' \
            "$unverifiable" "$red" >&2
        printf '      Nothing was measured for those. Either point their *_DIR at a\n' >&2
        printf '      checkout, or declare them in OSTLER_ORPHAN_GATE_SKIP. Do not\n' >&2
        printf '      read them as a finding, and do not read them as a pass.\n' >&2
    fi
    cat >&2 <<'EOF'

ERROR: work exists that is NOT in what you are about to ship.

This is the exact failure that produced the v1.0.15 walk: six fixes were
already written and none of them reached main, so Andy hit every one of
them by hand on a DMG that passed all forty other gates.

For each RED above, either:
  * merge it to main (preferred -- unmerged equals not shipped), or
  * record a deliberate deferral, with a reason, in cut-deferrals.yaml

Do NOT bypass this gate. Bypassing it is the habit it exists to stop.
EOF
    exit 1
fi

if [[ "$checked" -eq 0 ]]; then
    say "CANNOT VERIFY: no repo checkouts resolved. Failing closed." >&2
    exit 3
fi

if [[ "$unchecked" -gt 0 ]]; then
    say "GREEN, PARTIAL: every written fix in the ${checked} repo(s) CHECKED HERE is"
    say "shipping or consciously deferred. ${unchecked} repo(s) were not examined."
    exit 0
fi
say "GREEN: every written fix is either shipping or consciously deferred."
exit 0
