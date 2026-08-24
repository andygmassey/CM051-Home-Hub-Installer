#!/usr/bin/env bash
#
# test_no_orphaned_fixes_gate.sh
#
# Proves the orphaned-fix gate can actually FAIL. A gate that cannot go red is
# decoration -- and this repo has shipped four of those (the June
# zeroclaw-desktop -> ostler-hub rename left four gates silently SKIPping, one
# of which returned PASS for a target that no longer existed).
#
# Every case here is a real shape from the v1.0.15 walk, 2026-08-06:
#   (a) unmerged remote fix/ branch      -- CM044 7f1dc59, CM051 browsing
#   (b) LOCAL-ONLY branch, never pushed  -- CM051 #632, worktree, parent deleted
#   (c) dirty working tree               -- uncommitted work at cut time
#   (d) a recorded deferral is accepted  -- the escape hatch must work, or
#                                           people will bypass the gate instead
#   (e) clean repo passes                -- no false positives
#
# PR checks need network + gh auth and are exercised on the real repos, not here.
#
# Usage: bash tests/test_no_orphaned_fixes_gate.sh

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/verify_no_orphaned_fixes.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A repo with an origin, so "local-only" is meaningful.
make_repo() {
    local name="$1"
    local up="$TMP/${name}-origin" wt="$TMP/${name}"
    git init -q --bare "$up"
    git init -q "$wt" && git -C "$wt" remote add origin "$up"
    git -C "$wt" config user.email t@t.t; git -C "$wt" config user.name t
    echo base > "$wt/f.txt"
    git -C "$wt" add -A && git -C "$wt" commit -qm base
    git -C "$wt" branch -M main && git -C "$wt" push -q -u origin main
    printf '%s' "$wt"
}

run_gate() {  # $1 = checkout, $2 = deferrals file ("" for none)
    # Inject ONLY the fixture repo and skip PR lookups, so the test is
    # hermetic: no network, no gh auth, no dependence on the real repos.
    # (The first draft did not do this and hung for 10 minutes doing live
    # `git fetch` + `gh pr list` against every real repo. A test that needs
    # the network is a test nobody runs.)
    # 🔴 AND THE EXPIRY BASELINE IS ISOLATED, PER CALL.
    #
    # Every fixture here declares `until_cut: v1.0.17`. The gate derives the
    # version being cut from GITHUB_REF_NAME, which on a tag push IS THE TAG --
    # so from v1.0.18 onward these synthetic deferrals are EXPIRED, land in the
    # expired set, are absent from the PRODUCTION baseline, and fire the ratchet.
    #
    # That is not theory. It stopped the v1.0.44 cut dead at step 7 on
    # 2026-08-24, after which `Build, sign, notarise, staple` was SKIPPED and no
    # DMG existed. Measured on origin/main 98c46018:
    #
    #     GITHUB_REF_NAME unset / v1.0.17   5 passed, 0 failed
    #     GITHUB_REF_NAME v1.0.43 / v1.0.44 4 passed, 1 failed
    #
    # A self-test whose fixtures write into the production ledger it is judging
    # is an instrument measuring itself. Each call gets its own baseline file.
    local baseline="${TMP}/baseline.$$.$RANDOM"
    : > "$baseline"
    OSTLER_CUT_DEFERRALS="${2:-/nonexistent}" \
    OSTLER_EXPIRED_BASELINE="${3:-$baseline}" \
    OSTLER_ORPHAN_GATE_SKIP_PR=1 \
    OSTLER_ORPHAN_GATE_REPOS="CM044|$1|origin/main|" \
        bash "$GATE" 2>&1
}

printf '== test_no_orphaned_fixes_gate ==\n'

# (a) unmerged remote fix/ branch -> RED
R="$(make_repo unmerged)"
git -C "$R" checkout -q -b fix/thing && echo x > "$R/x.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: a real fix nobody merged"
git -C "$R" push -q -u origin fix/thing && git -C "$R" checkout -q main
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "fix/thing"; then
    ok "unmerged remote fix/ branch goes RED"
else
    bad "unmerged remote fix/ branch did NOT go red (rc=$rc)"
fi

# (b) LOCAL-ONLY branch -> RED  (the #632 class)
R="$(make_repo localonly)"
git -C "$R" checkout -q -b fix/never-pushed && echo y > "$R/y.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: lives on one machine only"
git -C "$R" checkout -q main
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "LOCAL-ONLY"; then
    ok "local-only branch goes RED and is named as LOCAL-ONLY"
else
    bad "local-only branch did NOT go red (rc=$rc) -- this is the #632 shape"
fi

# (c) dirty tree -> RED
R="$(make_repo dirty)"; echo scratch > "$R/uncommitted.txt"
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "working-tree"; then
    ok "dirty working tree goes RED"
else
    bad "dirty working tree did NOT go red (rc=$rc)"
fi

# (d) a recorded deferral is accepted, and still printed
R="$(make_repo deferred)"
git -C "$R" checkout -q -b fix/later && echo z > "$R/z.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: deliberately next cut"
git -C "$R" push -q -u origin fix/later && git -C "$R" checkout -q main
DEF="$TMP/deferrals.yaml"
cat > "$DEF" <<'YAML'
deferrals:
  - ref: "CM044:fix/later"
    reason: "lands in v1.0.17, needs a design pass first"
    until_cut: "v1.0.17"
