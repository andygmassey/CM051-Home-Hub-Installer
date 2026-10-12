#!/usr/bin/env bash
# scripts/tests/test_full_walk_chooses_the_real_person.sh
# DMG #23. hub_screens_render_for_a_customer's assertion "chat: a real person's
# compiled page renders with their name" was NOT MEASURED on every full walk:
# nothing exported HUB_SCREENS_REAL_PERSON. The runner now chooses one from the
# box's people API + compiled wiki People pages (lib/real_person_choose.sh) and
# hands it to the probe by env only.
# Oracle: a stub probe named like the real one records the env it is given; a
# stub ssh answers the three reads with SYNTHETIC people. ARM 0 is the positive
# control and the red-on-893659da arm (the freeze never set the variable).
# PRIVACY arms: the stand-in name must not appear anywhere in the walk log.
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

STAND_IN="Robbie Wang"      # synthetic stand-in for a real person's name
SLUG="robbie-wang"

cat > "${WORK}/people.json" <<'EOP'
{"people":[{"name":"Acme Corp Billing"},{"name":"Sam Q Patel"},{"name":"Tommy Min"},{"name":"Robbie Wang"},{"name":"Lizzie Li"}]}
EOP
printf 'index.md\ntommy-min.md\nsam-q-patel.md\n%s/index.md\nlizzie-li.md\n' "$SLUG" > "${WORK}/pages.txt"
: > "${WORK}/pages_empty.txt"

SSHD="${WORK}/sshbin"; mkdir -p "$SSHD"
cat > "${SSHD}/ssh" <<'EOS'
#!/bin/sh
case "$*" in
  *"people?sort"*)     [ "${RP_FAIL:-}" = people ] && { echo "boom-people" >&2; exit 7; }; cat "$RP_PEOPLE" ;;
  *"docker exec"*)     [ "${RP_FAIL:-}" = pages ] && { echo "boom-pages" >&2; exit 7; }; cat "$RP_PAGES" ;;
  *"user_first_name"*) [ "${RP_FAIL:-}" = owner ] && { echo "boom-owner" >&2; exit 7; }; printf 'Tommy\n' ;;
  *)                   printf ABSENT ;;
esac
EOS
chmod +x "${SSHD}/ssh"

_stage() {
    local t="${WORK}/$1"
    cp -R "$SRC" "$t"; rm -f "$t"/probes/*.sh
    cat > "$t/probes/hub_screens_render_for_a_customer.sh" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = "--self-test" ] && exit 1
printf '%s' "\${HUB_SCREENS_REAL_PERSON:-unset}" > "${t}/seen_person"
printf '%s' "\${HUB_SCREENS_REAL_PERSON_STATE:-unset}" > "${t}/seen_state"
printf '%s' "\${HUB_SCREENS_REAL_PERSON_DETAIL:-unset}" > "${t}/seen_detail"
printf '%s' "\${OSTLER_SCREENS_ALLOW_WRITE:-unset}" > "${t}/seen_write"
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
_run() {  # tree, pages file, budget
    local t="$1"
    ( cd "$t" && PATH="${SSHD}:${PATH}" OSTLER_BOX_HOST=fake.invalid RP_PEOPLE="${WORK}/people.json" RP_PAGES="$2" \
        OSTLER_REAL_PERSON_BUDGET_S="$3" OSTLER_REAL_PERSON_STEP_S=1 \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh ) > "$t/out.txt" 2>&1
}
_f() { cat "$1/$2" 2>/dev/null || printf 'NEVER-RAN'; }

t="$(_stage full)"; _run "$t" "${WORK}/pages.txt" 0
[ "$(_f "$t" seen_write)" = "1" ] && ok "arm 0a full run: OSTLER_SCREENS_ALLOW_WRITE=1" || bad "arm 0a: write saw '$(_f "$t" seen_write)'"
[ "$(_f "$t" seen_person)" = "$STAND_IN" ] && ok "arm 0b full run: probe was handed the one valid real person (not org, synthetic cast, owner, or page-less)" || bad "arm 0b: probe saw a person value of length $(_f "$t" seen_person | wc -c), want the stand-in"
[ "$(_f "$t" seen_state)" = "chosen" ] && ok "arm 0c full run: state chosen" || bad "arm 0c: state '$(_f "$t" seen_state)'"
if /usr/bin/grep -qiE "robbie|wang|${SLUG}" "$t/out.txt"; then bad "arm 1 PRIVACY: the stand-in name or slug is in the walk log"; else ok "arm 1 PRIVACY: neither the name nor its slug is in the walk log"; fi
if /usr/bin/grep -qE 'real person: chosen id=[0-9a-f]{8} page_path_depth=1 ' "$t/out.txt"; then ok "arm 1b the log carries sha256[:8] and page path depth only"; else bad "arm 1b: no fingerprint line"; fi
exp8="$(printf '%s' "$STAND_IN" | /usr/bin/shasum -a 256 | cut -c1-8)"
/usr/bin/grep -q "id=${exp8}" "$t/out.txt" && ok "arm 1c the logged id is sha256(name)[:8]" || bad "arm 1c: id is not sha256(name)[:8]"

t="$(_stage none)"; _run "$t" "${WORK}/pages_empty.txt" 0
[ "$(_f "$t" seen_person)" = "unset" ] && ok "arm 2 no compiled pages: no person is handed over" || bad "arm 2: a person was handed over"
[ "$(_f "$t" seen_state)" = "cannot-run" ] && ok "arm 2b state is cannot-run, never chosen" || bad "arm 2b: state '$(_f "$t" seen_state)'"
_f "$t" seen_detail | /usr/bin/grep -q "compiled_pages=0" && ok "arm 2c the reason names the count examined" || bad "arm 2c: detail lacks compiled_pages=0"
if /usr/bin/grep -qiE "robbie|wang|lizzie" "$t/out.txt"; then bad "arm 2d PRIVACY: a person name is in the cannot-run log"; else ok "arm 2d no person name in the cannot-run log"; fi

for which in people pages owner; do
    t="$(_stage "fail_$which")"
    ( cd "$t" && PATH="${SSHD}:${PATH}" OSTLER_BOX_HOST=fake.invalid RP_FAIL="$which" RP_PEOPLE="${WORK}/people.json" RP_PAGES="${WORK}/pages.txt" \
        OSTLER_REAL_PERSON_BUDGET_S=0 OSTLER_REAL_PERSON_STEP_S=1 \
        perl -e 'alarm 120; exec @ARGV' bash ./run_box_walk.sh ) > "$t/out.txt" 2>&1
    [ "$(_f "$t" seen_state)" = "cannot-run" ] && [ "$(_f "$t" seen_person)" = "unset" ] && ok "arm 3 $which read fails: cannot-run, no person handed over" || bad "arm 3 $which: state '$(_f "$t" seen_state)' person-set=$([ "$(_f "$t" seen_person)" = unset ] && echo no || echo YES)"
    _f "$t" seen_detail | /usr/bin/grep -q "${which} read failed rc=7: boom-${which}" && ok "arm 3 $which: the detail names the rc and the error" || bad "arm 3 $which: detail lacks the error"
    _f "$t" seen_detail | /usr/bin/grep -q "compiled_pages=0" && bad "arm 3 $which: reported as 0 compiled pages" || ok "arm 3 $which: not misreported as 0 compiled pages"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
