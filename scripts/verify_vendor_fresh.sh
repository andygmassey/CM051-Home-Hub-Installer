#!/usr/bin/env bash
# verify_vendor_fresh.sh -- THE vendor-freshness gate.
# ===================================================
#
# Kills the divergent-vendored-twin class. The DMG ships VENDORED copies of
# upstream source trees (CM041/CM048/ostler_fda/CM019/CM021/...). A fix that
# lands in a SOURCE repo does not reach the customer until it is grafted into
# vendor/. The old guard (tests/test_no_divergent_vendor_twin.sh) compared
# vendor/<pkg> against a top-level ./<pkg> twin that does NOT exist inside
# CM051 -- so it trivially passed and was BLIND to real cross-repo drift.
#
# This gate is cross-repo. For each entry in vendor/VENDOR_MANIFEST.toml it:
#   1. materialises source_repo @ pinned_sha (restricted to the vendored
#      file-set via the entry's exclude globs),
#   2. applies the recorded divergence patch (legitimate vendor-side grafts,
#      e.g. contact_syncer's identity_resolver import + en-dash house style),
#   3. diffs the result against the vendored tree -- ANY mismatch FAILS,
#   4. AND checks whether the SOURCE repo has advanced past pinned_sha for
#      the vendored sub-path; if so the vendor is STALE (an ungrafted fix) --
#      that FAILS too, naming the tree and the unshipped commits.
#
# (1)-(3) catch in-place rot / a vendor edited without a source change.
# (4) catches the headline class: a fix merged to source but never grafted.
#
# Productised: source repo paths are overridable per operator/CI (see
# _vendor_lib.sh resolve_source_repo). If a source repo is not locally
# available the tree is reported as "could not verify (source repo not
# found)" and counted as a WARNING -- never a silent pass.
#
# Exit: 0 = all verifiable trees fresh; 1 = at least one stale/divergent tree,
# OR at least one tree that could not be verified at all.
#
# FAIL-CLOSED SINCE 2026-08-15, AND HERE IS WHY IT HAD TO CHANGE.
#
# This defaulted to VENDOR_FRESH_STRICT=0. An unverifiable tree printed
# "GATE: GREEN with N warning(s)" and exited 0 -- a warn that reads as a pass,
# on the gate that guards what ships, with the reassuring word GREEN in front
# of it.
#
# The intent was never in doubt. What was missing was anyone actually setting
# the flag:
#
#   OS003/CUT_MECHANISM_CANONICAL.md:40,119  "VENDOR_FRESH_STRICT=1 ... GREEN"
#   CM051 .github/workflows/vendor-integrity.yml:106  a COMMENT promising the
#     real gate runs "with all source repos present, VENDOR_FRESH_STRICT=1"
#   OS003/pipeline/release.yml:75  the actual cut invocation:
#     `bash vendor/verify_vendor_fresh.sh`   <-- no flag
#
# Measured 2026-08-15: NOTHING anywhere sets VENDOR_FRESH_STRICT=1. Two
# documents and a comment described a strict gate; every invocation ran the
# lenient one. A mention is not an invocation.
#
# So the default is now 1. An environment that genuinely cannot verify -- CI
# without the sibling source repos checked out -- must now say so explicitly by
# setting VENDOR_FRESH_STRICT=0, which makes the degradation visible at the
# call site instead of inherited silently by everything including the cut.
#
# The asymmetry is deliberate. Getting this wrong in the lenient direction
# ships an unverified vendored tree to a customer. Getting it wrong in the
# strict direction turns one CI job red until somebody adds one word.
#
# ACKNOWLEDGED-UNVERIFIABLE, ADDED 2026-08-15, AND WHY IT IS NOT THE OLD HOLE.
#
# Making the default strict was right and is not being softened. But it left
# the gate with only two words for two very different states:
#
#   "nobody has looked at this tree and we do not know what its source is"
#   "somebody looked, measured the blocker, wrote it down, and owns fixing it"
#
# Both printed WARN, both went RED, so the second was indistinguishable from
# the first and the only way to cut was VENDOR_FRESH_STRICT=0, which drops
# strictness for EVERY tree at once. That is a blunt instrument that re-creates
# the exact false green #701 removed, just at the call site instead of the
# default.
#
# So a tree may now carry, IN THE MANIFEST, PER TREE:
#
#   unverifiable_ack        = true
#   unverifiable_ack_reason = "the measured blocker, not a description"
#   unverifiable_ack_owner  = "who is retiring it"
#
# The guardrails are the whole design, and each one closes a way this could
# have become the old hole:
#
#  1. IT ONLY APPLIES WHERE THE GATE WAS ALREADY GOING TO SAY "UNVERIFIABLE".
#     A tree that DRIFTED, or whose source ADVANCED past the pin, still FAILS
#     with an ack in place. An ack can never silence a content verdict,
#     because in that case a content verdict was actually reached. This is
#     asserted by tests/test_vendor_fresh_gate.sh scenario 6.
#  2. REASON AND OWNER ARE BOTH REQUIRED. Declaring the ack without either is
#     RED, naming the tree. An unattributed exemption is how a temporary gap
#     becomes permanent, and the sibling mechanism in verify_cut_freshness.sh
#     (verify_exempt + exempt_reason) already learned this.
#  3. THERE IS NO GLOBAL FORM. No env var, no wildcard, no "ack everything".
#     Adding a tree to this list is a manifest edit that shows up in a diff and
#     has to be defended in review.
#  4. THE COUNT IS IN THE DENOMINATOR LINE AND IN THE VERDICT. While any ack is
#     live the gate never prints a plain "GATE: GREEN". It prints GREEN WITH N
#     ACKNOWLEDGED-UNVERIFIABLE TREE(S), so a reader skimming the last line
#     cannot mistake it for a clean run -- which is the failure mode that made
#     "GATE: GREEN with N warning(s)" so dangerous.
#
# An ack is a debt with a name on it. It is not a pass, and the wording of
# every line below is chosen so that nobody can quote it as one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"

