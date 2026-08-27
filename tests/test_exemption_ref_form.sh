#!/usr/bin/env bash
# test_exemption_ref_form.sh -- a pr_exemptions ref whose FORM its consumer
# cannot generate is silently inert, and silence is what a WORKING exemption
# looks like.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS, MEASURED 2026-08-27 on origin/main 05d72954
# ─────────────────────────────────────────────────────────────────────────────
# cut-deferrals.yaml carries TWO blocks whose rows look identical -- both spell
# their entries `- ref: "..."` -- but they are consumed by DIFFERENT gates that
# generate DIFFERENT key forms:
#
#   pr_exemptions:   (line 34)   read by scripts/verify_pr_age.sh
#                                which generates  ref="${repo#*/}#${num}"
#                                i.e.  CM051-Home-Hub-Installer#982
#
#   deferrals:       (line 289)  read by scripts/verify_no_orphaned_fixes.sh
#                                which generates  key="${label}:#${num}"
#                                          or     key="${label}:${branch}"
#                                i.e.  CM051:#982   /   CM051:fix/some-branch
#
# Two namespaces, one file, one row shape. Measured in the pr_exemptions block:
#
#     23 refs total
#     21  repo-name#N   -- match verify_pr_age.sh, these work
#      2  label:#N      -- CM051:#982 and CM051:#975. INERT.
#
# Both dead ones are shadowed by a correctly-spelled duplicate of the SAME PR
# sitting a line away:
#
#     - ref: "CM051:#982"                    <- inert
#     - ref: "CM051-Home-Hub-Installer#982"  <- the one that works
#
# That pair is the whole story. Somebody wrote the colon form, it did nothing,
# and they added the working form WITHOUT removing the dead one -- so the file
# already records a person hitting this. Today the impact is zero, purely
# because the duplicate exists. The next wrong spelling will not have one.
#
# 🔴 AN EXEMPTION THAT MATCHES NOTHING IS WORSE THAN NO EXEMPTION.
# No exemption reds the gate and you go and fix it. A dead exemption reds the
# gate while a human believes it is recorded, reasoned and accounted for -- so
# the red gets read as the gate being wrong. Same shape as OS003 #164's
# dangling capability_id: a NAME that resolves to nothing reads as a guarantee.
#
# WHAT THIS GUARDS, AND WHAT IT DELIBERATELY DOES NOT
# It checks FORM ONLY -- that a ref in pr_exemptions is shaped like something
# verify_pr_age.sh could emit. It does NOT check the repo exists, the PR exists,
# or that the exemption is justified. Form is the part that fails SILENTLY;
# the rest fails loudly or is a human judgement.
#
# NOT NORMALISED ON READ, DELIBERATELY. Teaching verify_pr_age.sh to accept
# `CM051:#982` too would make both spellings work and hide the fact that the
# file is serving two key namespaces. The next person still would not know
# which block they are writing in. A red at write time tells them.
#
# EXIT  0 = every pr_exemptions ref is in a form its consumer can generate
#       1 = FAIL
#       3 = CANNOT-RUN (file or block missing, or the block parsed to zero rows)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFERRALS="${OSTLER_CUT_DEFERRALS:-$HERE/cut-deferrals.yaml}"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }
cannot(){ printf '\n  CANNOT-RUN  %s\n\n0 passed, 0 failed, 1 could not run\n' "$1" >&2; exit 3; }

# ---------------------------------------------------------------------------
# THE PARSER. Bounded by LINE NUMBER between the two block headers, because a
# range that runs to EOF swallows the next block.
#
# 🔴 THIS IS NOT A HYPOTHETICAL. Building this test I ran
#     sed -n '/^pr_exemptions:/,$p'
# and got 681 refs -- pr_exemptions (23) PLUS the whole deferrals block (658) --
# then classified the lot and published "660 of 681 exemptions are inert". The
# 658 were deferrals rows, correctly spelled for the gate that reads them. The
# real number is 2 of 23. An unvalidated RANGE is a predicate like any other:
# it has to be proved before its output is counted.
# ---------------------------------------------------------------------------
block_refs() {  # $1 = block name -> refs on stdout
    local name="$1" start end
    start="$(grep -nE "^${name}:" "$DEFERRALS" | head -1 | cut -d: -f1)"
    [[ -n "$start" ]] || return 1
    # end = the next top-level key after start, or EOF
    end="$(awk -v s="$start" 'NR>s && /^[a-z_]+:/ {print NR-1; exit}' "$DEFERRALS")"
    [[ -n "$end" ]] || end="$(wc -l < "$DEFERRALS")"
    sed -n "$((start+1)),${end}p" "$DEFERRALS" \
      | grep -E '^[[:space:]]*-[[:space:]]*ref:' \
      | sed -E 's/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*"?//; s/"?[[:space:]]*$//'
}

# The form verify_pr_age.sh:175 emits: ref="${repo#*/}#${num}".
# Repo names may carry dots and hyphens; the number is bare digits.
PR_AGE_FORM='^[A-Za-z0-9._-]+#[0-9]+$'

