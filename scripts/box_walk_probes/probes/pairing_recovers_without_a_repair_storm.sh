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
#
# 🔴 THIS PROBE MINTS A BEARER TOKEN EVERY TIME IT PASSES, AND ITS OWN CEILING
# IS WHAT THAT TOKEN COUNTS AGAINST. Limb 2 below performs a REAL pair against
# :8443 and requires `"paired":true`, which is exactly what persists an entry in
# the `paired_tokens` array that limb 1 counts. Traced entirely from source, no
# box required:
#
#   nothing revokes it            0 revoke/unpair surfaces in the tree
#   --reset does not remove it    ttywalk.sh runs no uninstaller (announced
#                                 since #1516), so config.toml survives a walk
#   an install PRESERVES it       install.sh:12981-13004 reads the existing
#                                 paired_tokens out of the old config and merges
#                                 them forward, DELIBERATELY, so that an upgrade
#                                 does not unpair every device (install.sh:13603)
#   limb 1 fails above            TOKEN_CEILING = 12
#
# ⇒ THE PASSES ACCUMULATE TOWARDS THE FAILURE. After enough walks on one box, a
# BLOCKING probe fails on evidence it manufactured itself, and it says so in the
# language of a customer-visible defect: "a re-pair storm ... the customer sees
# 'Pairing failed (403)'". A walk-minted token produces no 403 for anybody. That
# verdict would send an operator to hunt RECOVER_MAX_ATTEMPTS in useAuth.ts for a
# storm that never happened, while the real cut sat blocked behind it.
#
# So the probe now KEEPS ITS OWN LEDGER and subtracts itself. It reports the raw
# count and the attributable count side by side, and it never silently adjusts:
# an unreadable ledger is CANNOT-RUN, because a probe that cannot separate its
# own footprint from the product's has not earned either verdict.
#
# ⚠️ IT ADJUSTS ONLY WHAT IT RECORDED. Tokens minted by walks taken BEFORE this
# ledger existed are still counted against the product. That is stated in the
# verdict rather than hidden, and it decays: the ledger starts at 0 and only ever
# grows from here.
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

# Evaluated ON THE BOX, like $cfg below: a local `~` would expand to the
# operator's home and is correct only while both machines share a username.
WALK_MINT_LEDGER="${OSTLER_WALK_MINT_LEDGER:-\$HOME/.ostler/state/walk-minted-pair-tokens}"

# THE CEILING TEST AS ITS OWN FUNCTION, so run_probe and its negative control
# are the SAME CODE. The sibling probe pair_state_agreement learned this the
# hard way: an earlier draft of its control inlined a second copy of the parser
# it was meant to be testing, which is a fixture encoding the fix rather than
# the property, and it would have gone green with the real reader still broken.
adjudicate_tokens() {
    # adjudicate_tokens <raw> <minted-by-this-suite> <ceiling>
    # -> "OK <attributable>" | "STORM <attributable>" | "CANNOT <reason>"
    local raw="$1" minted="$2" ceiling="$3" adjusted
    case "$raw" in
        ''|*[!0-9]*) printf 'CANNOT the token count read back as %s, which is not a number' "${raw:-<empty>}"; return ;;
    esac
    case "$minted" in
        ''|*[!0-9]*) printf 'CANNOT the walk mint ledger read back as %s, which is not a number' "${minted:-<empty>}"; return ;;
    esac
    case "$ceiling" in
        ''|*[!0-9]*) printf 'CANNOT the ceiling is %s, which is not a number' "${ceiling:-<empty>}"; return ;;
    esac
    adjusted=$(( raw - minted ))
    # FLOOR AT ZERO, NEVER NEGATIVE. A ledger ahead of the count means somebody
    # pruned config.toml between walks, which is not a storm and must not read
    # as one through a negative comparing low.
    [ "$adjusted" -lt 0 ] && adjusted=0
    if [ "$adjusted" -gt "$ceiling" ]; then
        printf 'STORM %s' "$adjusted"
    else
        printf 'OK %s' "$adjusted"
    fi
}

read_walk_mint_ledger() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_MINTED:-0}"; return
    fi
    local out
    # ABSENT is 0 and says so; UNREADABLE comes back empty and is refused by
    # adjudicate_tokens. A missing file and a failed read are different facts,
    # and this suite exists because they used to print the same.
    out="$(box_run "if [ -f \"${WALK_MINT_LEDGER}\" ]; then /bin/cat \"${WALK_MINT_LEDGER}\"; else printf 0; fi" | tr -d '[:space:]')"
    printf '%s' "${out}"
}

