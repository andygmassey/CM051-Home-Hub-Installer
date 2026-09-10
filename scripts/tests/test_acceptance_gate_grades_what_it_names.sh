#!/usr/bin/env bash
# scripts/tests/test_acceptance_gate_grades_what_it_names.sh
# ============================================================================
# Two assertions in acceptance_gate_v1013.sh graded something other than what
# their titles name, and both stood red behind the A7 footer on the v1.0.82,
# v1.0.85 and v1.0.87 records:
#
#   A4 "Pairing signals consistent" demanded companion_paired, paired and
#      token_paired AGREE on an unpaired box. token_paired is the bearer-token
#      set being non-empty, and the installer seeds the admin token on every
#      install (ostler-assistant #208 keeps it out of the device state on
#      purpose). So a correctly installed unpaired box reads false/false/true
#      and the predicate could never pass. It now asserts the two DEVICE flags
#      and the device count, and reports the token flag as evidence.
#
#   A6 "Wiki compiler clean" counted "400 Bad Request", parser crashes and
#      "BROKEN LINK" across EVERY log under the account, and appended
#      "(stale image, pre-#219)" to every FAIL unconditionally. On v1.0.87 the
#      one 400 was in imessage-bundle.err. It now reads wiki-*.log only, and
#      the evidence is the counts.
#
# Hermetic: the gate's ssh-backed box() is replaced by a stub driven from a
# mode file, the same substitution test_an_unreachable_box_is_not_a_defect.sh
# uses. Nothing here opens a network connection.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GATE="${REPO}/scripts/box_walk_probes/acceptance_gate_v1013.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "${GATE}" ] || cant "cannot read ${GATE}"
[ -s "${GATE}" ] || cant "${GATE} is empty; every arm below would report on nothing"

WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "${WORK}"' EXIT
STUB_MODE="${WORK}/mode"

build() {
    awk -v stub="${WORK}/stub.sh" '
        /^box\(\)\{ ssh / { print "box(){ . " stub "; _fake_box \"$1\"; }"; next }
        { print }
    ' "${GATE}" > "$1"
    chmod +x "$1"
}

# The stub answers by the SHAPE of the command the gate sends. Order matters:
# the wiki-scoped counter's command names wiki-*.log AND carries the same
# grep pattern as the all-logs counter, so it is matched first.
cat > "${WORK}/stub.sh" <<'STUB'
_fake_box() {
    local cmd="$1"
    local mode; mode="$(cat "${STUB_MODE}")"
    # Common, healthy answers for everything A4 and A6 do not grade.
    case "${cmd}" in
        *"echo ok"*)   echo ok; return 0 ;;
        *http_code*)   echo 200; return 0 ;;
        *frontpage*)   echo '{"id":"welcome-1"}'; return 0 ;;
        *launchctl*)   echo __A8_OK__; return 0 ;;
        *api/tags*)    echo '"name":"qwen"'; return 0 ;;
    esac
    case "${mode}" in
        unpaired_healthy)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":false,"token_paired":true}' ;;
                *sqlite3*)              echo 0 ;;
                *wiki-*)                echo 0 ;;                 # the wiki logs are clean
                *"400 Bad Request"*)    echo 1 ;;                 # ONE 400, in a non-wiki log
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        lying_ui)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":true,"token_paired":true}' ;;
                *sqlite3*)              echo 0 ;;
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        ghost_device)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":false,"token_paired":true}' ;;
                *sqlite3*)              echo 1 ;;
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        health_unreadable)
            case "${cmd}" in
                */health*)              echo "" ;;
                *sqlite3*)              echo 0 ;;
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        wiki_unreadable)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":false,"token_paired":true}' ;;
                *sqlite3*)              echo 0 ;;
                *wiki-*)                echo GREPERR ;;              # grep could not read a wiki log
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        pairing_disabled)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":false,"token_paired":true,"require_pairing":false}' ;;
                *sqlite3*)              echo "" ;;                   # no devices.db on such a box
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
        wiki_dirty)
            case "${cmd}" in
                */health*)              echo '{"companion_paired":false,"paired":false,"token_paired":true}' ;;
                *sqlite3*)              echo 0 ;;
                *wiki-*"BROKEN LINK"*)  echo 133 ;;
                *wiki-*)                echo 0 ;;
                *found=0*)              echo 0 ;;
                *)                      echo "" ;;
            esac ;;
    esac
}
STUB

COPY="${WORK}/gate.sh"
build "${COPY}"

echo "== MUST-MISS: the stub really replaced ssh =="
if grep -q '^box(){ ssh ' "${COPY}"; then
    bad "the real ssh box() survived in the copy; every arm below would open a network connection"
elif grep -q '_fake_box' "${COPY}"; then
    ok "the copy calls _fake_box and contains no ssh box(), so the arms below are hermetic"
else
    cant "the copy has neither the real box() nor the stub"
fi

run_gate() {
    printf '%s' "$1" > "${STUB_MODE}"
    STUB_MODE="${STUB_MODE}" OSTLER_BOX_HOST="fake.invalid" \
        bash "${COPY}" > "${WORK}/out.txt" 2>&1
    printf '%s' "$?"
}
row() { grep -E "  (PASS|FAIL|CANT|EYES)  $1 " "${WORK}/out.txt" | head -1 | tr -s ' '; }

