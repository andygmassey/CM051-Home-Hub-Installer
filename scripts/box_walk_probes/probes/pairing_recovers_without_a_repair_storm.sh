#!/usr/bin/env bash
# probes/pairing_recovers_without_a_repair_storm.sh
# ============================================================================
# QUESTION: if a customer's session dies, can they get back in -- ONCE, quietly?
#
# 🔴 THIS FILE REPLACES pairing_recovers_on_the_port_the_app_uses.sh, WHICH
# ASSERTED A DEFECT THAT DOES NOT EXIST. That probe minted one pairing code,
# posted it to :8443 and then to :8000, and called the second rejection a
# failure. It would have FAILED ON A HEALTHY BOX, because the pairing code is
# SINGLE-USE BY DESIGN -- zeroclaw-config/src/pairing.rs sets
# *pairing_code = None the instant a code matches. Whichever port went first
# was always going to spend the code and starve the other. Its "control" (a
# wrong code is refused) proved the PREDICATE and said nothing about the
# SPECIMEN. Keeping it would have taught a future reader to hunt a TLS bug
# that was never there.
#
# WHAT IS ACTUALLY BROKEN, measured on the Mac mini 2026-08-25 from the
# daemon's own log (~/.ostler/logs/ostler-assistant.err):
#
#   08:41:00 .. 08:46:04   ~25 x "New client paired successfully"
#                          in BURSTS OF FIVE, gaps 2.2s 3.0s 4.4s 7.5s 13.4s,
#                          then a pause > 60s, then another burst of five.
#
# That is web/src/hooks/useAuth.ts RECOVER_MAX_ATTEMPTS=5 /
# RECOVER_BASE_DELAY_MS=750 (doubling) / RECOVER_RESET_MS=60000, running as
# designed. Something 401s straight after each SUCCESSFUL pair, so the app
# re-pairs, and when two of its own attempts race the same one-shot code the
# loser's 403 is what the customer sees on screen.
#
# Each re-pair leaks a bearer token that is never revoked. THAT is the
# fingerprint this probe reads, because it is durable, on disk, and needs no
# timing: config.toml carried 34 paired_tokens on Andy's box.
#
# ASSERT THE PROPERTY, NEVER THE TWO-PORT COMPARISON.
# ============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"

PROBE_NAME="pairing_recovers_without_a_repair_storm"
PROBE_QUESTION="if a customer's session dies, can they get back in -- once, quietly?"

# 🔴 THIS PROBE HAD NEVER RUN (fixed 2026-08-26). It defined run(); probe_main
# dispatches run_probe, so every box walk printed "VERDICT: BROKEN -- defines no
# run_probe" and measured nothing. It also called probe_examined with one
# argument where the contract is <count> <unit>, so a rename alone would have
# died on "$2: unbound variable", and it declared no self_test. Sibling of
# app_signature_survives_first_run, broken the same four ways.

# A human who has paired a Mac, a phone and a tablet, and re-paired a couple of
# times over the product's life, is nowhere near this. A re-pair storm blows
# through it in under a minute.
TOKEN_CEILING=12