note_minted_pair_token() {
    # Called ONLY where a body carrying "paired":true has actually been seen, so
    # the ledger counts pairings that happened rather than attempts that were
    # made. A refused pair mints nothing and must not be recorded.
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then return; fi
    box_run "d=\$(dirname \"${WALK_MINT_LEDGER}\"); mkdir -p \"\$d\" 2>/dev/null; c=0; if [ -f \"${WALK_MINT_LEDGER}\" ]; then c=\$(/bin/cat \"${WALK_MINT_LEDGER}\" 2>/dev/null | tr -d '[:space:]'); fi; case \"\$c\" in ''|*[!0-9]*) c=0 ;; esac; printf '%s' \"\$((c+1))\" > \"${WALK_MINT_LEDGER}\"" >/dev/null 2>&1
}

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
  local _minted _tokres _tok _attrib
  _minted="$(read_walk_mint_ledger)"
  _tokres="$(adjudicate_tokens "$n" "$_minted" "$TOKEN_CEILING")"
  _tok="${_tokres%% *}"; _attrib="${_tokres#* }"

  if [ "$_tok" = "CANNOT" ]; then
    probe_cannot_run "${_attrib}. The ledger at ${WALK_MINT_LEDGER} must hold a plain integer, because without it this probe cannot separate a product storm from its own pairings -- and it mints one every time it passes. Guessing either way is a verdict it has not earned. Not a pass."
    return
  fi

  probe_note "paired_tokens on disk           : ${n}"
  probe_note "minted by this suite's own runs : ${_minted}  (${WALK_MINT_LEDGER})"
  probe_note "attributable to the product     : ${_attrib}  (ceiling ${TOKEN_CEILING})"
  probe_examined "$_attrib" "paired_tokens attributable to the PRODUCT, after subtracting the ${_minted} this suite minted itself (raw on disk ${n}, ceiling ${TOKEN_CEILING})"

  if [ "$_tok" = "STORM" ]; then
    probe_fail "${_attrib} paired tokens persisted that this suite did not mint (${n} on disk, ${_minted} of them ours) -- a re-pair storm. Each is a bearer token that is never revoked, and the customer sees the losing attempt's 'Pairing failed (403)'. Andy's box had 34 after five minutes."
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
    # A REAL PAIR JUST HAPPENED. Record it before anything else can return:
    # this is the line that puts a token in config.toml, and limb 1 of the NEXT
    # walk is what counts it.
    *'"paired":true'*) note_minted_pair_token ;;
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
      # Two pairs, two tokens. Record the second before failing, or the ledger
      # under-counts and the next walk blames the product for our replay.
      note_minted_pair_token
      probe_fail "CONTROL FAILED: the same code paired TWICE. Pairing codes are meant to be consumed on first use (pairing.rs sets pairing_code = None); a code that never expires is a standing key to the customer's hub."
      return ;;
  esac

  probe_pass "recovery works and does not storm: 8443 accepted a fresh code, refused its replay, and only ${_attrib} of the ${n} persisted tokens are attributable to the product (${_minted} were minted by this suite, including the one this run just added)"
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
    # ── THE ATTRIBUTION ARITHMETIC, DRIVEN THROUGH THE REAL FUNCTION ──────
    #
    # Every case below calls adjudicate_tokens, the same function run_probe
    # calls. Six cases, and each one is a way this could go wrong that would
    # otherwise cost a cut. The two that matter most are 2 and 3: case 2 is the
    # false red this change exists to kill, and case 3 is the false GREEN the
    # change could have introduced while killing it.
    local r
    _at_fail=0
    _at_case() {
        # _at_case <label> <raw> <minted> <expected-token> <expected-value>
        r="$(adjudicate_tokens "$2" "$3" "$TOKEN_CEILING")"
        if [ "${r%% *}" != "$4" ] || [ "${r#* }" != "$5" ]; then
            _at_fail=1
            printf 'VERDICT: BROKEN -- %s: adjudicate_tokens %s %s %s said "%s", expected "%s %s".\n' \
                "$1" "$2" "$3" "$TOKEN_CEILING" "$r" "$4" "$5"
        fi
    }

    # 1. Andy's real box, before this suite ever ran. MUST still be a storm, or
    #    the change has bought a false green with a false red.
    _at_case "the 34-token storm with nothing of ours in it" 34 0 STORM 34

    # 2. THE FALSE RED THIS EXISTS TO KILL. Thirteen walks, thirteen tokens,
    #    every one minted by limb 2 of this very probe. Zero product tokens.
    #    Unadjusted this trips the ceiling of 12 and blocks a cut.
    _at_case "a box walked 13 times and otherwise clean" 13 13 OK 0

    # 3. THE FALSE GREEN THE CHANGE COULD HAVE BOUGHT. A genuine storm on a box
    #    we have also walked. Subtracting ours must NOT hide theirs.
    _at_case "a real storm on a box we have also walked" 20 5 STORM 15

    # 4. Ledger ahead of the count -- somebody pruned config.toml between walks.
    #    Not a storm, and the floor must stop it reading as one.
    _at_case "a ledger ahead of the count (config.toml was pruned)" 3 9 OK 0

    # 5. Exactly at the ceiling is NOT over it. An off-by-one here fails every
    #    correctly configured box.
    _at_case "exactly at the ceiling" 12 0 OK 12

    # 6. An unreadable ledger must REFUSE, never assume zero. Assuming zero is
    #    how our own tokens get blamed on the product.
    r="$(adjudicate_tokens 13 "" "$TOKEN_CEILING")"
    if [ "${r%% *}" != "CANNOT" ]; then
        _at_fail=1
        printf 'VERDICT: BROKEN -- an unreadable mint ledger adjudicated as "%s", not CANNOT.\n' "$r"
    fi

    if [ "$_at_fail" -ne 0 ]; then
        printf '  The attribution arithmetic is what separates this suite own pairings from\n'
        printf '  the product. With it wrong, a blocking probe either blames the product for\n'
        printf '  tokens we minted, or hides a real storm behind them.\n'
        exit "$PROBE_EX_FAIL"
    fi
    probe_note "attribution control: 6 of 6 cases through the real adjudicate_tokens"

    probe_examined 8 "synthetic cases (negative control): a 34-token storm, a clean 3-token box, and 6 attribution cases"
    probe_fail "negative control behaved correctly -- counted 34 single-line tokens as a storm, cleared a 3-token box, and attributed 6 of 6 raw/minted combinations correctly including the walk-only box that used to read as a storm"
    # NOTHING BELOW probe_fail. The `exit "${PROBE_EX_OK:-0}"` that used to sit
    # here is deleted, not merely bypassed: it is unreachable while probe_fail
    # exits, and it would silently RESURRECT this defect the day probe_fail
    # returned instead. The working probes (daemon_is_listening and the other 14)
    # carry no PROBE_EX_OK at all -- measured, zero occurrences.
}

probe_main "$@"