echo "== A4: a correctly installed UNPAIRED box passes =="
rc="$(run_gate unpaired_healthy)"
if grep -qE '  PASS  A4 ' "${WORK}/out.txt"; then
    ok "companion=false paired=false devices=0 with the installer's token present is PASS"
else
    bad "the unpaired healthy box did not pass A4: $(row A4)"
fi
# No pipe into grep -q: under pipefail the arm would read the producer's
# status, not the match. Read the two lines into a variable first.
a4_lines="$(grep -A1 -E '  PASS  A4 ' "${WORK}/out.txt")"
if grep -q 'token=true' <<< "${a4_lines}"; then
    ok "the token flag is reported as evidence rather than judged"
else
    bad "A4's evidence does not report the token flag"
fi

echo "== A6: a 400 outside the wiki logs is not the wiki compiler's =="
if grep -qE '  PASS  A6 ' "${WORK}/out.txt"; then
    ok "clean wiki logs pass A6 even though another log carries a 400"
else
    bad "A6 charged the wiki compiler with a 400 from another log: $(row A6)"
fi
if [ "${rc}" = "0" ]; then
    ok "CONTROL: the healthy unpaired box exits 0, so the two fixes are not a blanket refusal"
else
    bad "CONTROL: the healthy unpaired box exits ${rc}, expected 0. Rows: $(grep -E '  (PASS|FAIL|CANT|EYES)  A' "${WORK}/out.txt" | tr -s ' ' | tr '\n' ' ')"
fi

echo "== CONTROL: A4 can still fail =="
rc="$(run_gate lying_ui)"
if grep -qE '  FAIL  A4 ' "${WORK}/out.txt" && [ "${rc}" = "1" ]; then
    ok "paired=true with no device is FAIL and blocks (exit ${rc})"
else
    bad "a device flag claiming a pairing that does not exist did not fail A4: $(row A4) rc=${rc}"
fi
rc="$(run_gate ghost_device)"
if grep -qE '  FAIL  A4 ' "${WORK}/out.txt"; then
    ok "a device row with both device flags false is FAIL"
else
    bad "a ghost device row did not fail A4: $(row A4)"
fi

echo "== A4: an unreadable health endpoint is could-not-run, not pass and not fail =="
rc="$(run_gate health_unreadable)"
if grep -qE '  CANT  A4 ' "${WORK}/out.txt" && [ "${rc}" = "78" ]; then
    ok "empty pairing signals render as could-not-run and the gate exits 78"
else
    bad "empty pairing signals rendered as '$(row A4)' with rc=${rc}, expected CANT and 78"
fi

echo "== CONTROL: A6 still fails on the wiki compiler's own log =="
rc="$(run_gate wiki_dirty)"
if grep -qE '  FAIL  A6 ' "${WORK}/out.txt" && grep -q 'broken-links=133' "${WORK}/out.txt"; then
    ok "133 broken links in wiki-*.log is FAIL and the evidence carries the count"
else
    bad "broken links in the wiki log did not fail A6 with the count: $(row A6)"
fi
if grep -q 'pre-#219' "${WORK}/out.txt"; then
    bad "the FAIL evidence still carries the hardcoded 'pre-#219' diagnosis"
else
    ok "the FAIL evidence carries measured counts and no baked-in diagnosis"
fi

echo "== A6: a wiki log grep could not read is could-not-run, not clean =="
rc="$(run_gate wiki_unreadable)"
if grep -qE '  CANT  A6 ' "${WORK}/out.txt" && [ "${rc}" = "78" ]; then
    ok "a grep error on the wiki logs renders A6 as could-not-run and exits 78, never as sparql-400=0"
else
    bad "a grep error on the wiki logs rendered as '$(row A6)' rc=${rc}, expected CANT and 78"
fi

echo "== A4: a box with pairing disabled is named, not reported as an unreadable probe =="
rc="$(run_gate pairing_disabled)"
if grep -qE '  CANT  A4 ' "${WORK}/out.txt" && grep -q 'pairing disabled' "${WORK}/out.txt"; then
    ok "require_pairing=false renders A4 as could-not-run and says the registry does not exist"
else
    bad "require_pairing=false rendered as '$(row A4)' without naming the disabled registry"
fi

echo "== SOURCE: the baked-in diagnosis and the all-logs A6 reads are gone =="
if [ "$(grep -c 'pre-#219' "${GATE}")" -eq 0 ]; then
    ok "the gate source no longer contains the 'pre-#219' string"
else
    bad "the gate source still contains 'pre-#219'"
fi
if grep -qE "^brk=\\\$\(wikicount 'BROKEN LINK'\)" "${GATE}" && grep -qE "^ox400=\\\$\(wikicount '400 Bad Request'\)" "${GATE}"; then
    ok "A6's counts come from wikicount, the wiki-log-scoped reader"
else
    bad "A6's counts do not come from wikicount"
fi

echo
echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="
[ "${fail}" -eq 0 ]
