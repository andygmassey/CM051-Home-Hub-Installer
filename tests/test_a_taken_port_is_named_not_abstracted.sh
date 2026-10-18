#!/usr/bin/env bash
# When 11434 is already held, the install must NAME that, not abort as ERR-99.
#
# MEASURED on a console walk of v1.0.73: the install died at step 5 of 41 and
# the customer saw exactly one thing, `ERR-99-INSTALL-ABORT-L12423`, a
# catch-all with no cause. The cause was in ~/.ostler/logs/ollama.err at that
# moment, six times over: "listen tcp 127.0.0.1:11434: bind: address already in
# use".
#
# WHY WAITING COULD NEVER HELP. The readiness loop requires BOTH that the port
# answers AND that our own agent is running. A foreign server makes those
# mutually unsatisfiable by construction: the curl succeeds BECAUSE the foreign
# process answers, and our agent can never bind while it holds the port. The
# loop then times out into a bare `exit 1`.
#
# THE POPULATION IS EVERY REPEAT INSTALLER, not "people who run Ollama": a
# leftover com.ostler.ollama LaunchAgent from a previous install keeps serving,
# because nothing in the reset path stops it. That is how it was found.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0; PASS=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# The extraction exactly as install.sh performs it.
extract() { tail -n 40 "$1" 2>/dev/null | grep -F 'address already in use' | tail -n 1 || true; }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

# ARM 1: the real log shape must yield the evidence.
{ echo "slot print_timing: prompt eval time = 12.3 ms"
  echo "Error: listen tcp 127.0.0.1:11434: bind: address already in use"
  echo "all slots are idle"; } > "$t/ollama.err"
if [ -n "$(extract "$t/ollama.err")" ]; then
    ok "a real bind failure in ollama.err IS found, even under slot chatter"
else
    bad "the bind line was not extracted, so the install would still abort with
         a catch-all while the cause sat in the log"
fi

# ARM 2: CONTROL. A log with no bind failure must yield NOTHING, or the
# curated error would fire on every unrelated timeout and mislead.
{ echo "slot print_timing: prompt eval time = 12.3 ms"; echo "all slots are idle"; } > "$t/quiet.err"
if [ -z "$(extract "$t/quiet.err")" ]; then
    ok "CONTROL: a log with no bind failure yields nothing, so the named error cannot fire spuriously"
else
    bad "a log with no bind failure produced evidence, so this would blame a
         port conflict for unrelated timeouts"
fi

# ARM 3: CONTROL. An ABSENT log must not crash the extraction, and must not
# invent evidence. A missing file and a clean file are different facts, and
# neither is a port conflict.
if [ -z "$(extract "$t/does-not-exist.err")" ]; then
    ok "CONTROL: an absent log yields nothing rather than erroring or inventing"
else
    bad "an absent log produced evidence"
fi

# ARM 4: the curated failure must come BEFORE the bare exit in the file, or it
# can never be reached and this whole change is decorative.
cur="$(grep -n 'ERR-08-OLLAMA-PORT-11434-IN-USE' install.sh | head -1 | cut -d: -f1)"
bare="$(awk 'NR>'"${cur:-0}"' && /^            exit 1$/ {print NR; exit}' install.sh)"
if [ -n "$cur" ] && [ -n "$bare" ] && [ "$cur" -lt "$bare" ]; then
    ok "the named failure at :${cur} precedes the catch-all exit at :${bare}, so it is reachable"
else
    bad "could not establish that the named failure precedes the catch-all exit
         (named=${cur:-none} bare=${bare:-none}). If it follows, the customer
         still gets ERR-99 and nothing here changes what they see."
fi

# ARM 5: the message a customer reads must exist and must name the port.
# A curated code pointing at a missing string is worse than the catch-all.
# grep -c rather than a pipe into a short-circuiting grep. Under the
# `set -uo pipefail` on line 19, a quiet grep exits at its first match and
# SIGPIPEs the producer, so pipefail reports the whole pipeline FAILED
# precisely when the needle IS present, and this arm would read "does not
# name 11434" on a correct string. Measured: the inversion needs a producer
# big enough to fill the pipe buffer (reproduced at 200k lines, not at this
# arm's one-line string), so it is latent here rather than live -- which is
# exactly why it gets fixed now instead of baselined. grep -c must read to
# EOF, so it cannot short-circuit, and it is POSIX rather than a bashism.
_port_named=$(bash -c 'set -u; source ./install.sh.strings.en-GB.sh >/dev/null 2>&1; printf "%s" "$MSG_FAIL_OLLAMA_PORT_IN_USE"' 2>/dev/null | grep -c '11434' || true)
if [ "${_port_named}" -gt 0 ]; then
    ok "the customer-facing message resolves under set -u and names the port"
else
    bad "MSG_FAIL_OLLAMA_PORT_IN_USE is missing or does not name 11434"
fi

printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