STRICT="${VENDOR_FRESH_STRICT:-1}"

fail=0
warn=0
ok=0
held=0
ackd=0
checked=0

echo "vendor-freshness gate -- manifest: $VLIB_MANIFEST"
echo

# Which ref does the advance arm compare the pin against?
#
# This used to be, flatly, `HEAD` -- whatever the operator's source checkout
# happened to be sitting on. So "source has advanced past pinned_sha" was a
# function of one machine's branch state and last fetch, which is the opposite
# of a gate. MEASURED 2026-08-15 across the checkouts this gate is normally
# pointed at:
#
#   cm059 checkouts    on main but 4 commits BEHIND origin/main (confirmed in a
#                      NON-shallow clone). The advance arm was judging the pin
#                      against a tree older than origin/main, so it could not
#                      have reported an advance that existed only in those 4.
#   cm048 checkouts    parked on unmerged feature branches -- the gate reading
#                      one agent's work in progress as though it were upstream.
#
# BE PRECISE ABOUT THE BLAST RADIUS, because overstating it is its own defect:
# for cm059 the compiler-path delta measures 0 under BOTH refs today, so this
# was latent blindness rather than a wrong number on the board. What was
# actually broken is reproducibility -- two operators, two checkouts, two
# verdicts, and nothing in the output saying why. That is fixed by resolving
# the ref explicitly AND printing it.
#
# Prefer origin/main; fall back to HEAD only when no such ref exists. The
# fallback is load-bearing: the hermetic self-test fixtures build synthetic
# source repos with no remote at all, and they must keep working.
#
# DELIBERATELY NO FETCH. A gate that reaches the network is slow and flaky, and
# fetching would HIDE a stale checkout rather than report one. The staleness is
# reported instead -- see checkout_drift below -- and the resolved ref is
# printed per tree, which is the half that makes a verdict something a second
# operator can reproduce rather than an artefact of this machine.
compare_ref() {
    local repo="$1"
    [ -n "$repo" ] && [ -d "$repo" ] || { printf 'HEAD\n'; return 0; }
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        printf 'origin/main\n'
    else
        printf 'HEAD\n'
    fi
}

