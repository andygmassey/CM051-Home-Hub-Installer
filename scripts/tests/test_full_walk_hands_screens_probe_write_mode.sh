#!/usr/bin/env bash
# scripts/tests/test_full_walk_hands_screens_probe_write_mode.sh
# DMG #22. hub_screens_render_for_a_customer reported "chat: a person link opens
# inside the app" NOT MEASURED ("needs --allow-write and HUB_SCREENS_PERSON")
# because nothing in the repo ever exported OSTLER_SCREENS_ALLOW_WRITE=1: the
# probe's write mode (which also makes it seed its own person) depended on the
# operator's shell. The runner owns the answer: a full run (READ_ONLY=0) hands
# every probe OSTLER_SCREENS_ALLOW_WRITE=1; a read-only run hands 0 and never
# trusts an inherited 1.
# Oracle: a stub probe records the env it was given. ARM 0 is the positive
# control (full run must record 1), so "0" elsewhere is not a stub that never ran.
# EXIT 0 pass, 1 fail, 2 CANNOT-RUN. BASH 3.2.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../box_walk_probes"
[ -f "${SRC}/run_box_walk.sh" ] || { echo "CANNOT-RUN: no runner"; exit 2; }
WORK="$(mktemp -d)" || exit 78
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

SSHD="${WORK}/sshbin"; mkdir -p "$SSHD"
printf '#!/bin/sh\nprintf ABSENT\n' > "${SSHD}/ssh"; chmod +x "${SSHD}/ssh"

_stage() {
    local t="${WORK}/$1"
    cp -R "$SRC" "$t"; rm -f "$t"/probes/*.sh
    cat > "$t/probes/stub_env.sh" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = "--self-test" ] && exit 1
printf '%s' "\${OSTLER_SCREENS_ALLOW_WRITE:-unset}" > "${t}/seen"
echo "VERDICT: PASS -- stub"
exit 0
EOS
    chmod +x "$t"/probes/*.sh
    for l in grounding_seed preference_seed conversation_seed usage_seed; do
        printf '%s_apply() { return 0; }\nGROUNDING_SEED_STATE=unrun\n' "$l" > "$t/lib/$l.sh"
    done
    printf 'wiki_summaries_wait() { WIKI_WAIT_STATE=unrun; WIKI_WAIT_DETAIL=""; return 0; }\n' > "$t/lib/wiki_summaries_wait.sh"
    printf '%s' "$t"
}
_run() {  # tree, [env assignment], args...
    local t="$1"; shift
    ( cd "$t" && PATH="${SSHD}:${PATH}" OSTLER_BOX_HOST=fake.invalid "$@" \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh ) > "$t/out.txt" 2>&1
}
_runargs() {  # tree, runner args...
    local t="$1"; shift
    ( cd "$t" && PATH="${SSHD}:${PATH}" OSTLER_BOX_HOST=fake.invalid \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh "$@" ) > "$t/out.txt" 2>&1
}
_seen() { cat "$1/seen" 2>/dev/null || printf 'NEVER-RAN'; }

t="$(_stage full)"; _runargs "$t"
[ "$(_seen "$t")" = "1" ] && ok "arm 0 full run: probe was handed OSTLER_SCREENS_ALLOW_WRITE=1" || bad "arm 0 full run: probe saw '$(_seen "$t")', want 1"

t="$(_stage only)"; _runargs "$t" --only stub_env
[ "$(_seen "$t")" = "0" ] && ok "arm 1 --only (read-only): probe handed 0" || bad "arm 1 --only: saw '$(_seen "$t")', want 0"

t="$(_stage onlyw)"; _runargs "$t" --only stub_env --allow-writes
[ "$(_seen "$t")" = "1" ] && ok "arm 2 --only --allow-writes: probe handed 1" || bad "arm 2: saw '$(_seen "$t")', want 1"

t="$(_stage ro)"; ( cd "$t" && OSTLER_SCREENS_ALLOW_WRITE=1 PATH="${SSHD}:${PATH}" OSTLER_BOX_HOST=fake.invalid perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh --read-only ) > "$t/out.txt" 2>&1
[ "$(_seen "$t")" = "0" ] && ok "arm 3 --read-only ignores an inherited 1" || bad "arm 3: saw '$(_seen "$t")', want 0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
