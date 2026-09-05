#!/usr/bin/env bash
# A NON-ANSWER FROM 8443 IS NOT A REJECTION, AND A NON-ANSWERED CONTROL IS NOT A PASS.
#
# WHY THIS EXISTS. MEASURED on archie@.240: the SAME artefact (v1.0.67, one
# sha256) walked twice, 28 minutes apart, and exactly one probe changed its
# mind:
#
#     v1.0.67-20260905T031918Z   pairing_recovers_without_a_repair_storm  PASS
#     v1.0.67-20260905T034741Z   pairing_recovers_without_a_repair_storm  FAIL
#
# The FAIL read:
#
#     VERDICT: FAIL -- 8443 -- the port the app pairs against -- REJECTED a
#     code the gateway had just issued. A customer whose session dies cannot
#     get back in. Response:
#
# NOTHING AFTER "Response:". The body was empty. An empty body is the signature
# of a curl that never got an answer (--max-time 6 expiring, connection refused,
# TLS handshake dying), because a GENUINE refusal carries a JSON body -- the
# same run's replay arm printed {"error":"Invalid pairing code"} to prove it.
#
# The probe captured curl's stdout and never took its exit code, so three
# distinct states collapsed into one FAIL:
#
#     transport failed    -> should be CANNOT-RUN
#     gateway refused     -> FAIL, correctly
#     gateway accepted    -> PASS
#
# That spent a red in walks/v1.0.67.tsv, which gates the customer download, and
# it asserted a product claim about the shipped artefact on a six-second timeout.
#
# ⚠️ THE CONTROL ARM HAD THE INVERSE BUG AND IT IS THE WORSE HALF. The single-use
# check only failed on a body containing '"paired":true'. If the replay curl also
# got no answer the body was empty, the case did not match, and the probe fell
# through to probe_pass reporting "refused its replay" -- when nothing refused
# anything. A control that passes by never running is not a control, and this one
# guards whether a spent pairing code is still a live key to the customer's hub.
#
# THE TEST DRIVES THE REAL run_probe. It extracts the function from the probe
# file and executes it against a stubbed box_run, so the text under test is the
# text that ships. A paraphrase here would pass forever while the probe drifted.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/box_walk_probes/probes/pairing_recovers_without_a_repair_storm.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no probe at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Drive the REAL run_probe against a scripted 8443 ─────────────────────────
# $1 probe source file
# $2 what the FIRST /pair call does:   ok | refuse | silent
# $3 what the SECOND /pair call does:  refuse | accept | silent
# $4 who owns :8443 (optional, default "mine"): mine | foreign | nothing
# Echoes the probe's own VERDICT word.
_verdict() {
    local src="$1" a="$2" b="$3" own="${4:-mine}" h="${WORK}/h.sh"
    local fn; fn="$(awk '/^run_probe\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$src")"
    [ -n "$fn" ] || { printf 'NOFN'; return; }
    cat > "$h" <<HDR
set -uo pipefail
TOKEN_CEILING=12
PROBE_EX_PASS=0; PROBE_EX_FAIL=1; PROBE_EX_CANNOT_RUN=2
probe_examined() { :; }
probe_note()     { :; }
probe_pass()       { printf 'PASS\n';       exit 0; }
probe_fail()       { printf 'FAIL\n';       exit 1; }
probe_cannot_run() { printf 'CANNOT-RUN\n'; exit 2; }
box_reachable() { return 0; }
# THE COUNTER IS A FILE, NOT A VARIABLE. box_run is invoked inside \$( ), which
# is a SUBSHELL: an arithmetic increment there is discarded on return, so a
# shell variable would report "first call" on every call and the replay arm
# would be handed the first call's behaviour forever. Measured while writing
# this test -- the healthy-box arm reported FAIL on BOTH trees, and that it
# failed on the CONTROL too is what proved the fault was mine and not the fix's.
_PAIRN_F="${WORK}/paircount"; : > "\$_PAIRN_F"
box_run() {
  case "\$1" in
    *'-r '*)                 return 0 ;;                       # config readable
    *"grep -o 'enc2:'"*)     printf '1\n'; return 0 ;;         # one token, under ceiling
    *'require_pairing = false'*) return 1 ;;                   # pairing IS required
    *zeroclaw_admin_token*)  printf 'SYNTHETIC-ADMIN-TOKEN\n'; return 0 ;;
    *paircode/new*)          printf 'SYNTHETIC-CODE\n'; return 0 ;;
    *lsof*8443*)
      case '$own' in mine) printf '1\n' ;; *) printf '0\n' ;; esac; return 0 ;;
    *'%{http_code}'*8443*)
      # The OWNERSHIP probe, not a pairing attempt. It must be matched BEFORE the
      # arm below, because this command also contains the string 8443/pair --
      # and a stub that let it fall through would silently consume a pair slot.
      case '$own' in
        foreign) printf '403' ;;
        nothing) printf '000' ;;
        *)       printf '403' ;;
      esac; return 0 ;;
    *8443/pair*)
      printf 'x' >> "\$_PAIRN_F"
      if [ "\$(wc -c < "\$_PAIRN_F" | tr -d ' ')" -eq 1 ]; then _M='$a'; else _M='$b'; fi
      case "\$_M" in
        ok)      printf '{"paired":true}\n'; return 0 ;;
        accept)  printf '{"paired":true}\n'; return 0 ;;
        refuse)  printf '{"error":"Invalid pairing code"}\n'; return 0 ;;
        silent)  return 28 ;;                                  # curl timeout: no stdout, non-zero
      esac ;;
    *) return 0 ;;
  esac
}
HDR
    printf '%s\n' "$fn" >> "$h"
    printf 'run_probe\n' >> "$h"
    bash "$h" 2>/dev/null | tail -1
}

