#!/bin/bash
# reclassify-subject-names is WIRED into install.sh, logs its counts, and never
# aborts the install (CM051 #2544, v1.0.107)
# ============================================================================
#
# The one-off repair `reclassify-subject-names` (vendor/cm021/src/cli.py)
# shipped DARK in the first push of CM051 #2596: registered in the CLI, invoked
# by nothing. This test extracts the REAL install.sh block (not a paraphrase,
# which would stay green while install.sh drifted) and RUNS it, under the same
# `set -Eeuo pipefail` install.sh uses, with a stub standing in for the
# pwg-email-ingest binary.
#
# Arms:
#   0. WIRING: install.sh invokes `reclassify-subject-names`, AFTER
#      `reclassify-mail`, with the same binary and graph endpoint variables.
#      Fails the moment install.sh stops invoking it.
#   1. Clean box: stub prints people_examined 4, subject_shaped 0. INFO line
#      carries the counts, marker written, install continues.
#   2. Marker present: the stub is NOT invoked.
#   3. Non-zero exit: WARN naming the exit code, NO marker, install continues.
#   4. errors non-empty: WARN naming the error count, NO marker, install
#      continues.
#   5. Garbage output: WARN "no readable result", NO marker, install continues.
#
# Control: the extraction is non-empty and holds the invocation, so "nothing
# ran" cannot read as every arm passing.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
PASS=0; FAIL=0
ok()  { echo "  [pass] $*"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no $INSTALL"; exit 2; }

echo "== arm 0: wiring =="
n_mail="$(grep -n 'reclassify-mail "\$HOME/Library/Mail"' "$INSTALL" | head -1 | cut -d: -f1)"
n_subj="$(grep -n '"\$_HYDRATE_EMAIL_BIN" reclassify-subject-names' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -z "$n_subj" ]; then
    bad "install.sh does not invoke reclassify-subject-names through \$_HYDRATE_EMAIL_BIN -- the repair ships dark"
elif [ -z "$n_mail" ]; then
    bad "reclassify-mail invocation not found; cannot check the order"
elif [ "$n_subj" -le "$n_mail" ]; then
    bad "reclassify-subject-names (line $n_subj) runs before reclassify-mail (line $n_mail)"
else
    ok "invoked at install.sh:$n_subj, after reclassify-mail at :$n_mail"
fi
if sed -n "${n_subj:-1},$(( ${n_subj:-1} + 2 ))p" "$INSTALL" | grep -q -- '--graph-endpoint "\$_HYDRATE_OXIGRAPH_EMAIL"'; then
    ok "same graph endpoint as reclassify-mail"
else
    bad "reclassify-subject-names is not given --graph-endpoint \"\$_HYDRATE_OXIGRAPH_EMAIL\""
fi

BLOCK="$(awk '
    /^    # v1\.0\.107 \(CM051 #2544\): a From-header display name is not necessarily a/ {f=1}
    f {print}
    f && /^    unset _RECLASSIFY_SUBJ_MARKER/ {exit}
' "$INSTALL")"

echo "== control: the extraction is non-empty and carries the invocation =="
if [ -n "$BLOCK" ] && printf '%s' "$BLOCK" | grep -q 'reclassify-subject-names' \
   && printf '%s' "$BLOCK" | grep -q '_RECLASSIFY_SUBJ_MARKER'; then
    ok "extracted $(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ') lines"
else
    # Arm 0 already failed when the invocation is gone: that is a FAIL (exit
    # 1), not a CANNOT-RUN. Only an extraction failure with arm 0 green is
    # CANNOT-RUN (exit 2).
    [ "$FAIL" -gt 0 ] && { echo "reclassify-subject-names wiring: $PASS passed, $FAIL failed"; exit 1; }
    echo "CANNOT-RUN: could not extract the install.sh block"; exit 2
fi

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

run_arm() {   # run_arm <name> <stub body> [premark]
    local name="$1" body="$2" premark="${3:-}" d="$SB/$1"
    mkdir -p "$d/ostler/state" "$d/bin"
    printf '#!/bin/bash\ntouch "%s/invoked"\n%s\n' "$d" "$body" > "$d/bin/ingest"
    chmod +x "$d/bin/ingest"
    [ -n "$premark" ] && echo premarked > "$d/ostler/state/email_reclassify_subject_names_v1.done"
    cat > "$d/run.sh" <<EOF
set -Eeuo pipefail
info() { echo "INFO \$*"; }
warn() { echo "WARN \$*"; }
OSTLER_DIR="$d/ostler"
_HYDRATE_EMAIL_BIN="$d/bin/ingest"
_HYDRATE_OXIGRAPH_EMAIL="http://127.0.0.1:1"
_HYDRATE_EMAIL_LOG="$d/ingest.log"
$BLOCK
echo REACHED_AFTER_BLOCK
EOF
    bash "$d/run.sh" > "$d/out" 2>&1
    echo "$?" > "$d/rc"
}
marker() { echo "$SB/$1/ostler/state/email_reclassify_subject_names_v1.done"; }

echo "== arm 1: clean box =="
run_arm clean 'echo "{\"people_examined\": 4, \"subject_shaped\": 0, \"people_demoted\": 0, \"errors\": []}"'
grep -q '^INFO .*people_examined 4, subject_shaped 0, people_demoted 0, errors 0' "$SB/clean/out" \
    && ok "INFO logs people_examined 4, subject_shaped 0" || bad "no INFO count line: $(cat "$SB/clean/out")"
[ -f "$(marker clean)" ] && ok "marker written" || bad "marker not written on success"
grep -q REACHED_AFTER_BLOCK "$SB/clean/out" && ok "install continues" || bad "install did not continue"

echo "== arm 2: marker present =="
run_arm premarked 'echo "{}"' yes
[ ! -f "$SB/premarked/invoked" ] && ok "not invoked when marker exists" || bad "invoked despite marker"

echo "== arm 3: non-zero exit =="
run_arm failing 'echo "{\"people_examined\": 2, \"subject_shaped\": 1, \"people_demoted\": 0, \"errors\": []}"; exit 3'
grep -q '^WARN .*exited 3' "$SB/failing/out" && ok "WARN names exit 3" || bad "no WARN naming the exit: $(cat "$SB/failing/out")"
[ ! -f "$(marker failing)" ] && ok "no marker" || bad "marker written after a failure"
grep -q REACHED_AFTER_BLOCK "$SB/failing/out" && ok "install continues" || bad "the failure ABORTED the install"

echo "== arm 4: errors reported =="
run_arm errs 'echo "{\"people_examined\": 5, \"subject_shaped\": 2, \"people_demoted\": 0, \"errors\": [\"HTTPError\", \"HTTPError\"]}"'
grep -q '^WARN .*errors 2' "$SB/errs/out" && ok "WARN names errors 2" || bad "errors swallowed: $(cat "$SB/errs/out")"
[ ! -f "$(marker errs)" ] && ok "no marker" || bad "marker written despite errors"
grep -q REACHED_AFTER_BLOCK "$SB/errs/out" && ok "install continues" || bad "install did not continue"

echo "== arm 5: unreadable output =="
run_arm garbage 'echo "Traceback (most recent call last)"'
grep -q '^WARN .*no readable result' "$SB/garbage/out" && ok "WARN on unreadable result" || bad "unreadable result not warned: $(cat "$SB/garbage/out")"
[ ! -f "$(marker garbage)" ] && ok "no marker" || bad "marker written for unreadable output"
grep -q REACHED_AFTER_BLOCK "$SB/garbage/out" && ok "install continues" || bad "install did not continue"

echo
echo "reclassify-subject-names wiring: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
