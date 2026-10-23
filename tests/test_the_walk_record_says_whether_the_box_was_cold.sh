#!/usr/bin/env bash
#
# THE WALK RECORD MUST SAY WHETHER THE BOX WAS COLD.
#
# MEASURED 2026-10-23, v1.0.117 walk on the Mini16: vane_install took 6515 s of
# a 9685 s install (a 3.43 GB image at 0.53 MB/s), while ai_models took 5 s
# because both models were already on disk ("existing=kept"). The colima data
# disk was carried over too. The record had a field for the stores and for
# nothing else, so a walk that never exercised the model download, the image
# pulls or the VM creation would have read as a cold one.
#
# Warm walks are the fast way to iterate. They are only honest if declared,
# and the FINAL pre-ship walk must still be cold. This test drives:
#
#   A. walk_cold_state_measure on synthetic HOMEs (the function ttywalk ships
#      to the box), one arm per surface, plus the unreadable arm
#   B. walk_cold_state_read_box turning the install.sh run header into epoch
#   C. walk_cold_state_rows: every not-recorded path, and the passthrough
#   D. the real chain end to end: measure -> marker -> read_box -> rows
#   E. scripts/verify_walk_record.sh: NOT-COLD refuses a promote, cold and
#      absent do not, a measured defect is not masked
#   F. scripts/ttywalk.sh --require-cold, END TO END with ssh stubbed: a warm
#      box is refused before any staging command reaches the host
#   G. wiring: ttywalk measures before RUN, post_walk_qa writes the rows once
#
# Nothing here touches a real box, a real HOME or a real keychain. Every HOME
# is a mktemp dir and ssh is a stub on PATH.
#
# EXIT CODES. 0 every arm held; 1 an arm failed; 2 CANNOT-RUN (anchors moved).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib_walk_cold_state.sh"
TW="${ROOT}/scripts/ttywalk.sh"
QA="${ROOT}/scripts/post_walk_qa.sh"
VR="${ROOT}/scripts/verify_walk_record.sh"
STRIP="${ROOT}/scripts/lib/strip_comments.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  CANNOT-RUN  %s\n' "$*"; }
cannot() { printf '\nCANNOT-RUN: %s\n' "$1" >&2; exit 2; }

for f in "$TW" "$QA" "$VR"; do [ -f "$f" ] || cannot "missing ${f}"; done

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"

HAVE_LIB=0
if [ -f "$LIB" ]; then
    # shellcheck source=scripts/lib_walk_cold_state.sh
    source "$LIB"; HAVE_LIB=1
    ok "CONTROL: scripts/lib_walk_cold_state.sh exists and sources"
else
    bad "scripts/lib_walk_cold_state.sh does not exist: nothing measures whether the box was cold"
fi

# Run the measurement the way ttywalk does: the function body shipped into a
# fresh bash -s, with HOME pointed at a synthetic tree.
measure_in() {  # measure_in <home>
    { declare -f walk_cold_state_measure; printf 'walk_cold_state_measure\n'; } \
        | env -i PATH=/usr/bin:/bin HOME="$1" /bin/bash -s
}
field_of() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }

echo
echo "=== A. the measurement, one surface at a time ==="
if [ "$HAVE_LIB" -eq 1 ]; then
    H="${TMP}/h_cold"; mkdir -p "$H"
    out="$(measure_in "$H")"
    [ "$(printf '%s\n' "$out" | field_of cold_state)" = "cold" ] \
        && [ "$(printf '%s\n' "$out" | awk -F'\t' '$1=="not_cold"' | wc -l | tr -d ' ')" = "0" ] \
        && ok "an empty HOME is cold, with 0 not_cold rows" \
        || bad "an empty HOME did not read cold: $(printf '%s' "$out" | tr '\n\t' '| ')"
    case "$(printf '%s\n' "$out" | field_of measured_at)" in
        ''|*[!0-9]*) bad "measured_at is not epoch seconds" ;;
        *) ok "measured_at is epoch seconds" ;;
    esac

    surface_arm() {  # surface_arm <label> <surface> <setup...>
        local label="$1" surf="$2"; shift 2
        local h="${TMP}/h_${surf}"; mkdir -p "$h"
        ( cd "$h" && eval "$*" )
        local o; o="$(measure_in "$h")"
        if [ "$(printf '%s\n' "$o" | field_of cold_state)" = "NOT-COLD" ] \
           && printf '%s\n' "$o" | awk -F'\t' -v s="$surf" '$1=="not_cold" && $2==s {f=1} END{exit !f}'; then
            ok "${label} -> NOT-COLD, not_cold ${surf}"
        else
            bad "${label} did not produce NOT-COLD + not_cold ${surf}: $(printf '%s' "$o" | tr '\n\t' '| ')"
        fi
    }
    surface_arm "a colima VM instance"  colima_vm            'mkdir -p .colima/_lima/colima && : > .colima/_lima/colima/disk'
    surface_arm "a colima data disk"    container_data_disk  'mkdir -p .colima/_lima/_disks/colima && head -c 4096 /dev/zero > .colima/_lima/_disks/colima/datadisk'
    surface_arm "ollama models"         ollama_model         'mkdir -p .ollama/models/manifests/registry.ollama.ai/library/gemma4 .ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text && : > .ollama/models/manifests/registry.ollama.ai/library/gemma4/e2b && : > .ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest'
    surface_arm "orphan ollama blobs"   ollama_blobs         'mkdir -p .ollama/models/blobs && head -c 4096 /dev/zero > .ollama/models/blobs/sha256-x'

    o="$(measure_in "${TMP}/h_ollama_model")"
    names="$(printf '%s\n' "$o" | awk -F'\t' '$1=="not_cold" && $2=="ollama_model"{split($3,a," "); print a[1]}' | tr '\n' ' ')"
    [ "$names" = "gemma4:e2b nomic-embed-text:latest " ] \
        && ok "each model is named as model:tag (${names% })" \
        || bad "model names came out as '${names}'"

    # An empty manifests dir and an empty blobs dir are not a warm surface.
    H="${TMP}/h_emptyollama"; mkdir -p "$H/.ollama/models/manifests" "$H/.ollama/models/blobs"
    [ "$(measure_in "$H" | field_of cold_state)" = "cold" ] \
        && ok "empty Ollama dirs are still cold (nothing to reuse)" \
        || bad "empty Ollama dirs were called warm"

    # COULD NOT LOOK is not FOUND NOTHING.
    if [ "$(id -u)" = "0" ]; then
        skip "the unreadable arm: running as root, a mode-000 dir is still readable"
    else
        H="${TMP}/h_unreadable"; mkdir -p "$H/.ollama/models/manifests/registry.ollama.ai"
        chmod 000 "$H/.ollama/models/manifests"
        st="$(measure_in "$H" | field_of cold_state)"
        chmod 755 "$H/.ollama/models/manifests"
        case "$st" in
            unknown\(*) ok "an unreadable surface makes the state unknown(...), never cold" ;;
            *) bad "an unreadable surface produced '${st}'" ;;
        esac
    fi
else
    bad "A skipped: no measurement to drive"
fi