echo "── subject: this tree ──"

case "$(_verdict "$SUBJECT" silent refuse)" in
    NOFN)       echo "CANNOT-RUN: run_probe was not extractable from the probe." >&2; exit 2 ;;
    CANNOT-RUN) ok "8443 giving NO ANSWER on the first pair reads as CANNOT-RUN, not a rejection" ;;
    FAIL)       bad "a transport failure is still reported as FAIL -- this is the measured defect" ;;
    *)          bad "a transport failure produced '$(_verdict "$SUBJECT" silent refuse)'" ;;
esac

case "$(_verdict "$SUBJECT" refuse refuse)" in
    FAIL) ok "CONTROL: a GENUINE refusal (JSON error body, rc=0) still FAILS, so the fix did not blind the probe" ;;
    *)    bad "a real rejection now reports '$(_verdict "$SUBJECT" refuse refuse)' -- the defect this probe exists for is no longer detected" ;;
esac

case "$(_verdict "$SUBJECT" ok refuse)" in
    PASS) ok "CONTROL: a healthy box (pair accepted, replay refused) still PASSES" ;;
    *)    bad "a healthy box reports '$(_verdict "$SUBJECT" ok refuse)' -- the probe is broken-to-red and its FAILs carry no information" ;;
esac

case "$(_verdict "$SUBJECT" ok silent)" in
    CANNOT-RUN) ok "the single-use CONTROL getting no answer reads as CANNOT-RUN, not as 'refused its replay'" ;;
    PASS)       bad "a control that never ran reported PASS. A spent code could be a standing key and this would say the box is clean." ;;
    *)          bad "an unanswered control produced '$(_verdict "$SUBJECT" ok silent)'" ;;
esac

case "$(_verdict "$SUBJECT" ok accept)" in
    FAIL) ok "CONTROL ON THE CONTROL: a code that pairs TWICE still FAILS, so the arm is live and not merely quiet" ;;
    *)    bad "a twice-usable pairing code reports '$(_verdict "$SUBJECT" ok accept)'" ;;
esac

case "$(_verdict "$SUBJECT" ok refuse foreign)" in
    CANNOT-RUN) ok "a :8443 THIS ACCOUNT DOES NOT OWN reads as CANNOT-RUN, not as a verdict about our artefact" ;;
    PASS)       bad "the probe PASSED against a foreign listener. Measured on .240: 0 listeners owned by this account, yet 8443 answers 403. That PASS would describe another account's Hub." ;;
    *)          bad "a foreign :8443 produced '$(_verdict "$SUBJECT" ok refuse foreign)'" ;;
esac

case "$(_verdict "$SUBJECT" ok refuse nothing)" in
    CANNOT-RUN) ok "nothing listening and nothing answering on :8443 reads as CANNOT-RUN, not a pass" ;;
    *)          bad "an absent :8443 produced '$(_verdict "$SUBJECT" ok refuse nothing)'" ;;
esac

case "$(_verdict "$SUBJECT" ok refuse mine)" in
    PASS) ok "CONTROL ON THE OWNERSHIP GUARD: when the port IS ours, the probe still adjudicates normally" ;;
    *)    bad "the ownership guard fires even when we own the port ('$(_verdict "$SUBJECT" ok refuse mine)') -- it would blind every real verdict" ;;
esac

# ── NEGATIVE CONTROL, pinned to the tree that PRODUCED the flip ──────────────
# Pinned to a fixed sha, never origin/main: a control that reads a branch
# inverts the moment this fix merges and then vouches for nothing.
_CONTROL_SHA="5532772b"
echo "── negative control: ${_CONTROL_SHA} (the tree whose walk flipped) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:scripts/box_walk_probes/probes/pairing_recovers_without_a_repair_storm.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:scripts/box_walk_probes/probes/pairing_recovers_without_a_repair_storm.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA} is unreadable. A shallow clone" >&2
    echo "  cannot see it, and scanning nothing must not read as a passing control." >&2
    exit 2
fi

case "$(_verdict "$_ctl" silent refuse)" in
    NOFN) echo "CANNOT-RUN: run_probe was not extractable from the control blob." >&2; exit 2 ;;
    FAIL) ok "control ${_CONTROL_SHA}: a transport failure reports FAIL there, reproducing the flip that spent a red in walks/v1.0.67.tsv" ;;
    *)    bad "control ${_CONTROL_SHA}: a transport failure reports '$(_verdict "$_ctl" silent refuse)', so this harness is not measuring the defect" ;;
esac

case "$(_verdict "$_ctl" ok silent)" in
    PASS) ok "control ${_CONTROL_SHA}: an unanswered single-use control reports PASS there -- the false green this fix removes" ;;
    *)    bad "control ${_CONTROL_SHA}: an unanswered control reports '$(_verdict "$_ctl" ok silent)'; the inverse bug is not reproduced, so that half of the fix is unproven" ;;
esac

case "$(_verdict "$_ctl" ok refuse)" in
    PASS) ok "CONTROL ON THE CONTROL: the pre-fix tree is fine on a healthy box, so TRANSPORT is the discriminator and not general breakage" ;;
    *)    bad "the pre-fix tree also fails on a healthy box; the control proves nothing about transport specifically" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