# How far the checkout itself sits from the ref the pin is judged against.
# Empty when they coincide (nothing to report) or when the ref IS HEAD (the
# question is meaningless). Printed so a stale or feature-branched checkout is
# VISIBLE rather than silently changing the answer.
checkout_drift() {
    local repo="$1" ref="$2" counts behind ahead
    [ "$ref" = "HEAD" ] && return 0
    counts="$(git -C "$repo" rev-list --left-right --count "${ref}...HEAD" 2>/dev/null)" || return 0
    [ -n "$counts" ] || return 0
    behind="$(printf '%s' "$counts" | awk '{print $1}')"
    ahead="$(printf '%s' "$counts" | awk '{print $2}')"
    [ "${behind:-0}" = "0" ] && [ "${ahead:-0}" = "0" ] && return 0
    printf 'source checkout HEAD is %s ahead / %s behind %s\n' "${ahead:-0}" "${behind:-0}" "$ref"
}

# Read a tree's acknowledgement state. Prints nothing; the caller decides how
# loud to be. Three states, never two -- a declared-but-incomplete ack is its
# own answer and must not collapse into either "acked" or "not acked".
#   0 = complete ack   (declared, with BOTH a reason and an owner)
#   1 = no ack declared
#   2 = declared but incomplete (missing reason and/or owner) -> RED
ack_state() {
    local tree="$1" declared reason owner
    declared="$(vlib_field "$tree" unverifiable_ack)"
    [ "$declared" = "true" ] || return 1
    reason="$(vlib_field "$tree" unverifiable_ack_reason)"
    owner="$(vlib_field "$tree" unverifiable_ack_owner)"
    [ -n "$reason" ] && [ -n "$owner" ] || return 2
    return 0
}

# The ONE place an unverifiable tree is reported, so the ack rules cannot be
# applied at one call site and forgotten at the other. Increments exactly one
# of ackd / fail / warn.
report_unverifiable() {
    local tree="$1" detail="$2" st=0
    ack_state "$tree" || st=$?
    case "$st" in
        0)
            echo "ACK   $tree -- UNVERIFIABLE, acknowledged in writing (owner: $(vlib_field "$tree" unverifiable_ack_owner))"
            echo "        NOT VERIFIED. Declared, with a reason and an owner: $(vlib_field "$tree" unverifiable_ack_reason)"
            ackd=$((ackd + 1))
            ;;
        2)
            echo "FAIL  $tree -- unverifiable_ack is declared but INCOMPLETE." >&2
            echo "        It requires BOTH unverifiable_ack_reason and unverifiable_ack_owner." >&2
            echo "        An exemption with nobody's name on it is how a temporary gap becomes" >&2
            echo "        permanent, so an incomplete one is refused rather than honoured." >&2
            fail=$((fail + 1))
            ;;
        *)
            echo "WARN  $tree -- $detail"
            warn=$((warn + 1))
            ;;
    esac
}

# Does the source sub-path have commits newer than pinned_sha?
# Prints one line per unshipped commit, "<full-sha> <subject>" (empty if up to
# date). FULL sha, not %h: it is fed to vlib_sha_in_list, and an abbreviation
# short enough to be ambiguous would acknowledge a commit nobody acknowledged.
# Display abbreviates again at the print site.
unshipped_commits() {
    local tree="$1" ref="$2"
    local repo subpath sha
    repo="$(resolve_source_repo "$tree")"
    subpath="$(vlib_field "$tree" source_path)"
    sha="$(vlib_field "$tree" pinned_sha)"
    [ "$sha" = "WORKING_TREE" ] && return 0
    [ -d "$repo" ] || return 0
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
    local pathspec="."
    [ -n "$subpath" ] && [ "$subpath" != "." ] && pathspec="$subpath"
    # Commits on the resolved ref that touch the vendored sub-path and are not
    # ancestors of pinned_sha.
    git -C "$repo" log --format='%H %s' "${sha}..${ref}" -- "$pathspec" 2>/dev/null
}

