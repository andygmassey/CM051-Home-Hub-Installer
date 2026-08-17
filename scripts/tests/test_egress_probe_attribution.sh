#!/usr/bin/env bash
#
# test_egress_probe_attribution.sh -- the egress probe must not go blind by
# failing to recognise a process as ours.
#
# PROVED-RED-BY: this file, control 2.
#
# The probe's existing --self-test plants a REAL loopback socket and checks the
# boundary regex flags it under a narrow policy and not under a wide one. That
# control was working perfectly and was completely blind to this defect,
# because it never exercised ATTRIBUTION -- only the boundary. The planted
# socket belongs to python3, the old inclusion filter did not list python3, and
# the self-test never noticed because it fed rows straight to the classifier.
#
# So these controls drive the ATTRIBUTION axis, using the recorded reading that
# caught the defect on a real box.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../box_walk_probes/probes/no_unexpected_egress.sh"
FIX="$HERE/../box_walk_probes/fixtures/egress_2026-08-17_mid_install.tsv"
[ -r "$PROBE" ] || { echo "FAIL: no probe at $PROBE"; exit 99; }
[ -r "$FIX" ]   || { echo "FAIL: no fixture at $FIX"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t egressattr_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

classify() { bash "$PROBE" --classify-fixture "$1" > "$TMP/out" 2>"$TMP/err"; echo $?; }

echo "test_egress_probe_attribution"
echo

# ---------------------------------------------------------------------------
# 1. THE REAL READING. Six outside-boundary rows, held by the installer's own
#    curl, limactl and tailscale. All six must be flagged.
# ---------------------------------------------------------------------------
rc="$(classify "$FIX")"
n="$(grep -c . "$TMP/out")"
if [ "$rc" != 1 ]; then no "the real mid-install capture did not flag anything (rc=$rc)" "$(cat "$TMP/out" "$TMP/err")"
elif [ "$n" != 6 ]; then no "expected 6 flagged rows, got $n" "$(cat "$TMP/out")"
else
    missing=""
    for p in curl limactl tailscale; do
        [ "$(grep -c "^${p}	" "$TMP/out")" -gt 0 ] || missing="${missing} ${p}"
    done
    [ -z "$missing" ] && ok "real capture -> 6 flagged, including curl, limactl and tailscale" \
                      || no "flagged 6 but missed:${missing}" "$(cat "$TMP/out")"
fi

# ---------------------------------------------------------------------------
# 2. THE REGRESSION CONTROL, AND IT IS THE POINT OF THE FILE.
#    Restore the ORIGINAL inclusion filter by naming every process in the
#    fixture EXCEPT the product list as "the operator's". That is behaviourally
#    what the old code did: keep only ostler|qdrant|oxigraph|ollama|mkdocs.
#    Under it, the same six rows must vanish. If this control ever reports
#    flagged rows, the old filter was not actually blind and this whole change
#    rests on a false premise.
# ---------------------------------------------------------------------------
rc="$(OSTLER_EGRESS_FOREIGN_RE='^(curl|limactl|tailscale|llama-ser|python3.1|Mail|WhatsApp|rapportd|sshd-sess|ssh)[[:space:]]' classify "$FIX")"
n="$(grep -c . "$TMP/out" 2>/dev/null || echo 0)"
if [ "$rc" = 1 ] && [ "$n" -gt 0 ]; then
    no "the OLD filter flagged $n rows -- the premise of this fix is wrong" "$(cat "$TMP/out")"
else
    ok "under the OLD product-name filter the same capture flags NOTHING (the blindness, reproduced)"
fi

# ---------------------------------------------------------------------------
# 3. The operator's own apps must NOT be attributed to us. Mail and WhatsApp
#    hold real outside-boundary sockets in the fixture (IMAP, XMPP) and both
#    came back flagged on the first run of this change, because the exclusion
#    was anchored with $ instead of to the tab and matched nothing.
# ---------------------------------------------------------------------------
classify "$FIX" >/dev/null
if [ "$(grep -cE '^(Mail|WhatsApp)	' "$TMP/out")" -gt 0 ]; then
    no "an operator app was attributed to Ostler -- the exclusion anchor is wrong again" "$(cat "$TMP/out")"
else
    ok "Mail and WhatsApp are excluded despite holding real outside-boundary sockets"
fi

# ---------------------------------------------------------------------------
# 4. It can still say GREEN. A capture with nothing outside the boundary must
#    flag nothing and exit 0, or the probe is a permanent red nobody will keep.
# ---------------------------------------------------------------------------
printf 'ollama\t1\t127.0.0.1:11434\ncurl\t2\t192.168.1.50:443\ntailscale\t3\t100.87.179.65:443\n' > "$TMP/clean.tsv"
rc="$(classify "$TMP/clean.tsv")"
[ "$rc" = 0 ] && ok "loopback + LAN + tailnet only -> GREEN (the probe can pass)" \
              || no "a clean capture was flagged (rc=$rc)" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 5. A fixture of nothing but operator processes is CANNOT-RUN, never a pass.
#    Nothing of ours was observed, so nothing about our egress was measured.
# ---------------------------------------------------------------------------
printf 'Mail\t1\t17.57.154.7:993\nSafari\t2\t93.184.216.34:443\n' > "$TMP/foreign.tsv"
rc="$(classify "$TMP/foreign.tsv")"
[ "$rc" = 2 ] && ok "only operator processes -> CANNOT-RUN (rc=2), not a quiet pass" \
              || no "a reading containing nothing of ours returned rc=$rc" "$(cat "$TMP/out" "$TMP/err")"

# ---------------------------------------------------------------------------
# 6. An absent fixture is CANNOT-RUN.
# ---------------------------------------------------------------------------
rc="$(classify "$TMP/nope.tsv")"
[ "$rc" = 2 ] && ok "absent fixture -> CANNOT-RUN (rc=2)" || no "absent fixture gave rc=$rc"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL EGRESS ATTRIBUTION CONTROLS PASSED"
