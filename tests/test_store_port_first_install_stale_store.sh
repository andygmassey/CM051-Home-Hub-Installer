#!/usr/bin/env bash
# ===========================================================================
# A first install must claim its own colima store port even when a STALE store
# container from a prior run answers 401 to the freshly-written credential.
#
# #1253 signal 2 (the store must answer OUR credential) built a deadlock a first
# install cannot escape: a store left running by an earlier walk answers 401 to
# the new key, so the preflight marked 6333/7878 HELD and aborted graph_db_start
# -- the very step that recreates the store WITH the new key. Fix: signal 1 (the
# holder is THIS user's colima forward) plus the single-machine invariant is
# sufficient for 6333/7878, exactly as for the four credential-less ports.
# #549 (a foreign holder) stays HELD via signal 1, NOT via signal 2.
# ===========================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/install.sh"
[ -r "$SRC" ] || { echo "CANNOT-RUN: $SRC unreadable" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
awk '/^_port_is_our_own_forward\(\) \{/,/^    \}$/' "$SRC" > "$WORK/func.sh"
[ -s "$WORK/func.sh" ] || { echo "CANNOT-RUN: could not extract the function" >&2; exit 2; }
# CONTROL: signal 1 (argv names our colima) must still be in the function, or a
# blanket return-0 would pass every assertion below vacuously.
grep -q '.colima/' "$WORK/func.sh" || { echo "CANNOT-RUN: signal 1 absent; wrong subject" >&2; exit 2; }

cat > "$WORK/runner.sh" <<'EOS'
#!/usr/bin/env bash
FUNC="$1"; OWN="$2"; CRC="$3"; PORT="$4"; HH="$5"
rm -rf "$HH"; mkdir -p "$HH/.ostler/secrets"
printf 'user = "x:y"\n' > "$HH/.ostler/secrets/store-curl.conf"
export HOME="$HH" OSTLER_DIR="$HH/.ostler" OSTLER_STORE_AUTH_ENFORCE=1
if [ "$OWN" = ours ]; then ARGV="ssh -N -L ${PORT} ${HH}/.colima/_lima/colima/ssh.sock [mux]"
else ARGV="/usr/bin/ssh other -L ${PORT} /opt/not-ours/colima.sock"; fi
ps(){ printf '%s\n' "$ARGV"; }
curl(){ return "$CRC"; }
source "$FUNC"
_port_is_our_own_forward "$PORT" 12345
EOS
run(){ bash "$WORK/runner.sh" "$WORK/func.sh" "$1" "$2" "$3" "$WORK/h" >/dev/null 2>&1; echo $?; }
fails=0
chk(){ if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (got %s want %s)\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
printf 'a first install claims its own store port through a stale-store 401\n'
chk "stale store 401 on OUR colima 6333 -> claimed (deadlock removed)" "$(run ours 22 6333)" 0
chk "stale store 401 on OUR colima 7878 -> claimed"                    "$(run ours 22 7878)" 0
chk "fresh store 200 on OUR colima 6333 -> claimed"                    "$(run ours 0 6333)" 0
chk "NEGATIVE CONTROL: foreign holder of 6333 -> HELD (#549 via signal 1)" "$(run foreign 22 6333)" 1
chk "NEGATIVE CONTROL: unknown port 9999 -> HELD"                      "$(run ours 0 9999)" 1
printf '  examined 5 assertions\n'
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s)\n' "$fails" >&2; exit 1; }
printf 'PASS: signal 1 is sufficient for the store ports; #549 stays HELD.\n'