# Print a "<full-sha> <subject>" list the way the gate has always shown it:
# indented, sha abbreviated to 7.
print_commits() {
    # `NF` skips blank lines. The unacked list is accumulated with a trailing
    # newline, so without this the caller's `printf '%s\n'` emitted one final
    # empty record and the gate printed a phantom eight-space commit under a
    # list of real ones. Small, but this is the output an operator classifies
    # commit by commit, and an entry that names nothing invites a guess.
    awk 'NF { printf "        %s %s\n", substr($1, 1, 7), substr($0, index($0, " ") + 1) }'
}

while IFS= read -r tree; do
    [ -z "$tree" ] && continue
    checked=$((checked + 1))
    vendor_path="$(vlib_field "$tree" vendor_path)"
    abs_vendor="$VLIB_REPO_ROOT/$vendor_path"

    verify="$(vlib_field "$tree" verify)"
    if [ "$verify" = "skip" ]; then
        reason="$(vlib_field "$tree" note)"
        report_unverifiable "$tree" "verification skipped: ${reason:-marked verify=skip}"
        continue
    fi

    if [ ! -d "$abs_vendor" ]; then
        echo "FAIL  $tree -- vendored tree missing on disk: $vendor_path" >&2
        fail=$((fail + 1))
        continue
    fi

    tmp="$(mktemp -d)"
    rc=0
    vlib_materialise "$tree" "$tmp" || rc=$?

    if [ "$rc" = "2" ] || [ "$rc" = "3" ]; then
        # Source not available / sha absent -> warning, not a silent pass.
        report_unverifiable "$tree" "could not verify (see above)"
        rm -rf "$tmp"
        continue
    fi

    # Apply the recorded legitimate divergence.
    if ! vlib_apply_patch "$tree" "$tmp"; then
        echo "FAIL  $tree -- divergence patch failed to apply (source moved under the patch; re-graft)" >&2
        fail=$((fail + 1))
        rm -rf "$tmp"
        continue
    fi

    # Compare ONLY files present in BOTH source@sha+patch and the vendored
    # tree. Source-only files (tests/, un-vendored src/) and vendor-only files
    # (grafts) are out of scope -- "stale" means a shared file has drifted.
    if vlib_vendor_diff "$tree" "$tmp" "$abs_vendor" "$tmp.diff"; then
        content_ok=1
    else
        content_ok=0
    fi

    # Has the source advanced past the pin without a re-graft? Judged against
    # an EXPLICIT ref (origin/main where it exists), never the checkout's
    # incidental HEAD -- see compare_ref.
    src_repo="$(resolve_source_repo "$tree" || true)"
    src_ref="$(compare_ref "$src_repo")"
    src_drift="$(checkout_drift "$src_repo" "$src_ref" || true)"
    behind="$(unshipped_commits "$tree" "$src_ref" || true)"

    # A pin sitting behind source HEAD is allowed ONLY via a hold_ack that
    # acknowledges EVERY commit in the delta, records WHY, and asserts the
    # shipping bugfixes among them are grafted. Identical ladder, identical
    # parser (vlib_sha_in_list / vlib_manifest_bool) to verify_cut_freshness.sh
    # -- see the hold_ack section of scripts/_vendor_lib.sh for why this is
    # shared rather than reimplemented.
    #
    # advance_verdict: clean | none | unacked | no-grafted-assert | no-reason
    #   clean  = up to date, OR fully held. Never fails this arm.
    advance_verdict="clean"
    unacked=""
    if [ -n "$behind" ]; then
        hold_shas="$(vlib_field "$tree" hold_ack_shas)"
        hold_reason="$(vlib_field "$tree" hold_ack_reason)"
        grafted="$(vlib_manifest_bool "$tree" shipping_bugfixes_grafted)"
        if [ -z "$hold_shas" ]; then
            # No ledger at all: every delta commit is un-acknowledged.
            advance_verdict="none"
            unacked="$behind"
        else
            while IFS= read -r _c; do
                [ -z "$_c" ] && continue
                vlib_sha_in_list "${_c%% *}" "$hold_shas" && continue
                unacked="${unacked}${_c}