echo
echo "=== B. the install.sh run header becomes epoch seconds ==="
if [ "$HAVE_LIB" -eq 1 ]; then
    H="${TMP}/h_read"; mkdir -p "$H/.ostler/logs"
    printf 'measured_at\t1\ncold_state\tcold\n' > "$H/.walk-cold-state"
    # Two runs in one log: the LAST header is the one the marker must match.
    printf '\n=== install.sh run 2026-10-22T09:00:00Z (DMG #47 transcript) ===\nx\n=== install.sh run 2026-10-23T01:42:08Z (DMG #48 transcript) ===\n' > "$H/.ostler/logs/install.log"
    o="$( { declare -f walk_cold_state_read_box; printf 'walk_cold_state_read_box\n'; } | env -i PATH=/usr/bin:/bin HOME="$H" /bin/bash -s)"
    # 1792719728 is 2026-10-23T01:42:08Z, an external fact (python calendar.timegm).
    [ "$(printf '%s\n' "$o" | field_of install_run_epoch)" = "1792719728" ] \
        && ok "the LAST run header is read, as epoch 1792719728" \
        || bad "install_run_epoch came out '$(printf '%s\n' "$o" | field_of install_run_epoch)'"
    [ "$(printf '%s\n' "$o" | field_of cold_state)" = "cold" ] \
        && ok "the marker is passed through verbatim" || bad "the marker was not passed through"
    rm -f "$H/.ostler/logs/install.log"
    o="$( { declare -f walk_cold_state_read_box; printf 'walk_cold_state_read_box\n'; } | env -i PATH=/usr/bin:/bin HOME="$H" /bin/bash -s)"
    printf '%s\n' "$o" | awk -F'\t' '$1=="install_run_epoch" && $2=="" {f=1} END{exit !f}' \
        && ok "no install.log -> an EMPTY install_run_epoch line, still present" \
        || bad "no install.log did not produce an empty install_run_epoch line"
fi

echo
echo "=== C. the record rows ==="
if [ "$HAVE_LIB" -eq 1 ]; then
    AT=1792719700
    rows_case() {  # rows_case <label> <expected cold_state prefix> <raw>
        local got; got="$(printf '%b' "$3" | walk_cold_state_rows | field_of cold_state)"
        case "$got" in
            "$2"*) ok "$1 -> ${got:0:60}" ;;
            *)     bad "$1 -> '${got}', expected '${2}...'" ;;
        esac
    }
    W="measured_at\t${AT}\ncold_state\tNOT-COLD\nnot_cold\tollama_model\tgemma4:e2b present\n"
    rows_case "fresh NOT-COLD"                  "NOT-COLD"     "${W}install_run_epoch\t$((AT+5))\n"
    rows_case "fresh cold"                      "cold"         "measured_at\t${AT}\ncold_state\tcold\ninstall_run_epoch\t$((AT+5))\n"
    rows_case "install ran an hour later"       "not-recorded(stale" "${W}install_run_epoch\t$((AT+3600))\n"
    rows_case "install ran BEFORE the measure"  "not-recorded(stale" "${W}install_run_epoch\t$((AT-600))\n"
    rows_case "no run header"                   "not-recorded(no install.sh run header" "${W}install_run_epoch\t\n"
    rows_case "no marker, box answered"         "not-recorded(no ~/.walk-cold-state" "install_run_epoch\t$((AT+5))\n"
    rows_case "nothing came back (ssh failed)"  "not-recorded(the box read returned nothing" ""
    rows_case "unrecognised state"              "not-recorded(marker held an unrecognised" "measured_at\t${AT}\ncold_state\tCOLDISH\ninstall_run_epoch\t$((AT+5))\n"
    rows_case "cold that lists a warm surface"  "not-recorded(marker says cold AND" "measured_at\t${AT}\ncold_state\tcold\nnot_cold\tcolima_vm\tx\ninstall_run_epoch\t$((AT+5))\n"
    rows_case "NOT-COLD naming nothing"         "not-recorded(marker says NOT-COLD and names" "measured_at\t${AT}\ncold_state\tNOT-COLD\ninstall_run_epoch\t$((AT+5))\n"
    rows_case "a two-field not_cold row"        "not-recorded(marker held a malformed" "measured_at\t${AT}\ncold_state\tNOT-COLD\nnot_cold\tcolima_vm\ninstall_run_epoch\t$((AT+5))\n"
    rows_case "measured_at not a number"        "not-recorded(marker has no numeric" "measured_at\tsoon\ncold_state\tcold\ninstall_run_epoch\t$((AT+5))\n"
    n="$(printf '%b' "${W}install_run_epoch\t$((AT+5))\n" | walk_cold_state_rows | awk -F'\t' '$1=="not_cold"' | wc -l | tr -d ' ')"
    [ "$n" = "1" ] && ok "fresh NOT-COLD carries its not_cold row into the record" \
                   || bad "fresh NOT-COLD carried ${n} not_cold rows, expected 1"
    n="$(printf '%b' "${W}install_run_epoch\t$((AT+3600))\n" | walk_cold_state_rows | awk -F'\t' '$1=="not_cold"' | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "a stale marker contributes NO not_cold rows (they describe another install)" \
                   || bad "a stale marker leaked ${n} not_cold rows"