run_probe() {
  box_reachable || { probe_cannot_run "box not reachable"; return; }

  # Evaluated ON THE BOX. A local `~` would expand to the operator's home and
  # is correct only while both machines happen to share a username.
  local cfg='$HOME/.ostler/assistant-config/config.toml'
  local admin code first second n

  # ── Limb 1: the leaked-token count. Durable, timing-free, and it is the
  # ── defect's own fingerprint.
  if ! box_run "[ -r \"$cfg\" ]"; then
    probe_cannot_run "no readable ${cfg} -- cannot count paired tokens. NOT a pass."
    return
  fi

  # Count on the box. `grep -o ... | grep -c .` rather than `grep -c`, because
  # every token sits on ONE line: a line count would report 1 for 34 tokens.
  n=$(box_run "/usr/bin/grep -o 'enc2:' \"$cfg\" 2>/dev/null | /usr/bin/grep -c . || true")
  if ! printf '%s' "${n:-}" | /usr/bin/grep -qE '^[0-9]+$'; then
    probe_cannot_run "token count came back as '${n:-<empty>}', not a number -- the read failed, so this is not a pass"
    return
  fi
  probe_examined "$n" "paired_tokens in config.toml (ceiling ${TOKEN_CEILING})"

  if [ "$n" -gt "$TOKEN_CEILING" ]; then
    probe_fail "${n} paired tokens persisted -- a re-pair storm. Each is a bearer token that is never revoked, and the customer sees the losing attempt's 'Pairing failed (403)'. Andy's box had 34 after five minutes."
    return
  fi

  # ── Limb 2: pairing still WORKS on the port the app uses, and is single-use.
  # ── Only meaningful when pairing is required; with require_pairing = false
  # ── the guard holds no code and every post is correctly refused.
  if box_run "/usr/bin/grep -q '^require_pairing = false' \"$cfg\""; then
    probe_cannot_run "require_pairing = false on this box, so /pair cannot mint anything -- limb 1 passed (${n} tokens) but recovery is UNTESTED. This is the state TNM left the mini in on 2026-08-25 to get Andy back in; it must be reverted before this row can go green."
    return
  fi

  # ⚠️ WHOSE 8443 IS THIS? MEASURED on archie@.240, 2026-09-05T04:2xZ:
  #
  #     listeners on :8443 owned by this account (lsof -u $(id -u))  0
  #     https://127.0.0.1:8443/pair                                  answers 403
  #
  # Something IS there and it is not ours. On a shared Mac that is another
  # account's Hub, and every verdict limb 2 can produce is then a statement
  # about THAT Hub rather than about the artefact this walk installed. Run A's
  # PASS was as uninformative as run B's FAIL; the flip between them was most
  # likely the other Hub restarting, not our pairing path changing.
  #
  # daemon_is_listening already refuses on exactly this shape for :8000 (see
  # "OCCUPIED BY SOMETHING THIS ACCOUNT DOES NOT OWN"). This is the sixth site
  # in one day where reachable was mistaken for ours -- :11434, the store ports,
  # colima's ssh mux, the process table, :8000, and now the pairing port.
  #
  # Limb 1 above is unaffected: it reads OUR config.toml on disk and stands.
  local _own _ans
  _own=$(box_run "lsof -nP -u \"\$(id -u)\" -a -iTCP:8443 -sTCP:LISTEN 2>/dev/null | grep -c LISTEN") || true
  case "${_own:-0}" in
    ''|*[!0-9]*) _own=0 ;;
  esac
  if [ "$_own" -eq 0 ]; then
    _ans=$(box_run "curl -sk --noproxy '*' --max-time 4 -o /dev/null -w '%{http_code}' -X POST https://127.0.0.1:8443/pair") || true
    case "${_ans:-000}" in
      000|"")
        probe_cannot_run "nothing is listening on :8443 and nothing answered there, so pairing recovery could not be exercised at all. Limb 1 passed (${n} tokens persisted) but recovery is UNMEASURED. Not a pass."
        return ;;
      *)
        probe_cannot_run "8443 is OCCUPIED BY SOMETHING THIS ACCOUNT DOES NOT OWN: lsof (run as the walked user) saw 0 listeners, but a connect answered HTTP ${_ans}. Every pairing verdict below would describe THAT service, not the Hub this walk installed. On a shared Mac this is another account's Hub holding the port; stop it and re-run. This is not a pass and it is not a product failure."
        return ;;
    esac
  fi

  admin=$(box_run 'cat ~/.ostler/secrets/zeroclaw_admin_token 2>/dev/null') || true
  [ -n "${admin:-}" ] || { probe_cannot_run "no zeroclaw_admin_token -- cannot mint a code. NOT a pass."; return; }

  code=$(box_run "curl -s --noproxy '*' --max-time 6 -X POST -H 'Authorization: Bearer ${admin}' http://127.0.0.1:8000/admin/paircode/new | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"pairing_code\"])'") || true
  [ -n "${code:-}" ] || { probe_cannot_run "gateway would not issue a pairing code"; return; }

  # The port the APP uses. One post, one code.
  #
  # ⚠️ TAKE curl'S EXIT CODE. A REFUSAL AND A NON-ANSWER ARE DIFFERENT FINDINGS.
  # MEASURED, archie@.240, two runs of the SAME artefact 28 minutes apart
  # (v1.0.67-20260905T031918Z vs T034741Z): run A passed here, run B printed
  #   "REJECTED a code the gateway had just issued ... Response:"
  # with NOTHING after "Response:". An empty body is the signature of a curl
  # that never got an answer -- --max-time 6 expiring, a refused connection, a
  # TLS handshake that died. A GENUINE rejection carries a JSON body; run A's
  # own replay arm printed {"error":"Invalid pairing code"} to prove it.
  #
  # Without the rc, all three collapse into one FAIL that asserts "a customer
  # whose session dies cannot get back in" -- a product claim about the shipped
  # artefact -- on the strength of a six-second timeout. That is CANNOT-RUN
  # wearing a FAIL's clothes, and it spent a red in the v1.0.67 walk record.
  first=""; _first_rc=0
  first=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' https://127.0.0.1:8443/pair") || _first_rc=$?
  if [ "${_first_rc}" -ne 0 ] || [ -z "${first}" ]; then
    probe_cannot_run "8443 gave NO ANSWER (curl rc=${_first_rc}, body ${#first} bytes). That is a transport failure, not a rejection: a real refusal carries a JSON error body. The pairing path was NOT MEASURED. Not a pass, and not a product failure."
    return
  fi
  case "$first" in
    *'"paired":true'*) : ;;
    *) probe_fail "8443 -- the port the app pairs against -- REJECTED a code the gateway had just issued. A customer whose session dies cannot get back in. Response: ${first:0:100}"
       return ;;
  esac

  # CONTROL, and it is the one the withdrawn probe got backwards: replaying the
  # SAME code must now be refused. If it were accepted, the code is not
  # single-use and every issued code stays live forever -- a worse defect than
  # the one under test, and it would otherwise read as a clean pass.
  #
  # ⚠️ AND THE CONTROL HAS THE INVERSE BUG, WHICH IS THE WORSE HALF. Below, only
  # a body containing '"paired":true' fails. So if this second curl ALSO gets no
  # answer, $second is empty, the case does not match, and the probe walks
  # straight to probe_pass -- reporting "refused its replay" when nothing
  # refused anything. A control that passes by never running is not a control,
  # and this one guards a standing key to the customer's hub.
  second=""; _second_rc=0
  second=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' https://127.0.0.1:8443/pair") || _second_rc=$?
  if [ "${_second_rc}" -ne 0 ] || [ -z "${second}" ]; then
    probe_cannot_run "the single-use CONTROL got no answer from 8443 on the replay (curl rc=${_second_rc}, body ${#second} bytes). The first pair SUCCEEDED, so this cannot be reported as a pass: whether a spent code is still live was NOT MEASURED."
    return
  fi
  probe_examined "1" "replay of the spent code -- response: ${second:0:60}"
  case "$second" in
    *'"paired":true'*)
      probe_fail "CONTROL FAILED: the same code paired TWICE. Pairing codes are meant to be consumed on first use (pairing.rs sets pairing_code = None); a code that never expires is a standing key to the customer's hub."
      return ;;
  esac

  probe_pass "recovery works and does not storm: 8443 accepted a fresh code, refused its replay, and only ${n} tokens are persisted"
}

