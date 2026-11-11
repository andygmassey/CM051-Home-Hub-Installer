#!/usr/bin/env bash
# The iMessage catch-up adapter must be able to import ostler_fda (2026-11-11).
#
# services/imessage_source/catchup.py does `from ostler_fda.sink_health import
# sink_healthy` at import time. Its catch-up runner (bin/catchup.d/60-imessage.sh)
# runs under the imessage-source venv with PYTHONPATH = lib + services/imessage-source,
# and NEITHER of those holds ostler_fda. So the only place ostler_fda can come from
# is the venv itself, which install.sh builds from the feed's venv_deps argument.
# That argument was "pyyaml". On the Mini16 box the venv has pyyaml and no ostler_fda,
# so every tick died with rc=3: "could not load ... No module named 'ostler_fda'".
#
# The check is derived from the adapter, not hard-coded: every top-level
# `ostler_fda` import in the iMessage catch-up module must be in the iMessage
# feed's venv deps. Add an ostler_fda import without the dep and this goes RED.
#
# THREE OUTCOMES. CANNOT-RUN (exit 2) is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
CATCHUP="${REPO}/vendor/imessage_source/catchup.py"
[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }
[ -f "$CATCHUP" ] || { echo "CANNOT-RUN: no vendor/imessage_source/catchup.py" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }

# 1. What the adapter needs from ostler_fda (the source of truth).
needed="$(sed -n 's/^from ostler_fda[.a-z_]* import .*/ostler_fda/p; s/^import ostler_fda.*/ostler_fda/p' "$CATCHUP" | sort -u)"
[ -n "$needed" ] && ok "catchup.py imports ostler_fda at module level (so the venv must provide it)" \
    || bad "catchup.py no longer imports ostler_fda; this test's premise is stale"

# 2. What the iMessage feed installs into its venv.
line="$(grep -E '^    _install_conversation_feed imessage ' "$INSTALL")"
[ -n "$line" ] || { echo "CANNOT-RUN: no _install_conversation_feed imessage line in install.sh" >&2; exit 2; }
deps="$(printf '%s\n' "$line" | sed -E 's/^.*services\/imessage_source "([^"]*)".*$/\1/')"
[ -n "$deps" ] || { echo "CANNOT-RUN: could not read the imessage venv deps from: $line" >&2; exit 2; }
echo "  imessage venv deps: \"${deps}\""

# 3. Every needed module is in the venv deps.
for m in $needed; do
    case " ${deps} " in
        *" ${m} "*) ok "imessage venv deps include ${m}" ;;
        *)          bad "imessage venv deps \"${deps}\" lack ${m}: services.imessage_source.catchup cannot import ${m} (rc=3 every tick)" ;;
    esac
done

echo "  pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