"
            done <<EOF
$behind
EOF
            if [ -n "$unacked" ]; then
                advance_verdict="unacked"
            elif [ "$grafted" != "true" ]; then
                advance_verdict="no-grafted-assert"
            elif [ -z "$hold_reason" ]; then
                advance_verdict="no-reason"
            fi
        fi
    fi

    # Report the checkout's own state whatever the verdict: a green produced by
    # a checkout parked 4 commits behind the ref is not the same green as one
    # produced by a current checkout, and the reader has to be able to tell.
    if [ -n "$src_drift" ]; then
        echo "      note: $tree -- $src_drift (the pin was judged against $src_ref, not that HEAD)"
    fi

    if [ "$content_ok" = "1" ] && [ "$advance_verdict" = "clean" ]; then
        pin8="$(vlib_field "$tree" pinned_sha | cut -c1-8)"
        if [ -n "$behind" ]; then
            # Fresh in content, and every source commit past the pin is on the
            # ledger. Say the number out loud: a hold is a decision that has to
            # stay visible, not a silence. Left in place after its commits land,
            # a hold_ack is a permanently-exempt path -- discharge them.
            held=$((held + 1))
            echo "OK    $tree -- vendor == source@$pin8 (+patch) [vs $src_ref]; $(printf '%s\n' "$behind" | grep -c .) source commit(s) HELD by hold_ack"
        else
            echo "OK    $tree -- vendor == source@$pin8 (+patch) [vs $src_ref]"
        fi
        ok=$((ok + 1))
    else
        if [ "$content_ok" != "1" ]; then
            echo "FAIL  $tree -- vendored tree DIFFERS from source@pinned_sha+patch:" >&2
            # NO `| head`. This was `sed ... | head -40`, and under the
            # `set -euo pipefail` at the top of this file that KILLED THE WHOLE
            # GATE with SIGPIPE (exit 141) the first time a tree produced a
            # diff bigger than the pipe buffer: head exits at 40 lines, sed
            # takes SIGPIPE, pipefail promotes 141 to the pipeline status, and
            # set -e ends the run. No summary line, no denominator, no verdict.
            #
            # It hid for as long as it did because it needs BOTH a resolvable
            # source repo AND a large divergence. With the eight ${VAR}
            # placeholders unset, zero trees were ever materialised, so nothing
            # ever diffed and the gate always finished in about a second.
            # MEASURED 2026-08-15: with the source repos exported, this line
            # took the run down at rc=141 before it printed anything.
            #
            # sed -n with a range does the same job in ONE process, so there is
            # no reader to close the pipe and no writer to signal. The repo
            # already learned this once -- scripts/select_pinned_xcode.sh says
            # outright why `grep ... | head -1` appears nowhere in it.
            sed -n '1,40{s/^/        /;p;}' "$tmp.diff" >&2
            # Also an `if`, not `[ ... ] && echo`: as the last statement in a
            # branch, a false test makes the && list return non-zero, which is
            # its own set -e hazard.
            if [ "$(wc -l < "$tmp.diff")" -gt 40 ]; then
                echo "        ... (diff truncated)" >&2
            fi
        fi
        case "$advance_verdict" in
            none)
                echo "FAIL  $tree -- source ($src_ref) has advanced past pinned_sha; UNGRAFTED commits:" >&2
                printf '%s\n' "$unacked" | print_commits >&2
                echo "        -> classify each: graft it (scripts/sync_vendor.sh $tree), or add its" >&2
                echo "           SHA to hold_ack_shas with hold_ack_reason + shipping_bugfixes_grafted = true." >&2
                ;;
            unacked)
                echo "FAIL  $tree -- source ($src_ref) has advanced past pinned_sha; delta commit(s) NOT in hold_ack_shas:" >&2
                printf '%s\n' "$unacked" | print_commits >&2
                echo "        -> classify each: graft it (scripts/sync_vendor.sh $tree), or add its" >&2
                echo "           SHA to hold_ack_shas with a reason." >&2
                ;;
            no-grafted-assert)
                echo "FAIL  $tree -- hold_ack covers the whole delta but shipping_bugfixes_grafted is not true." >&2
                echo "        -> graft the bugfixes among the held commits, then assert it." >&2
                ;;
            no-reason)
                echo "FAIL  $tree -- hold_ack_shas is present but hold_ack_reason is empty." >&2
                echo "        -> record WHY the pin is held. An unexplained hold is an expiring exemption nobody can audit." >&2
                ;;
        esac
        fail=$((fail + 1))
    fi
    rm -rf "$tmp" "$tmp.diff"