fi

echo
echo "=== D. the real chain: measure -> marker -> read_box -> rows ==="
if [ "$HAVE_LIB" -eq 1 ]; then
    H="${TMP}/h_chain"; mkdir -p "$H/.colima/_lima/_disks/colima" "$H/.ostler/logs"
    head -c 4096 /dev/zero > "$H/.colima/_lima/_disks/colima/datadisk"
    { declare -f walk_cold_state_measure
      printf 'walk_cold_state_measure > ~/.walk-cold-state.tmp && mv -f ~/.walk-cold-state.tmp ~/.walk-cold-state && cat ~/.walk-cold-state\n'
    } | env -i PATH=/usr/bin:/bin HOME="$H" /bin/bash -s >/dev/null
    printf '=== install.sh run %s (fixture) ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$H/.ostler/logs/install.log"
    rows="$( { declare -f walk_cold_state_read_box; printf 'walk_cold_state_read_box\n'; } \
        | env -i PATH=/usr/bin:/bin HOME="$H" /bin/bash -s | walk_cold_state_rows)"
    if [ "$(printf '%s\n' "$rows" | field_of cold_state)" = "NOT-COLD" ] \
       && printf '%s\n' "$rows" | awk -F'\t' '$1=="not_cold" && $2=="container_data_disk"{f=1} END{exit !f}'; then
        ok "a warm box measured before an install is recorded NOT-COLD, container_data_disk named"
    else
        bad "the real chain produced: $(printf '%s' "$rows" | tr '\n\t' '| ')"
    fi
    # The same marker against a LATER install (a GUI walk an hour on) is stale.
    printf '=== install.sh run %s (later) ===\n' "$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" >> "$H/.ostler/logs/install.log"
    rows="$( { declare -f walk_cold_state_read_box; printf 'walk_cold_state_read_box\n'; } \
        | env -i PATH=/usr/bin:/bin HOME="$H" /bin/bash -s | walk_cold_state_rows)"
    case "$(printf '%s\n' "$rows" | field_of cold_state)" in
        not-recorded\(stale*) ok "the same marker read after a LATER install is stale, not inherited" ;;
        *) bad "a later install inherited the marker: $(printf '%s' "$rows" | tr '\n\t' '| ')" ;;
    esac
fi

echo
echo "=== E. verify_walk_record.sh: a NOT-COLD walk is not promote evidence ==="
export OSTLER_WALK_RECORD_DIR="${TMP}/walks"; mkdir -p "$OSTLER_WALK_RECORD_DIR"
printf 'cold-state fixture artefact\n' > "${TMP}/artefact.bin"
SHA="$(shasum -a 256 "${TMP}/artefact.bin" 2>/dev/null | awk '{print $1}')"
[ -n "$SHA" ] || SHA="$(sha256sum "${TMP}/artefact.bin" | awk '{print $1}')"
rec() {  # rec <version> <verdict> <fail> <cold-rows or 'none'> [walk_kind]
    { printf 'version\t%s\n' "$1"
      printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
      printf 'artefact_sha256\t%s\n' "$SHA"
      printf 'artefact_sha256_source\tmeasured(shasum -a 256 of the fixture artefact)\n'
      printf 'walked_at\t2026-10-23T01:42:08Z\nbox_fp\t3f8a1c9d2e4b6071\n'
      printf 'walk_kind\t%s\nwalk_kind_source\tdeclared: synthetic fixture\n' "${5:-console}"
      [ "$4" = "none" ] || printf '%b' "$4"
      printf 'pass\t14\nfail\t%s\ncannot_run\t0\nbroken\t0\nverdict\t%s\nqa_exit\t%s\n' "$3" "$2" "$([ "$3" = 0 ] && echo 0 || echo 1)"
      [ "$3" = 0 ] || printf 'failed_probe_names_recorded\t1 of 1\nfailed_probe\thub_screens_customer_read\n'
    } > "${OSTLER_WALK_RECORD_DIR}/$1.tsv"
}
gate() { "$VR" "$1" "$SHA" >"${TMP}/gate.out" 2>"${TMP}/gate.err"; echo $?; }