# ---------------------------------------------------------------------------
# self_test -- the negative control. The counting rule is the whole game here:
# every paired token sits on ONE line of config.toml, so `grep -c` would report
# 1 for thirty-four tokens and a storm would read as a clean box.
# ---------------------------------------------------------------------------
self_test() {
    local fixture
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT

    # A storm: 34 tokens, all on ONE line, exactly as the daemon writes them.
    {
        printf 'require_pairing = true\n'
        printf 'paired_tokens = ['
        for _ in $(seq 34); do printf '"enc2:xxxx", '; done
        printf ']\n'
    } > "$fixture/storm.toml"

    local n
    n=$(/usr/bin/grep -o 'enc2:' "$fixture/storm.toml" 2>/dev/null | /usr/bin/grep -c . || true)
    if [ "${n:-0}" -ne 34 ]; then
        printf 'VERDICT: BROKEN -- counted %s tokens on a 34-token single line.\n' "${n:-none}"
        printf '  grep -c would say 1 here, and a re-pair storm would read as a clean box.\n'
        exit "$PROBE_EX_FAIL"
    fi
    if [ "$n" -le "$TOKEN_CEILING" ]; then
        printf 'VERDICT: BROKEN -- 34 tokens did not exceed the ceiling of %s.\n' "$TOKEN_CEILING"
        exit "$PROBE_EX_FAIL"
    fi

    # A healthy box: a Mac, a phone, a tablet. Must NOT trip the ceiling, or the
    # probe is broken-to-red and its FAILs carry no information.
    printf 'require_pairing = true\npaired_tokens = ["enc2:a", "enc2:b", "enc2:c"]\n' > "$fixture/ok.toml"
    n=$(/usr/bin/grep -o 'enc2:' "$fixture/ok.toml" 2>/dev/null | /usr/bin/grep -c . || true)
    if [ "${n:-0}" -ne 3 ] || [ "$n" -gt "$TOKEN_CEILING" ]; then
        printf 'VERDICT: BROKEN -- a healthy 3-token box read as %s and/or tripped the ceiling.\n' "${n:-none}"
        exit "$PROBE_EX_FAIL"
    fi

    # A SELF-TEST SIGNALS SUCCESS BY GOING RED. See the sibling note in
    # app_signature_survives_first_run.sh -- these two probes were the only 2 of
    # 17 exiting 0 here, which made both BROKEN in phase 1 and therefore SKIPPED
    # in phase 2. This one guards the re-pair storm; the box currently carries 35
    # unrevoked bearer tokens and this probe was not watching.
    #
    # POLARITY, stated once: run_box_walk.sh PHASE 1 drives every probe with
    # --self-test on KNOWN-BAD input and requires rc=1 -- "each probe must be
    # able to FAIL". Anything else is reported BROKEN. The failure branches above
    # print the literal "VERDICT: BROKEN", which phase 1 greps for BEFORE it reads
    # any exit code, precisely so a probe cannot vouch for itself with an exit
    # status.
    #
    # SECOND DEFECT, found independently by Archie2 in #1121 and folded in here:
    # this also read ${PROBE_EX_OK:-0}, and PROBE_EX_OK is defined NOWHERE in
    # lib/probe.sh -- the lib defines PROBE_EX_PASS. The `:-` default silently
    # supplied 0, so the wrong NAME never surfaced as an error. Two bugs wearing
    # one line.
    probe_examined 2 "synthetic token sets (negative control): a 34-token storm and a clean 3-token box"
    probe_fail "negative control behaved correctly -- counted 34 single-line tokens as a storm, cleared a 3-token box"
    # NOTHING BELOW probe_fail. The `exit "${PROBE_EX_OK:-0}"` that used to sit
    # here is deleted, not merely bypassed: it is unreachable while probe_fail
    # exits, and it would silently RESURRECT this defect the day probe_fail
    # returned instead. The working probes (daemon_is_listening and the other 14)
    # carry no PROBE_EX_OK at all -- measured, zero occurrences.
}

probe_main "$@"