done < <(vlib_tree_names)

echo
# The held count is APPENDED rather than spliced into the middle: the
# denominator assertions in tests/test_vendor_src_placeholder_unset.sh parse
# "N tree(s)" and ", N unverifiable" out of this line, and a held tree is a
# fresh tree with a declared debt, not a fourth bucket in the arithmetic.
held_note=""
if [ "$held" -gt 0 ]; then
    held_note=" ($held of the fresh HELD by hold_ack -- discharge when the held commits land)"
fi
# TWO SEPARATE UNVERIFIABLE COUNTS, on purpose: collapsing them into one number
# is precisely what let "not looked at" hide inside "known gap".
#
# NOTE THE WORDING OF THE SECOND ONE. It is "acknowledged-unverifiable", NOT
# "unverifiable (ACKNOWLEDGED)", and that is load-bearing rather than a style
# choice. The legacy assertion in tests/test_vendor_src_placeholder_unset.sh
# pulls the unverifiable count out with a GREEDY `.*, ([0-9]+) unverifiable.*`,
# which binds to the RIGHTMOST match. Phrasing the ack count as ", N
# unverifiable (...)" would therefore silently re-point that assertion at the
# acknowledged number, so a rising UNKNOWN count could hide behind a steady ack
# count. Hyphenating it leaves no ", N unverifiable" to the right, so the old
# parse keeps reading the UNKNOWN bucket, which is the one it exists to watch.
echo "vendor-freshness: $checked tree(s) -- $ok fresh, $fail stale/divergent, $warn unverifiable (UNKNOWN), $ackd acknowledged-unverifiable$held_note"

# ---------------------------------------------------------------------------
# ANTI-VACUITY FLOOR. Read this before touching the verdicts below.
#
# THE DEFECT THIS CLOSES (A2's silence sweep, 2026-09-02, tier 3 item 6).
# Every verdict below is computed from counters. If the manifest goes missing,
# is renamed, or the parser dies, ALL the counters stay at their initial 0, no
# branch above fires, and control reaches the final `else` -- which prints
#     GATE: GREEN -- every vendored tree matches its pinned source.
# and exits 0, HAVING EXAMINED NOTHING. That sentence would be a lie of the
# worst available kind, because this is the gate that decides whether
# UNVERIFIED VENDORED CODE SHIPS TO CUSTOMERS. A zero denominator reads as
# success, and the process substitution that feeds the loop discards the
# parser's non-zero exit, so nothing else would notice.
#
# WHY THE FLOOR IS AN EQUALITY AND NOT `checked > 0`.
# `> 0` would close the total-failure case and leave the more likely one open.
# The manifest uses TWO indentation conventions (#529: 15 rows unindented, 9
# indented, 24 total), so a reader with a `^`-anchored pattern silently sees
# 15 of 24 and skips nine trees while looking perfectly healthy. A `> 0` floor
# passes that. An equality does not.
#
# WHY grep AND NOT THE PARSER. Two instruments on one number is the best
# evidence available; asking the parser to confirm its own count would be a
# control that fails for the same reason as its subject. This grep is
# deliberately dumb and deliberately NOT `^`-anchored, so it counts rows under
# either indentation convention.
#
# CANNOT-RUN, NOT FAIL. Exit 2, distinct from the RED exit 1 below: "the gate
# could not look" is a third state, and collapsing it into either of the other
# two is the exact class this floor exists to refuse.
_declared_rows="$(grep -cE '^[[:space:]]*name[[:space:]]*=' "$VLIB_MANIFEST" 2>/dev/null || true)"
_declared_rows="${_declared_rows:-0}"
if [ "$_declared_rows" -eq 0 ]; then
    echo "GATE: CANNOT-RUN -- read 0 tree declarations from the manifest." >&2
    echo "      Expected: $VLIB_MANIFEST" >&2
    echo "      This is NOT a pass. The gate examined nothing, and an unexamined" >&2
    echo "      vendored tree is exactly the state it exists to refuse. Check the" >&2
    echo "      manifest exists and is readable, then re-run." >&2
    exit 2
