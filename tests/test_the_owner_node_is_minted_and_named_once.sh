#!/usr/bin/env bash
# tests/test_the_owner_node_is_minted_and_named_once.sh -- CM051 #1690.
#
# THE OWNER NODE WAS PRESENT AND DEAD.
#
# `pwg:user_<id>` is the "this is me" anchor: the OBJECT of every
# `pwg:belongsToUser` triple, and the identity the privacy layer branches on
# (identity_resolver/compartment.py `owner_node_iri`). CM041 ships a writer
# that mints it, and CM041 #154 fixed that writer so the one node whose job is
# to answer "who is the owner" can no longer end up carrying two names.
#
# Both were inert. MEASURED on origin/main before this test existed, with a
# positive control of the same shape so a broken predicate could not read as
# an absence:
#
#   --mint-owner / contact_syncer.owner_node in install.sh   0
#   CONTROL, --vcf, a flag install.sh really passes          6
#   test files naming owner_node                             0
#   CONTROL, test files naming contact_syncer               26
#   workflows naming owner_node                              0
#   CONTROL, workflows naming contact_syncer                 6
#
# TWO HALVES, ASSERTING DIFFERENT THINGS, and the split is the point:
#
#   1. WIRING. install.sh actually invokes the module, and it does so BEFORE
#      the wiki compile. A correct writer nobody calls is exactly what #1690
#      recorded, and half 2 alone passes on it.
#   2. BEHAVIOUR. The SHIPPED SPARQL, executed against a real SPARQL 1.1
#      engine, leaves the owner carrying exactly ONE display name -- on a bare
#      graph, on a re-run, and on a graph that already had a better name.
#      Delegated to tests/helpers/check_owner_node_mint.py, which carries its
#      own mutation control.
#
# EXIT: 0 all assertions hold. 1 one or more failed. 2 could not run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
INSTALL="$REPO/install.sh"
HELPER="$REPO/tests/helpers/check_owner_node_mint.py"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
cant() {
	printf '  \033[0;33mCANNOT-RUN\033[0m %s\n' "$1"
	printf '\033[0;33mCANNOT-RUN -- nothing was measured. This is not a pass.\033[0m\n'
	exit 2
}

echo "#1690: the owner node is minted by the install, and carries one name"
echo ""
echo "wiring"

[ -f "$INSTALL" ] || cant "install.sh missing at ${INSTALL}"
[ -f "$HELPER" ]  || cant "behaviour helper missing at ${HELPER}"
command -v "$PY" >/dev/null 2>&1 || cant "no ${PY} on PATH"

# The invocation itself. `grep -c`, never `grep -q`: this file sets
# `pipefail`, and a `producer | grep -q` short-circuits the producer.
calls="$(/usr/bin/grep -c 'contact_syncer\.owner_node' "$INSTALL" || true)"
# CONTROL of the same shape: a module install.sh demonstrably runs. If this
# returns 0 the predicate is broken and the subject's count means nothing.
control="$(/usr/bin/grep -c 'contact_syncer\.places_ingest' "$INSTALL" || true)"
if [ "${control:-0}" -eq 0 ]; then
	cant "the CONTROL (contact_syncer.places_ingest) returns 0 in install.sh, so this grep cannot see an invocation at all. Investigate the control, not the subject."
fi
if [ "${calls:-0}" -ge 1 ]; then
	ok "install.sh invokes contact_syncer.owner_node (${calls} reference(s); control places_ingest ${control})"
else
	bad "install.sh invokes contact_syncer.owner_node 0 times (control places_ingest ${control}) -- the writer is present and dead, which is #1690"
fi

# The RUN line, not a comment. A mention inside the block comment above the
# step would satisfy the count on its own, and that is how a wired-looking
# dead step gets written.
runline="$(/usr/bin/grep -c '^ *\.venv/bin/python -m contact_syncer\.owner_node' "$INSTALL" || true)"
if [ "${runline:-0}" -eq 1 ]; then
	ok "exactly one EXECUTABLE invocation line (not a comment mentioning it)"
else
	bad "${runline:-0} executable invocation line(s) -- expected exactly 1"
fi