rec v1.0.901 CLEAN 0 'cold_state\tcold\n'
rc="$(gate v1.0.901)"
[ "$rc" = "0" ] && ok "CONTROL: a clean console walk recorded cold is ACCEPTED (rc=0)" \
               || bad "CONTROL: a clean cold console walk returned rc=${rc}; every refusal below proves nothing. $(tail -3 "${TMP}/gate.err")"

rec v1.0.902 CLEAN 0 'cold_state\tNOT-COLD\nnot_cold\tollama_model\tgemma4:e2b present before install (model download not exercised)\nnot_cold\tcontainer_data_disk\t31457280 KiB carried over\n'
rc="$(gate v1.0.902)"
if [ "$rc" = "2" ] && grep -q 'ollama_model' "${TMP}/gate.err" && grep -q 'container_data_disk' "${TMP}/gate.err"; then
    ok "a clean console walk recorded NOT-COLD is REFUSED (rc=2), naming each reused surface"
else
    bad "a NOT-COLD clean console walk returned rc=${rc} (expected 2, naming the surfaces). It would authorise the customer download from a warm box."
fi

rec v1.0.903 CLEAN 0 none
rc="$(gate v1.0.903)"
if [ "$rc" = "0" ] && grep -q 'cold_state is' "${TMP}/gate.out"; then
    ok "an ABSENT cold_state does not refuse, and is PRINTED as not recorded"
else
    bad "an absent cold_state returned rc=${rc}, or was silent ($(head -c 200 "${TMP}/gate.out"))"
fi

rec v1.0.904 CLEAN 0 'cold_state\tc0ld\n'
rc="$(gate v1.0.904)"
[ "$rc" = "2" ] && ok "an unrecognised cold_state fails closed (rc=2)" \
               || bad "an unrecognised cold_state returned rc=${rc}"

rec v1.0.905 FAILED 1 'cold_state\tNOT-COLD\nnot_cold\tcolima_vm\tx\n'
rc="$(gate v1.0.905)"
[ "$rc" = "1" ] && ok "a FAILED walk that was also NOT-COLD still refuses for the DEFECT (rc=1), not masked as rc=2" \
               || bad "a FAILED NOT-COLD walk returned rc=${rc}; a measured defect must keep rc=1"

echo
echo "=== F. ttywalk.sh --require-cold, end to end with ssh stubbed ==="
if [ "$HAVE_LIB" -eq 1 ]; then
    STUB="${TMP}/stubbin"; mkdir -p "$STUB"
    # The stub answers the identity round trip, runs `bash -s` locally under the
    # synthetic HOME, and LOGS every other command so we can prove nothing else
    # reached the host. It never opens a network connection.
    cat > "${STUB}/ssh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift   # the host
cmd="$*"
printf '%s\n' "$cmd" >> "$STUB_LOG"
case "$cmd" in
    'bash -s') exec env -i PATH=/usr/bin:/bin HOME="$STUB_HOME" /bin/bash -s ;;
    *scutil*)  printf 'fixture-box-01\nMac16,10\nwalker\n'; exit 0 ;;
    *)         echo "stub: refusing unexpected command" >&2; exit 97 ;;
