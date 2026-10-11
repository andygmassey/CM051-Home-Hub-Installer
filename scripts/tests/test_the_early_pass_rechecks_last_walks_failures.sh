#!/usr/bin/env bash
# scripts/tests/test_the_early_pass_rechecks_last_walks_failures.sh
# ============================================================================
# The early repeat-failure pass: ttywalk re-asks the PREVIOUS walk's failed
# probes, read-only, right after the install, so a repeat failure shows within
# minutes. Three things must hold and each is measured here by an oracle that
# cannot be fooled by a log line:
#
#   A. run_box_walk.sh --only takes a comma-separated LIST and runs exactly
#      those probes (oracle: a RAN file each stub probe appends to).
#   B. A missing or unreadable previous record gives CANNOT-RUN (early), never
#      an empty pass (oracle: output text AND the RAN file stays empty).
#   C. The early pass makes no writes (oracle: sentinels from stubbed seed and
#      wiki writers, a stubbed ssh, and a pre-set verdicts file that must stay
#      empty), seed-dependent probes are CANNOT-RUN (early), and the full walk
#      keeps its order and is not wired to the early pass's result.
#
# Every arm that asserts an absence is paired with a positive control, so a
# stub that was never wired cannot read as "no write happened".
#
# Red on the old code: copy this file into a checkout of origin/main and run it
# with REPO_UNDER_TEST pointing there (see the PR for the recorded run).
#
# EXIT 0 all pass, 1 a check failed, 2 CANNOT-RUN. BASH 3.2. Synthetic data only.
# ============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_UNDER_TEST:-$(cd "$HERE/../.." && pwd)}"
SRC="${REPO}/scripts/box_walk_probes"
[ -f "${SRC}/run_box_walk.sh" ] || { echo "CANNOT-RUN: no runner at ${SRC}/run_box_walk.sh"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "CANNOT-RUN: perl (alarm wrapper) not found"; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no scratch dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A fake ssh that leaves a sentinel if anything shells out to a box.
BIN="${WORK}/bin"; mkdir -p "$BIN"
cat > "${BIN}/ssh" <<EOF
#!/bin/sh
touch "${WORK}/ssh_called"
printf 'ABSENT'
EOF
chmod +x "${BIN}/ssh"

# Stage a tree: the real runner and libs, stub probes, stub writers.
# Probes: alpha_probe (FAILs), beta_probe (PASSes), gamma_probe (PASSes), and
# assistant_answers_grounded (a name in the runner's SEED_DEPENDENT_PROBES).
_stage() {   # $1 = name -> prints the scripts/ dir of the staged tree
    local r="${WORK}/$1"
    mkdir -p "$r/scripts" "$r/walks" "$r/store"
    cp -R "$SRC" "$r/scripts/box_walk_probes"
    [ -f "${REPO}/scripts/early_repeat_fail_pass.sh" ] && cp "${REPO}/scripts/early_repeat_fail_pass.sh" "$r/scripts/"
    [ -f "${REPO}/scripts/walk_promote_scope.tsv" ] && cp "${REPO}/scripts/walk_promote_scope.tsv" "$r/scripts/"
    local pd="$r/scripts/box_walk_probes/probes"
    rm -f "$pd"/*.sh
    local n
    for n in alpha_probe beta_probe gamma_probe assistant_answers_grounded; do
        local verdict='echo "VERDICT: PASS -- stub"; exit 0'
        [ "$n" = "alpha_probe" ] && verdict='echo "VERDICT: FAIL -- stub finding"; exit 1'
        cat > "$pd/$n.sh" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "--self-test" ] && exit 1
echo "$n" >> "\${RAN_FILE:-/dev/null}"
$verdict
EOF
    done
    chmod +x "$pd"/*.sh
    local sd="${WORK}/sent-$1"; mkdir -p "$sd"
    local lib="$r/scripts/box_walk_probes/lib"
    cat > "$lib/grounding_seed.sh" <<EOF
GROUNDING_SEED_STATE="unrun"
grounding_seed_apply() { touch "${sd}/grounding"; GROUNDING_SEED_STATE="seeded"; return 0; }
grounding_seed_forget() { return 0; }
EOF
    cat > "$lib/preference_seed.sh" <<EOF
preference_seed_apply() { touch "${sd}/preference"; return 0; }
preference_seed_forget() { return 0; }
EOF
    cat > "$lib/owner_employer_seed.sh" <<EOF
owner_employer_seed_apply() { touch "${sd}/owner"; return 0; }
owner_employer_seed_forget() { return 0; }
EOF
    cat > "$lib/conversation_capture_seed.sh" <<EOF
conversation_capture_seed_apply() { touch "${sd}/convcap"; return 0; }
conversation_capture_seed_forget() { return 0; }
EOF
    cat > "$lib/conversation_seed.sh" <<EOF
conversation_seed_apply() { touch "${sd}/conversation"; return 0; }
conversation_seed_forget() { return 0; }
EOF
    cat > "$lib/usage_seed.sh" <<EOF
usage_seed_apply() { touch "${sd}/usage"; return 0; }
usage_seed_forget() { return 0; }
EOF
    cat > "$lib/scale_fixture_seed.sh" <<EOF
scale_fixture_apply() { touch "${sd}/scale"; return 0; }
EOF
    cat > "$lib/wiki_summaries_wait.sh" <<EOF
wiki_summaries_wait() { touch "${sd}/wiki_wait"; WIKI_WAIT_STATE="unrun"; WIKI_WAIT_DETAIL=""; return 0; }
wiki_baseline_resync() { touch "${sd}/wiki_resync"; return 0; }
EOF
    printf '%s' "$r"
}

_runner() {   # $1 tree, rest = runner args; RAN_FILE per tree
    local r="$1"; shift
    : > "${r}/ran.txt"
    ( cd "$r/scripts/box_walk_probes" && PATH="${BIN}:${PATH}" OSTLER_BOX_HOST=fake.invalid RAN_FILE="${r}/ran.txt" OSTLER_WALK_STORE="${r}/nostore" \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh "$@" ) > "${r}/out.txt" 2>&1
    return $?
}
_ran() { LC_ALL=C sort "$1/ran.txt" | tr '\n' ' ' | sed 's/ $//'; }

# --- A. --only takes a list --------------------------------------------------
printf -- '--- A: --only accepts a comma-separated list ---\n'
T="$(_stage a)"
_runner "$T"                       # positive control: no --only runs all four
[ "$(_ran "$T")" = "alpha_probe assistant_answers_grounded beta_probe gamma_probe" ] \
    && ok "control: no --only runs all 4 probes" || bad "control: expected all 4, ran: $(_ran "$T")"
_runner "$T" --only alpha_probe,gamma_probe
[ "$(_ran "$T")" = "alpha_probe gamma_probe" ] \
    && ok "list alpha_probe,gamma_probe runs exactly those two" || bad "list ran: '$(_ran "$T")'"
_runner "$T" --only beta
[ "$(_ran "$T")" = "beta_probe" ] \
    && ok "a single substring still behaves as before (beta -> beta_probe)" || bad "single ran: '$(_ran "$T")'"
_runner "$T" --only alpha_probe,no_such_probe; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$(_ran "$T")" ] && grep -q 'no_such_probe' "$T/out.txt"; then
    ok "a list item matching nothing is refused by name (rc 2), nothing ran"
else
    bad "unmatched list item: rc=$rc ran='$(_ran "$T")'"
fi

# --- the early pass ----------------------------------------------------------
EP() { echo "$1/scripts/early_repeat_fail_pass.sh"; }
_ep() {   # tree, extra args
    local r="$1"; shift
    mkdir -p "${r}/store"; : > "${r}/ran.txt"; : > "${r}/verdicts.txt"
    ( cd "$r" && PATH="${BIN}:${PATH}" RAN_FILE="${r}/ran.txt" OSTLER_WALK_STORE="${r}/store" \
        perl -e 'alarm 120; exec @ARGV' bash "$(EP "$r")" --host fake.invalid "$@" ) > "${r}/ep.txt" 2>&1
    return $?
}

printf -- '--- B: a missing or unreadable previous record is CANNOT-RUN, not an empty pass ---\n'
T="$(_stage b)"
if [ ! -f "$(EP "$T")" ]; then
    bad "scripts/early_repeat_fail_pass.sh does not exist"
else
    rm -rf "$T/store"
    _ep "$T"
    if grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && [ -z "$(_ran "$T")" ] && ! grep -q 'EARLY PASS RESULT: 0 repeat' "$T/ep.txt"; then
        ok "no walks dir: CANNOT-RUN (early), nothing ran"
    else bad "no walks dir: $(tail -n 4 "$T/ep.txt" | tr '\n' ' ')"; fi
    mkdir -p "$T/store"
    _ep "$T"
    grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && grep -q '0 files examined' "$T/ep.txt" \
        && ok "empty walks dir: CANNOT-RUN (early) with the denominator" || bad "empty walks dir: $(tail -n 3 "$T/ep.txt" | tr '\n' ' ')"
    _ep "$T" --prev-record "$T/store/v9.9.9-20260101T000000Z.tsv"
    grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && grep -q 'missing or unreadable' "$T/ep.txt" \
        && ok "named record absent: CANNOT-RUN (early) names the file" || bad "absent record: $(tail -n 3 "$T/ep.txt" | tr '\n' ' ')"
    printf 'version\tv9.9.9\nwalked_at\t2026-01-01T00:00:00Z\n' > "$T/store/v9.9.9-20260101T000000Z.tsv"
    _ep "$T"
    grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && grep -q 'no verdict row' "$T/ep.txt" \
        && ok "a record with no verdict row: CANNOT-RUN (early)" || bad "no-verdict record: $(tail -n 3 "$T/ep.txt" | tr '\n' ' ')"
    printf 'walked_at\t2026-01-01T00:00:00Z\nverdict\tFAILED\nfailed_probe_names_recorded\t0 of 0\n' > "$T/store/v9.9.9-20260101T000000Z.tsv"
    _ep "$T"
    grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && [ -z "$(_ran "$T")" ] \
        && ok "FAILED verdict naming no probe: CANNOT-RUN (early), not an empty pass" || bad "FAILED, no names: $(tail -n 3 "$T/ep.txt" | tr '\n' ' ')"
fi

printf -- '--- C: the early pass is read-only, skips seed-dependent probes, reports the repeat ---\n'
T="$(_stage c)"
if [ ! -f "$(EP "$T")" ]; then
    bad "scripts/early_repeat_fail_pass.sh does not exist"
else
    # older record must be ignored in favour of the newest by VERSION sort
    printf 'walked_at\t2026-01-01T00:00:00Z\nverdict\tFAILED\nfailed_probe_names_recorded\t1 of 1\nfailed_probe\tbeta_probe\n' > "$T/store/v1.0.10-20260101T000000Z.tsv"
    printf 'walked_at\t2026-02-01T00:00:00Z\nverdict\tFAILED\nfailed_probe_names_recorded\t3 of 4\nfailed_probe\talpha_probe\nfailed_probe\tassistant_answers_grounded\nfailed_probe\tsome_phase2_row\n' > "$T/store/v1.0.9-20260201T000000Z.tsv"
    VF="${T}/verdicts-canary.txt"; : > "$VF"
    rm -f "${WORK}/ssh_called"   # earlier arms ran FULL walks, which do ssh the in-use check
    ( cd "$T" && PATH="${BIN}:${PATH}" RAN_FILE="${T}/ran.txt" OSTLER_PHASE1_VERDICTS="$VF" OSTLER_WALK_STORE="${T}/store" \
        perl -e 'alarm 120; exec @ARGV' bash "$(EP "$T")" --host fake.invalid ) > "${T}/ep.txt" 2>&1
    # control that the early pass really ran the probe: alpha ran, once
    [ "$(_ran "$T")" = "alpha_probe" ] && ok "only the runnable previous failure ran (alpha_probe; the newer STAMP won though its version sorts lower)" \
        || bad "ran: '$(_ran "$T")'"
    grep -q 'EARLY FAIL alpha_probe: REPEAT FAILURE' "$T/ep.txt" && ok "a repeat failure is reported as EARLY FAIL" || bad "no EARLY FAIL line"
    grep -q 'CANNOT-RUN (early) assistant_answers_grounded: seed-dependent' "$T/ep.txt" && ok "seed-dependent probe is CANNOT-RUN (early), not run" || bad "seed-dependent not refused"
    grep -q 'CANNOT-RUN (early) some_phase2_row: no probe' "$T/ep.txt" && ok "a name with no box-walk probe is CANNOT-RUN (early)" || bad "unknown name not reported"
    grep -q '1 failure(s) in the previous walk are not named' "$T/ep.txt" && ok "the unnamed remainder (3 of 4) is reported, not dropped" || bad "unnamed remainder not reported"
    grep -q 'NOT PART OF THE WALK VERDICT' "$T/ep.txt" && grep -q 'early| ' "$T/ep.txt" && ok "output is labelled as an early pass" || bad "label missing"
    miss=0
    for w in grounding preference owner convcap conversation usage scale wiki_wait wiki_resync; do
        [ -e "${WORK}/sent-c/${w}" ] && { bad "writer ${w} ran in the early pass"; miss=1; }
    done
    [ "$miss" -eq 0 ] && ok "no writer ran in the early pass (0 of 9 sentinels)"
    [ -e "${WORK}/ssh_called" ] && bad "something shelled out to the box over ssh" || ok "nothing shelled out over ssh (stub probes only)"
    # The early pass uses its own verdicts file; the caller's must not be written.
    [ ! -s "$VF" ] && ok "the caller's OSTLER_PHASE1_VERDICTS file stayed empty (nothing reaches a record)" || bad "caller's verdicts file was written"
    [ -z "$(ls "$T/store" | grep -v -E '^v1\.0\.(9|10)-')" ] && ok "no walks/ file was written" || bad "walks/ gained a file"
    # POSITIVE CONTROL for the sentinels: the same tree, full run, writes them all.
    _runner "$T"
    n=0; for w in grounding preference owner convcap conversation usage scale wiki_wait wiki_resync; do [ -e "${WORK}/sent-c/${w}" ] && n=$((n+1)); done
    [ "$n" -eq 9 ] && ok "control: a full walk on the same tree trips all 9 sentinels" || bad "control: only ${n} of 9 sentinels tripped, so the 0-of-9 above proves nothing"
    # The fixed gap: a read-only run used to kickstart the recompile agent.
    T2="$(_stage c2)"
    _runner "$T2" --read-only --only alpha_probe
    [ ! -e "${WORK}/sent-c2/wiki_resync" ] && ok "--read-only no longer runs wiki_baseline_resync" || bad "--read-only still kickstarts the wiki recompile (wiki_baseline_resync ran)"
fi

printf -- '--- E: a fresh clone reads the operator walk store, not the checkout walks/ ---\n'
T="$(_stage e)"
if [ ! -f "$(EP "$T")" ]; then
    bad "scripts/early_repeat_fail_pass.sh does not exist"
else
    # The fresh clone: walks/ holds an OLD build's FAILED record naming alpha_probe.
    printf 'walked_at\t2026-09-30T16:20:37Z\nverdict\tFAILED\nfailed_probe_names_recorded\t1 of 1\nfailed_probe\talpha_probe\n' > "$T/walks/v1.0.106.tsv"
    # The store holds the walk that actually just happened, naming beta_probe.
    printf 'walked_at\t2026-10-10T08:00:00Z\nverdict\tFAILED\nfailed_probe_names_recorded\t1 of 1\nfailed_probe\tbeta_probe\n' > "$T/store/v1.0.107-20261010T080000Z.tsv"
    : > "$T/store/v1.0.107-20261010T075900Z.log"      # older than the record: fine
    _ep "$T"
    [ "$(_ran "$T")" = "beta_probe" ] && ok "re-checked the STORE's failure (beta_probe), not the stale repo record's (alpha_probe)" \
        || bad "fresh-clone fixture ran: '$(_ran "$T")' (alpha_probe here means the stale checkout record was read)"
    grep -q 'v1.0.107-20261010T080000Z.tsv' "$T/ep.txt" && ok "names the store record it read" || bad "does not name the store record"
    # Staleness: a walk ran after the record and left none.
    : > "$T/store/v1.0.107-20261011T010203Z.log"
    _ep "$T"
    if [ -z "$(_ran "$T")" ] && grep -q 'CANNOT-RUN (early)' "$T/ep.txt" && grep -q '20261011T010203Z' "$T/ep.txt" && grep -q '20261010T080000Z' "$T/ep.txt"; then
        ok "a newer walk log than the record: CANNOT-RUN (early), both stamps named, nothing ran"
    else bad "stale record not refused: ran='$(_ran "$T")' $(tail -n 3 "$T/ep.txt" | tr '\n' ' ')"; fi
    rm -rf "$T/store"; mkdir -p "$T/store"
    _ep "$T"
    [ -z "$(_ran "$T")" ] && grep -q 'CANNOT-RUN (early)' "$T/ep.txt" \
        && ok "empty store with a populated checkout walks/: CANNOT-RUN (early), no fallback to the checkout" || bad "fell back to the checkout record"
fi

printf -- '--- F: record_walk.sh copies each record into the walk store ---\n'
R="${WORK}/f"; mkdir -p "$R/rec" "$R/store"
cat > "$R/qa.sh" <<QAEOF
#!/bin/sh
sleep 1   # record_walk.sh demands the record be NEWER than its start marker; CI filesystems have coarse mtimes
printf 'version\t%s\nwalked_at\t2026-10-10T08:00:00Z\nverdict\tFAILED\n' "\$2" > "$R/rec/\$2.tsv"
exit 1
QAEOF
chmod +x "$R/qa.sh"
( cd "$R" && OSTLER_POST_WALK_QA="$R/qa.sh" OSTLER_WALK_RECORD_DIR="$R/rec" OSTLER_WALK_STORE="$R/store" \
    bash "${REPO}/scripts/record_walk.sh" --host fake.invalid --version v9.9.9 --walk-verdict 1 ) > "$R/out.txt" 2>&1
n="$(ls "$R/store" | grep -c -E '^v9\.9\.9-[0-9]{8}T[0-9]{6}Z\.tsv$')"
if [ "$n" -eq 1 ] && cmp -s "$R/rec/v9.9.9.tsv" "$R/store/"v9.9.9-*.tsv; then
    ok "record_walk.sh copied the record to the store byte-for-byte"
else
    bad "no store copy (matching files: ${n}): $(tail -n 3 "$R/out.txt" | tr '\n' ' ')"
fi

printf -- '--- G: the full walk moves the previous FAILs to the front, order only ---\n'
_runner_store() {   # tree, store, extra args
    local r="$1" st="$2"; shift 2
    : > "${r}/ran.txt"
    ( cd "$r/scripts/box_walk_probes" && PATH="${BIN}:${PATH}" OSTLER_BOX_HOST=fake.invalid RAN_FILE="${r}/ran.txt" OSTLER_WALK_STORE="${r}/nostore" \
        OSTLER_WALK_STORE="$st" perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh "$@" ) > "${r}/out.txt" 2>&1
}
T="$(_stage g)"
if [ ! -f "$T/scripts/box_walk_probes/lib/promote_order.sh" ]; then
    bad "lib/promote_order.sh is absent"
else
    ST="$T/st"; mkdir -p "$ST"
    printf 'walked_at\t2026-10-10T08:00:00Z\nverdict\tFAILED\nfailed_probe_names_recorded\t1 of 1\nfailed_probe\tgamma_probe\n' > "$ST/v1.0.107-20261010T080000Z.tsv"
    _runner_store "$T" "$ST"
    [ "$(tr '\n' ' ' < "$T/ran.txt" | sed 's/ $//')" = "gamma_probe alpha_probe assistant_answers_grounded beta_probe" ] \
        && ok "full walk: gamma_probe (the previous FAIL) ran first, the rest in C order, none lost" \
        || bad "full-walk order: $(tr '\n' ' ' < "$T/ran.txt")"
    : > "$ST/v1.0.107-20261011T000000Z.log"
    _runner_store "$T" "$ST"
    if [ "$(tr '\n' ' ' < "$T/ran.txt" | sed 's/ $//')" = "alpha_probe assistant_answers_grounded beta_probe gamma_probe" ] && grep -q 'PROMOTION: CANNOT-RUN' "$T/out.txt"; then
        ok "a stale record: PROMOTION CANNOT-RUN, order left as C-sorted"
    else bad "stale-record promotion: $(tr '\n' ' ' < "$T/ran.txt")"; fi
    _runner_store "$T" "$T/empty-store"
    grep -q 'PROMOTION: CANNOT-RUN' "$T/out.txt" && ok "no store: PROMOTION CANNOT-RUN, never silent" || bad "no store: no PROMOTION line"
    rm -f "$ST/"*.log
    _runner_store "$T" "$ST" --only beta_probe,gamma_probe
    [ "$(tr '\n' ' ' < "$T/ran.txt" | sed 's/ $//')" = "beta_probe gamma_probe" ] && ! grep -q PROMOTION "$T/out.txt" \
        && ok "--only runs are never reordered" || bad "--only run was reordered: $(tr '\n' ' ' < "$T/ran.txt")"
fi

printf -- '--- D: the full walk is unchanged and not wired to the early pass ---\n'
T="$(_stage d)"
_runner "$T"
[ "$(tr '\n' ' ' < "$T/ran.txt" | sed 's/ $//')" = "alpha_probe assistant_answers_grounded beta_probe gamma_probe" ] \
    && ok "a full run executes probes in the pinned C-sorted order" || bad "full-run order: $(tr '\n' ' ' < "$T/ran.txt")"
TW="${REPO}/scripts/ttywalk.sh"
l_early="$(grep -n 'early_repeat_fail_pass.sh" --host' "$TW" | head -1 | cut -d: -f1)"
l_rec="$(grep -n 'record_walk.sh" "\${RECORD_ARGS' "$TW" | head -1 | cut -d: -f1)"
if [ -n "$l_early" ] && [ -n "$l_rec" ] && [ "$l_early" -lt "$l_rec" ]; then
    ok "ttywalk runs the early pass (line ${l_early}) before the recorded full walk (line ${l_rec})"
else
    bad "ttywalk does not call the early pass before record_walk.sh (early='${l_early}' record='${l_rec}')"
fi
if [ -n "$l_early" ] && [ "$(sed -n "${l_early},$((l_early+2))p" "$TW" | grep -c 'WALK_VERDICT')" -eq 0 ]; then
    ok "the early pass call does not touch WALK_VERDICT"
else
    bad "the early pass call is near/assigns WALK_VERDICT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
