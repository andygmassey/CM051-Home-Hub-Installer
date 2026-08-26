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

# A human who has paired a Mac, a phone and a tablet, and re-paired a couple of
# times over the product's life, is nowhere near this. A re-pair storm blows
# through it in under a minute.
TOKEN_CEILING=12

run() {
  box_reachable || { probe_cannot_run "box not reachable"; return; }

  local cfg=~/.ostler/assistant-config/config.toml
  local admin code first second n

  # ── Limb 1: the leaked-token count. Durable, timing-free, and it is the
  # ── defect's own fingerprint.
  if ! box_run "[ -r '$cfg' ]"; then
    probe_cannot_run "no readable ${cfg} -- cannot count paired tokens. NOT a pass."
    return
  fi

  # Count on the box. `grep -o ... | grep -c .` rather than `grep -c`, because
  # every token sits on ONE line: a line count would report 1 for 34 tokens.
  n=$(box_run "/usr/bin/grep -o 'enc2:' '$cfg' 2>/dev/null | /usr/bin/grep -c . || true")
  if ! printf '%s' "${n:-}" | /usr/bin/grep -qE '^[0-9]+$'; then
    probe_cannot_run "token count came back as '${n:-<empty>}', not a number -- the read failed, so this is not a pass"
    return
  fi
  probe_examined "paired_tokens in config.toml: ${n} (ceiling ${TOKEN_CEILING})"

  if [ "$n" -gt "$TOKEN_CEILING" ]; then
    probe_fail "${n} paired tokens persisted -- a re-pair storm. Each is a bearer token that is never revoked, and the customer sees the losing attempt's 'Pairing failed (403)'. Andy's box had 34 after five minutes."
    return
  fi

  # ── Limb 2: pairing still WORKS on the port the app uses, and is single-use.
  # ── Only meaningful when pairing is required; with require_pairing = false
  # ── the guard holds no code and every post is correctly refused.
  if box_run "/usr/bin/grep -q '^require_pairing = false' '$cfg'"; then
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
  probe_examined "replay of the spent code: ${second:0:60}"
  case "$second" in
    *'"paired":true'*)
      probe_fail "CONTROL FAILED: the same code paired TWICE. Pairing codes are meant to be consumed on first use (pairing.rs sets pairing_code = None); a code that never expires is a standing key to the customer's hub."
      return ;;
  esac

  probe_pass "recovery works and does not storm: 8443 accepted a fresh code, refused its replay, and only ${n} tokens are persisted"
}

probe_main run