YAML
# The baseline this case is judged against DECLARES this ref already-expired.
# That is the ratchet's actual contract -- the expired set may SHRINK and may
# not GROW -- so a debt already on the books must not fire it. Supplying an
# empty baseline here instead would make the case fail for a reason that has
# nothing to do with whether a deferral is accepted, which is what it tests.
DEF_BASE="$TMP/deferral-baseline.txt"
printf '%s\n' "CM044:fix/later" > "$DEF_BASE"
out="$(run_gate "$R" "$DEF" "$DEF_BASE")"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "DEFERRED"; then
    ok "recorded deferral passes AND is still printed"
else
    bad "recorded deferral did not pass cleanly (rc=$rc)"
fi

# (e) clean repo -> GREEN (no false positives)
R="$(make_repo clean)"
out="$(run_gate "$R")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "clean repo passes (no false positive)"
else
    bad "clean repo wrongly went red (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# (f) 🔴 THE EXPIRY RATCHET MUST STILL FIRE. This is the arm that stops (d)'s
#     isolation from turning the ratchet off entirely.
#
#     Isolating the baseline in run_gate is what unblocks the cut. Done alone it
#     would be indistinguishable from deleting the ratchet: every synthetic
#     deferral would land in an empty per-call baseline and nothing would ever
#     be "new". So this case supplies an EMPTY baseline and a deferral that IS
#     expired against the cut being made, and requires RED.
#
#     Without this, (d) passing proves only that the gate can be made quiet.
# ---------------------------------------------------------------------------
R="$(make_repo ratchet)"
git -C "$R" checkout -q -b fix/expired-thing && echo e > "$R/e.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: expired deferral"
git -C "$R" push -q -u origin fix/expired-thing && git -C "$R" checkout -q main
DEF_EXP="$TMP/deferrals-expired.yaml"
cat > "$DEF_EXP" <<'YAML'
deferrals:
  - ref: "CM044:fix/expired-thing"
    reason: "said it would land in v1.0.17 and did not"
    until_cut: "v1.0.17"
YAML
EMPTY_BASE="$TMP/empty-baseline.txt"; : > "$EMPTY_BASE"
out="$(GITHUB_REF_NAME=v1.0.99 run_gate "$R" "$DEF_EXP" "$EMPTY_BASE")"; rc=$?
if [[ $rc -ne 0 ]]; then
    ok "CONTROL: a NEWLY-expired deferral absent from the baseline still goes RED (rc=$rc)"
else
    bad "CONTROL FAILED: expired deferral did not fire the ratchet -- isolation has silenced it"
fi

# ---------------------------------------------------------------------------
# (g) 🔴 AN UNWRITEABLE EXPIRED-SET IS CANNOT-RUN, NEVER A PASS.
#
#     The gate created its scratch file with `mktemp -t ostler-expired-refs`.
#     That form -- a template with no X's -- is BSD-only; GNU refuses it with
#     "too few X's in template". On every GNU host, which is ubuntu-latest where
#     preflight runs on EVERY PR, the command failed, EXPIRED_REFS was empty,
#     and `sort ... || : > "$EXPIRED_REFS.sorted"` swallowed it into an empty
#     file. The ratchet then compared nothing to a 430-ref baseline and said
#     nothing.
#
#     MEASURED 2026-08-24 by stubbing exactly that failure into PATH and
#     changing nothing else, same shell, same GITHUB_REF_NAME=v1.0.44:
#
#         real mktemp        4 passed, 1 failed   <- ratchet FIRES
#         mktemp -t fails    5 passed, 0 failed   <- ratchet SILENT
#
#     So the expiry half was inert on the surface it runs on most, and fired
#     only on the macOS cut job. This case pins the distinction the fix makes:
#     a gate that cannot create its own working file must EXIT 2, not exit 0.
# ---------------------------------------------------------------------------
STUBDIR="$TMP/stub-mktemp"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/mktemp" <<'STUB'
#!/usr/bin/env bash
# Refuse ONLY the expired-refs template, the way GNU mktemp refuses a template
# with no X's while every other call in the script succeeds.
#
# 🔴 THE FIRST VERSION OF THIS STUB REFUSED EVERYTHING, AND THAT MADE THIS CASE
# WORTHLESS. Reverting the EXPIRED_REFS guard still exited 2, because the
# CONSULTED_REFS guard one line below caught it -- so the case passed while the
# thing it names was broken. Measured: two mutations that should have killed it
# both scored 7/0. Narrowing the stub to the one template makes the case pin
# the one guard it claims to.
for a in "$@"; do
    case "$a" in
        *expired-refs*) echo "mktemp: too few X's in template (test stub)" >&2; exit 1 ;;
    esac
done
exec /usr/bin/mktemp "$@"
STUB
chmod +x "$STUBDIR/mktemp"
R="$(make_repo cannotrun)"
out="$(PATH="$STUBDIR:$PATH" run_gate "$R")"; rc=$?
if [[ $rc -eq 2 ]] && printf '%s' "$out" | grep -q "CANNOT-RUN"; then
    ok "unwriteable expired-set is CANNOT-RUN (exit 2), not a silent pass"
else
    bad "an unwriteable expired-set returned rc=$rc -- the ratchet can still go inert and report green"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