esac
SH
    chmod +x "${STUB}/ssh"
    run_tw() {  # run_tw <home> -> rc; output in ${TMP}/tw.out
        : > "${TMP}/stub.log"
        STUB_LOG="${TMP}/stub.log" STUB_HOME="$1" PATH="${STUB}:/usr/bin:/bin" \
            /bin/bash "$TW" --host walker@fixture --expect-name "fixture-box-01" --require-cold \
            > "${TMP}/tw.out" 2>&1 < /dev/null
        echo $?
    }
    H="${TMP}/h_tw_warm"; mkdir -p "$H/.ollama/models/manifests/registry.ollama.ai/library/gemma4"
    : > "$H/.ollama/models/manifests/registry.ollama.ai/library/gemma4/e2b"
    rc="$(run_tw "$H")"
    others="$(grep -v -e '^bash -s$' -e 'scutil' "${TMP}/stub.log" | wc -l | tr -d ' ')"
    if [ "$rc" = "2" ] && grep -q 'NOT cold' "${TMP}/tw.out" && grep -q 'gemma4:e2b' "${TMP}/tw.out" && [ "$others" = "0" ]; then
        ok "--require-cold on a warm box: CANNOT-RUN (rc=2), names gemma4:e2b, and 0 other commands reached the host"
    else
        bad "--require-cold on a warm box: rc=${rc}, other host commands=${others}; $(grep -m2 -E 'CANNOT-RUN|cold' "${TMP}/tw.out")"
    fi
    H="${TMP}/h_tw_cold"; mkdir -p "$H"
    rc="$(run_tw "$H")"
    if grep -q 'cold state before staging: cold' "${TMP}/tw.out"; then
        ok "--require-cold on a cold box: passes the cold check and goes on (the later rc=${rc} is a later preflight the fixture does not satisfy)"
    else
        bad "--require-cold on a cold box did not pass the cold check: $(grep -m2 -E 'CANNOT-RUN|cold' "${TMP}/tw.out")"
    fi
fi

echo
echo "=== G. wiring ==="
strip() { if [ -x "$STRIP" ]; then /bin/bash "$STRIP" "$1"; else grep -v '^[[:space:]]*#' "$1"; fi; }
TW_CODE="$(strip "$TW")"; QA_CODE="$(strip "$QA")"; VR_CODE="$(strip "$VR")"
m="$(printf '%s\n' "$TW_CODE" | grep -n '_COLD="$(cold_state_measure 1)"' | head -1 | cut -d: -f1)"
r="$(printf '%s\n' "$TW_CODE" | grep -n 'rule "RUN (unattended' | head -1 | cut -d: -f1)"
if [ -n "$m" ] && [ -n "$r" ] && [ "$m" -lt "$r" ]; then
    ok "ttywalk.sh measures and writes the cold state BEFORE the RUN step (line ${m} < ${r}, comments stripped)"
else
    bad "ttywalk.sh does not measure the cold state before RUN (measure='${m}', run='${r}')"
fi
n="$(printf '%s\n' "$QA_CODE" | grep -c "printf '%s\\\\n' \"\$COLD_ROWS\"")"
[ "$n" = "1" ] && ok "post_walk_qa.sh writes the cold rows into the record exactly once" \
               || bad "post_walk_qa.sh writes the cold rows ${n} times (expected 1)"
n="$(printf '%s\n' "$VR_CODE" | grep -c '_require_cold_walk$')"
[ "$n" = "2" ] && ok "verify_walk_record.sh asks the cold question on BOTH promote paths" \
               || bad "verify_walk_record.sh calls _require_cold_walk ${n} times (expected 2, one per exit-0 path)"

printf '\n== %s pass / %s fail / %s CANNOT-RUN / %s total ==\n' "$PASS" "$FAIL" "$SKIP" "$((PASS+FAIL+SKIP))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