main_check() {
    [[ -f "$DEFERRALS" ]] || cannot "no cut-deferrals.yaml at $DEFERRALS -- nothing was checked."

    local refs n
    refs="$(block_refs pr_exemptions)" || cannot "no pr_exemptions: block in $DEFERRALS."
    n="$(printf '%s\n' "$refs" | grep -c . || true)"

    # ANTI-VACUITY. A parser that silently returns nothing would report a clean
    # sweep over zero rows, which is the exact failure this file is about.
    (( n > 0 )) || cannot "pr_exemptions parsed to ZERO refs. That is a broken parser, not a clean file."

    printf '\n=== pr_exemptions ref form (%s refs) ===\n\n' "$n"

    local bad_n=0 r
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        if [[ ! "$r" =~ $PR_AGE_FORM ]]; then
            bad "'$r' is not a form scripts/verify_pr_age.sh can generate"
            printf '       it emits <repo-name>#<number>, e.g. CM051-Home-Hub-Installer#982\n' >&2
            printf '       '"'"'<label>:#<n>'"'"' is the DEFERRALS key form -- different block, different gate\n' >&2
            bad_n=$((bad_n+1))
        fi
    done <<< "$refs"

    if (( bad_n == 0 )); then
        ok "all $n refs are in <repo-name>#<number> form"
    fi

    printf '\n%s passed, %s failed\n' "$pass" "$fail"
    (( fail == 0 ))
}

self_test() {
    # A gate nobody has watched go red is indistinguishable from one that cannot.
    local tmp rc t_pass=0 t_fail=0
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

    _expect() { # <label> <want-rc> <file-body>
        local label="$1" want="$2" body="$3"
        printf '%s' "$body" > "$tmp/d.yaml"
        OSTLER_CUT_DEFERRALS="$tmp/d.yaml" DEFERRALS="$tmp/d.yaml" \
          bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; rc=$?
        if [[ "$rc" == "$want" ]]; then
            printf '  ok   %-52s rc=%s\n' "$label" "$rc"; t_pass=$((t_pass+1))
        else
            printf '  FAIL %-52s rc=%s want=%s\n' "$label" "$rc" "$want"; t_fail=$((t_fail+1))
        fi
    }

    printf '\n=== self-test: exemption ref form ===\n\n'

    # GREEN -- the positive control. Without it a script that returned 1
    # unconditionally would pass every red below and be worthless.
    _expect "a correctly-spelled block is GREEN" 0 \
'pr_exemptions:
  - ref: "CM051-Home-Hub-Installer#982"
    review_by: "2026-09-01"
deferrals:
  - ref: "CM051:#1"
'

    # RED -- the live defect, exactly as it sits in the real file.
    _expect "label:#N in pr_exemptions is RED" 1 \
'pr_exemptions:
  - ref: "CM051:#982"
    review_by: "2026-09-01"
deferrals:
  - ref: "CM051:#1"
'

    # RED -- branch form. Separate from the above because a predicate loosened
    # to "anything containing #" would still red the case above and go green here.
    _expect "label:branch in pr_exemptions is RED" 1 \
'pr_exemptions:
  - ref: "CM051:fix/some-branch"
    review_by: "2026-09-01"
'

    # 🔴 THE BLOCK-BOUNDARY CONTROL. This is the one that catches the mistake I
    # actually made: if the parser runs past pr_exemptions into deferrals, these
    # correctly-spelled deferrals rows get judged by the pr_age form and the
    # result is a spectacular false RED. It MUST stay green.
    _expect "deferrals rows are NOT judged (boundary control)" 0 \
'pr_exemptions:
  - ref: "CM051-Home-Hub-Installer#982"
    review_by: "2026-09-01"
deferrals:
  - ref: "CM051:#982"
  - ref: "CM051:fix/a-branch"
  - ref: "daemon:#287"
  - ref: "CM044:working-tree"
'

    # GREEN -- block ORDER must not matter. The real file has pr_exemptions
    # first; a parser keyed to that order would break silently if it flipped.
    _expect "order-independent: deferrals first is still GREEN" 0 \
'deferrals:
  - ref: "CM051:#982"
  - ref: "CM051:fix/a-branch"
pr_exemptions:
  - ref: "CM051-Home-Hub-Installer#982"
'

    # CANNOT-RUN -- absent file. Not a pass, not a red.
    rm -f "$tmp/d.yaml"
    OSTLER_CUT_DEFERRALS="$tmp/d.yaml" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; rc=$?
    if [[ "$rc" == 3 ]]; then
        printf '  ok   %-52s rc=%s\n' "absent file is CANNOT-RUN, not a pass" "$rc"; t_pass=$((t_pass+1))
    else
        printf '  FAIL %-52s rc=%s want=3\n' "absent file is CANNOT-RUN, not a pass" "$rc"; t_fail=$((t_fail+1))
    fi

    # CANNOT-RUN -- block present but empty. The uniform-zero shape: a parser
    # that returns nothing must not read as a clean sweep.
    _expect "empty block is CANNOT-RUN, not vacuously green" 3 \
'pr_exemptions:
deferrals:
  - ref: "CM051:#1"
'

    # CANNOT-RUN -- no such block at all.
    _expect "missing block is CANNOT-RUN" 3 \
'deferrals:
  - ref: "CM051:#1"
'

    printf '\n'
    if (( t_fail )); then printf 'SELF-TEST FAILED: %s\n' "$t_fail"; return 1; fi
    printf 'SELF-TEST PASSED: %s/%s (3 red, 3 green, 3 cannot-run)\n' "$t_pass" "$t_pass"
    return 0
}

case "${1:-}" in
    --self-test) self_test ;;
    *)           main_check ;;
esac
