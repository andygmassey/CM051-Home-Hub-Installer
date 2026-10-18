#!/usr/bin/env bash
# tests/test_precondition_one_settles_like_every_later_opening.sh
#
# v1.0.107 candidate 3 walk: precondition 1 (before opening 1) forgot the one
# memory entry it found, re-read once, and the daemon's own async turn
# consolidation had already landed a fresh entry about the same synthetic
# seed person -- reported as "FORGOT 1 0 api=1 db=0; re-read: PRESENT" and the
# battery stopped CANNOT-RUN. _restore_precondition_before_opening (used
# before every LATER opening) already tolerates exactly this with a bounded
# settle-and-retry loop (tests/test_every_opening_starts_from_clean_memory.sh,
# "a memory re-written once by consolidation is purged again"); precondition-1
# did not, because it was a separate, single-shot copy of the same check. This
# drives run_probe for real (through the precondition-1 block only -- it is
# made to stop right after on a missing admin token, a controlled, unrelated
# halt) and proves precondition-1 now shares the same settle-and-retry helper,
# _settle_purge_seed_person, as i>1.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$HERE/scripts/box_walk_probes/probes/assistant_grounds_the_opening_turn.sh"
pass=0; fail=0
arm() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; else fail=$((fail+1)); printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/probes"; ln -s "$HERE/scripts/box_walk_probes/lib" "$T/lib"
sed '$d' "$PROBE" > "$T/probes/probe_nomain.sh"

# run_probe, stubbed just enough to reach precondition-1 and stop right after
# it on a controlled, unrelated halt (no admin token file). $T/reads is a
# queue of entry counts: each line is how many entries the NEXT
# _memory_mentions_person call reports (0 = absent, ERR = unreadable).
run() {
    ( . "$T/probes/probe_nomain.sh" >/dev/null 2>&1
      box_reachable() { return 0; }
      _read_model_state() { echo "ok test-model"; }
      _read_ram_gb() { echo 24; }
      _memory_mentions_person() {
          r="$(head -1 "$T/reads")"
          [ "$(wc -l < "$T/reads")" -gt 1 ] && sed -i.bak 1d "$T/reads"
          case "$r" in
              0)   echo "READ 50 0" ;;
              ERR) echo "UNREADABLE http 503 upstream timed out" ;;
              *)   echo "READ 50 $r"; i=0; while [ "$i" -lt "$r" ]; do echo "KEY k$i"; i=$((i+1)); done ;;
          esac
      }
      _memory_forget_keys() { echo "FORGOT $# 0 api=$# db=0"; }
      probe_note() { printf 'NOTE %s\n' "$1"; }
      probe_cannot_run() { printf 'CANNOT %s\n' "$1"; }
      sleep() { :; }
      KNOWN_PERSON="seed-person-zz9"; EXPECT_FACT="submarine cable engineer"
      OSTLER_SEED_PERSON_IS_SYNTHETIC=1
      OSTLER_PROBE_PURGE_ROUNDS="${1:-4}"
      run_probe )
}

printf 'PRECONDITION 1 SETTLES LIKE EVERY LATER OPENING\n\n'

# Mirrors test_every_opening_starts_from_clean_memory.sh's i>1 arm exactly:
# present once, one forget, consolidation re-writes it once, re-forgotten,
# then absent -- the battery goes on past precondition-1 instead of stopping.
printf '1\n1\n0\n' > "$T/reads"; out="$(run 4)"
arm "a memory re-written once by consolidation is purged again and precondition 1 goes on" \
    "$(printf '%s' "$out" | grep -c -E '^NOTE precondition 1 RESTORED' | awk '{print ($1==1)?0:1}')" "$out"
arm "it is never reported as a forget that did not take" \
    "$(printf '%s' "$out" | grep -c 'did not take' | awk '{print ($1==0)?0:1}')" "$out"
arm "the battery proceeds past precondition 1 (reaches the later, unrelated token halt)" \
    "$(printf '%s' "$out" | grep -c 'CANNOT.*admin token' | awk '{print ($1==1)?0:1}')" "$out"

# A re-write that never settles within the bounded rounds is still CANNOT-RUN,
# not silently waved through.
printf '1\n1\n1\n1\n' > "$T/reads"; out="$(run 3)"
arm "a re-write that outlasts every settle round still stops the battery CANNOT-RUN" \
    "$(printf '%s' "$out" | grep -c -E '^CANNOT the daemon remembers.*did not take' | awk '{print ($1==1)?0:1}')" "$out"
arm "and names the settle rounds it tried" \
    "$(printf '%s' "$out" | grep -c 'settle round' | awk '{print ($1>0)?0:1}')" "$out"

# An unreadable re-read is retried inside the rounds too, same as i>1.
printf '1\nERR\n0\n' > "$T/reads"; out="$(run 4)"
arm "an unreadable re-read once, then absent: precondition 1 still goes on" \
    "$(printf '%s' "$out" | grep -c -E '^NOTE precondition 1 RESTORED' | awk '{print ($1==1)?0:1}')" "$out"

# MUST-FAIL regression guard: the exact pre-fix shape was a bespoke,
# non-retrying forget-and-reread inline in run_probe, not a call to the
# shared settle helper. If someone reintroduces that shape, this fails.
present_block="$(awk '/if \[ "\$_memstate" = "PRESENT" \]/{f=1} f{print} f && /^    fi$/{exit}' "$T/probes/probe_nomain.sh")"
arm "MUST-FAIL regression guard: precondition 1's PRESENT branch calls the shared settle helper" \
    "$(printf '%s' "$present_block" | grep -c '_settle_purge_seed_person "\$_mem"' | awk '{print ($1==1)?0:1}')" "$present_block"
arm "and does not re-implement its own bare forget-and-reread instead" \
    "$(printf '%s' "$present_block" | grep -cE '_keys=.*sed -n .s/\^KEY' | awk '{print ($1==0)?0:1}')" "$present_block"

printf '\n== %d pass / %d fail / %d total ==\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