fi
if [ "$checked" -ne "$_declared_rows" ]; then
    echo "GATE: CANNOT-RUN -- the manifest declares $_declared_rows tree(s) and the gate examined $checked." >&2
    echo "      A partial parse is not a partial pass: the $((_declared_rows - checked)) unexamined tree(s)" >&2
    echo "      would ship unverified while this gate printed a verdict about the others." >&2
    echo "      The two counts come from independent instruments on purpose (grep over the" >&2
    echo "      manifest vs the gate's own parser), so a disagreement means one of them is" >&2
    echo "      wrong and neither result can be trusted until that is settled." >&2
    exit 2
fi

if [ "$fail" -gt 0 ]; then
    echo "GATE: RED -- $fail tree(s) are stale or have drifted from source." >&2
    exit 1
fi

if [ "$warn" -gt 0 ] && [ "$STRICT" = "1" ]; then
    echo "GATE: RED -- $warn tree(s) could NOT BE VERIFIED." >&2
    echo "      Not verified is not the same as verified fresh. This gate guards" >&2
    echo "      what ships; an unverifiable vendored tree is exactly the state it" >&2
    echo "      exists to refuse." >&2
    echo "      Check the source repos out, or set VENDOR_FRESH_STRICT=0 at the" >&2
    echo "      call site to accept the degradation ON PURPOSE and in writing." >&2
    exit 1
fi

if [ "$warn" -gt 0 ]; then
    # Reached only when a caller has explicitly opted out. Do NOT print GREEN.
    # The previous wording was "GATE: GREEN with N warning(s)", which is the
    # whole defect in one line: the reader takes the first word and moves on.
    echo "GATE: DEGRADED -- $warn tree(s) NOT VERIFIED (VENDOR_FRESH_STRICT=0 was set explicitly)."
    echo "      $ok tree(s) were checked and are fresh. The other $warn were not checked at all."
    echo "      This is not a pass for those trees. The cut must run with all source"
    echo "      repos present and the default strictness."
    if [ "$ackd" -gt 0 ]; then
        echo "      A further $ackd tree(s) are acknowledged-unverifiable in the manifest."
    fi
elif [ "$ackd" -gt 0 ]; then
    # Deliberately NOT the word GREEN on its own. Every ack is a tree nobody
    # checked; the only thing that changed is that we now know which trees, why,
    # and whose job it is. Say the number out loud in the verdict as well as the
    # denominator, because the verdict is the line people quote.
    echo "GATE: GREEN WITH $ackd ACKNOWLEDGED-UNVERIFIABLE TREE(S) -- $ok tree(s) verified fresh."
    echo "      Those $ackd were NOT checked against their source. Each is declared in"
    echo "      vendor/VENDOR_MANIFEST.toml with a measured reason and a named owner, which"
    echo "      makes the gap auditable. It does not make it verified, and it is not a pass"
    echo "      for those trees. Retire them; do not inherit them."
else
    echo "GATE: GREEN -- every vendored tree matches its pinned source."
fi
exit 0
