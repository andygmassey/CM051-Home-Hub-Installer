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

  admin=$(box_run 'cat ~/.ostler/secrets/zeroclaw_admin_token 2>/dev/null') || true
  [ -n "${admin:-}" ] || { probe_cannot_run "no zeroclaw_admin_token -- cannot mint a code. NOT a pass."; return; }

  code=$(box_run "curl -s --noproxy '*' --max-time 6 -X POST -H 'Authorization: Bearer ${admin}' http://127.0.0.1:8000/admin/paircode/new | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"pairing_code\"])'") || true
  [ -n "${code:-}" ] || { probe_cannot_run "gateway would not issue a pairing code"; return; }

  # The port the APP uses. One post, one code.
  first=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' https://127.0.0.1:8443/pair")
  case "$first" in
    *'"paired":true'*) : ;;
    *) probe_fail "8443 -- the port the app pairs against -- REJECTED a code the gateway had just issued. A customer whose session dies cannot get back in. Response: ${first:0:100}"
       return ;;
  esac

  # CONTROL, and it is the one the withdrawn probe got backwards: replaying the
  # SAME code must now be refused. If it were accepted, the code is not
  # single-use and every issued code stays live forever -- a worse defect than
  # the one under test, and it would otherwise read as a clean pass.
  second=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' https://127.0.0.1:8443/pair")
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

    printf 'VERDICT: SELF-TEST PASS -- counted 34 single-line tokens as a storm, cleared a 3-token box.\n'
    exit "${PROBE_EX_OK:-0}"
}

probe_main "$@"