# ORDER. The mint must land before the wiki compile or the customer's first
# wiki is compiled from a graph without them in it.
mint_ln="$(/usr/bin/grep -n '^ *\.venv/bin/python -m contact_syncer\.owner_node' "$INSTALL" | head -n 1 | cut -d: -f1)"
# The anchor is the compile INVOCATION, not a message name: install.sh has no
# MSG_ string for this step, and an anchor that does not exist turns the
# ordering assertion into a silent CANNOT-RUN.
wiki_ln="$(/usr/bin/grep -n 'docker compose --profile compile run --rm' "$INSTALL" | head -n 1 | cut -d: -f1)"
if [ -z "${wiki_ln:-}" ]; then
	cant "cannot locate the wiki-compile step in install.sh, so the ordering assertion has no anchor (capped: first match only)"
fi
if [ -n "${mint_ln:-}" ] && [ "${mint_ln}" -lt "${wiki_ln}" ]; then
	ok "the mint (line ${mint_ln}) runs BEFORE the wiki compile (line ${wiki_ln})"
else
	bad "the mint is at line ${mint_ln:-none} and the wiki compile at ${wiki_ln} -- the first wiki would compile without the owner"
fi

# The owner id must reach the module through the ENVIRONMENT, so config.py's
# normaliser owns the IRI derivation. A raw `--user-id "$USER_ID"` skips it,
# and a real answer like "Mrs Smith" mints an IRI the read side cannot match.
#
# SCOPED TO THE INVOCATION, not to the whole file: install.sh legitimately
# passes --user-id to two OTHER tools (the consent recorder and ostler-import),
# so a file-wide count answers a different question and is red by construction.
# The window is the invocation line plus the three continuation lines that
# carry its flags.
#
# GUARDED ON THE INVOCATION EXISTING. With no invocation the window is empty,
# and an empty-window CANNOT-RUN would exit before the two FAILs above are
# reported -- so removing the call would refuse rather than go red, which is
# the wrong verdict for a defect that IS present. Measured while mutating this
# file: rc went 2 instead of 1 until this guard existed.
if [ "${runline:-0}" -ge 1 ]; then
uid_here="$(/usr/bin/grep -A3 '^ *\.venv/bin/python -m contact_syncer\.owner_node' "$INSTALL" \
            | /usr/bin/grep -c -- '--user-id' || true)"
# CONTROL for the same window: the flag we DO pass must be visible in it, or
# the window is empty and the zero above means nothing.
ep_here="$(/usr/bin/grep -A3 '^ *\.venv/bin/python -m contact_syncer\.owner_node' "$INSTALL" \
           | /usr/bin/grep -c -- '--graph-endpoint' || true)"
if [ "${ep_here:-0}" -eq 0 ]; then
	cant "the invocation window carries no --graph-endpoint either, so it is empty and the --user-id zero is not a measurement."
fi
if [ "${uid_here:-0}" -eq 0 ]; then
	ok "the invocation passes no --user-id (control --graph-endpoint ${ep_here} in the same window), so the shipped normaliser derives the IRI"
else
	bad "the invocation passes --user-id, bypassing normalise_user_id -- the minted IRI can disagree with owner_node_iri"
fi
fi

echo ""
echo "behaviour (the SHIPPED SPARQL executed against a real SPARQL engine)"
# stdout and stderr SEPARATED. The shipped config module logs a warning about
# DEFAULT_COUNTRY_CODE at import, and folding that into the assertion stream
# turned a harmless log line into a FAIL. Not `2>/dev/null` either: a real
# traceback must still be readable, so stderr is kept and printed when the
# helper produced no assertions at all.
_err="$(mktemp)"
out="$("$PY" "$HELPER" "$REPO" 2>"$_err")"; rc=$?
if [ -z "$(printf '%s' "$out" | /usr/bin/grep -c -E '^(PASS|FAIL):' || true)" ] \
   || [ "$(printf '%s\n' "$out" | /usr/bin/grep -c -E '^(PASS|FAIL):' || true)" -eq 0 ]; then
	printf '  helper stderr:\n'
	sed 's/^/    /' "$_err"
	rm -f "$_err"
	cant "the behaviour helper emitted no PASS/FAIL assertions (rc=${rc}) -- nothing was measured"
fi
rm -f "$_err"
while IFS= read -r line; do
	case "$line" in
		PASS:*) ok "${line#PASS: }" ;;
		FAIL:*) bad "${line#FAIL: }" ;;
		*)      [ -n "$line" ] && bad "unexpected harness output: $line" ;;
	esac
done <<< "$out"

echo ""
if [ "$fail" -eq 0 ]; then
	printf '\033[0;32mGREEN -- %d assertion(s); the owner is minted and carries one name\033[0m\n' "$pass"
	exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
echo "Do NOT make this pass by deleting the invocation. The writer with no"
echo "caller is the defect #1690 records, not the cure."
exit 1
