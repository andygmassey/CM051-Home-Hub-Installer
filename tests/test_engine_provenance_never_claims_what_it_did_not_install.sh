#!/usr/bin/env bash
#
# THE PROVENANCE RECORD MUST NEVER CLAIM WE INSTALLED SOMETHING WE DID NOT.
# =========================================================================
#
# The record exists so that when a customer's wiki is dark we can say a TRUE
# thing about whose engine it is. Its entire value is that "not ours" can be
# trusted. A record that over-claims is worse than no record, because it gets
# quoted back at us by someone holding a broken product.
#
# So the assertions here are deliberately lopsided: most of them try to make
# the module claim credit it has not earned.
#
# ⚠️ BOUND: this exercises the module against synthetic PATHs and a temp dir.
# It does NOT prove install.sh calls it at the right moment -- that is a
# separate wiring assertion, and a green here says nothing about it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO_ROOT}/lib/ostler-engine-provenance.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

echo
echo "== the engine provenance record must be derived, never asserted =="
echo

if [[ ! -r "$LIB" ]]; then
    echo "CANNOT-RUN: ${LIB} is not readable." >&2
    echo "  Nothing was measured. This is NOT a pass -- exit 2." >&2
    exit 2
fi
ok "CANNOT-RUN check: the provenance module is readable"

# shellcheck source=/dev/null
. "$LIB"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAKEBIN="${WORK}/bin"; mkdir -p "$FAKEBIN"
REAL_PATH="$PATH"

stub()   { printf "#!/bin/sh\nexit 0\n" > "${FAKEBIN}/$1"; /bin/chmod +x "${FAKEBIN}/$1"; }
unstub() { /bin/rm -f "${FAKEBIN}/$1"; }
# Stubs first, then ONLY the system coreutils. Homebrew is deliberately off
# the end: that is where a real colima/docker lives, so excluding it makes an
# "absent" case genuinely absent. /usr/bin and /bin stay because the module
# itself needs mkdir, date and sed -- emptying PATH entirely made the module
# unable to run its own dependencies, and every record silently went unwritten.
isolate() { PATH="${FAKEBIN}:/usr/bin:/bin"; _OSTLER_DOCKER_DESKTOP="${WORK}/no-such-Docker.app"; }
restore() { PATH="$REAL_PATH"; _OSTLER_DOCKER_DESKTOP="/Applications/Docker.app"; }

field() { sed -n "s/.*\"$2\": \"\\([^\"]*\\)\".*/\\1/p" "$1"; }
list()  { sed -n "s/.*\"$2\": \\[\\(.*\\)\\],*/\\1/p" "$1"; }

# ── CONTROL FIRST: the harness can actually see a runtime ─────────────────
# If stubbing does not work, every assertion below reports "absent" and the
# whole file passes for free. This is the uniform-zero trap in miniature.
isolate; stub colima
CTRL="$(ostler_engines_present)"
unstub colima; restore
if [[ "$CTRL" == "colima" ]]; then
    ok "CONTROL: a stubbed runtime IS detected (got '${CTRL}')"
else
    bad "CONTROL FAILED: stubbed colima not detected (got '${CTRL}')" \
        "the harness cannot see runtimes, so every case below is vacuous"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 1. CUSTOMER-OWNED: engine present before we touch anything ────────────
# The case Andy asked about: they brought their own. We must not claim it,
# and we must not have installed a second one.
D1="${WORK}/customer"; isolate; stub orbstack
ostler_engine_provenance_before "$D1"
ostler_engine_provenance_after  "$D1"
unstub orbstack; restore
if [[ "$(field "${D1}/container-engine.json" owner)" == "customer" ]]; then
    ok "a pre-existing engine is recorded as owner=customer"
else
    bad "pre-existing engine did not yield owner=customer" \
        "got '$(field "${D1}/container-engine.json" owner)'"
fi
if [[ -z "$(list "${D1}/container-engine.json" installed_by_ostler)" ]]; then
    ok "and we claim NOTHING as installed by us"
else
    bad "we claimed credit for a customer's own engine" \
        "installed_by_ostler = $(list "${D1}/container-engine.json" installed_by_ostler)"
fi

# ── 2. OSTLER-OWNED: nothing before, something after ──────────────────────
D2="${WORK}/ours"; isolate
ostler_engine_provenance_before "$D2"     # snapshot with NO engine
stub colima                                # ...then "we install" one
ostler_engine_provenance_after  "$D2"
unstub colima; restore
if [[ "$(field "${D2}/container-engine.json" owner)" == "ostler" ]]; then
    ok "an engine we added is recorded as owner=ostler"
else
    bad "engine added after the snapshot did not yield owner=ostler" \
        "got '$(field "${D2}/container-engine.json" owner)'"
fi
if [[ "$(list "${D2}/container-engine.json" installed_by_ostler)" == '"colima"' ]]; then
    ok "and it is named in installed_by_ostler, derived from the before/after diff"
else
    bad "the added engine was not derived into installed_by_ostler" \
        "got $(list "${D2}/container-engine.json" installed_by_ostler)"
fi

# ── 3. NO SNAPSHOT MUST YIELD unknown, NOT A GUESS ────────────────────────
# THE ASSERTION I MOST WANT TO HOLD. An upgrade over an install that predates
# this module has no `before` file. Guessing "ostler" there would make us
# apologise for a customer's own engine; guessing "customer" would let us
# disown one of ours. Both are worse than admitting the gap.
D3="${WORK}/nosnapshot"; mkdir -p "$D3"; isolate; stub podman
ostler_engine_provenance_after "$D3"       # deliberately NO before-snapshot
unstub podman; restore
if [[ "$(field "${D3}/container-engine.json" owner)" == "unknown" ]]; then
    ok "a missing snapshot yields owner=unknown rather than a guess"
else
    bad "a missing snapshot was guessed at" \
        "got '$(field "${D3}/container-engine.json" owner)' -- must be 'unknown'"
fi
if [[ -z "$(list "${D3}/container-engine.json" installed_by_ostler)" ]]; then
    ok "and with no snapshot we still claim nothing"
else
    bad "we claimed an install with no evidence for it" \
        "got $(list "${D3}/container-engine.json" installed_by_ostler)"
fi

# ── 4. THE CLIENT IS NEVER COUNTED AS AN ENGINE ───────────────────────────
# The exact confusion that produced the walk finding: /opt/homebrew/bin/docker
# is a CLIENT. A box with the client and no engine must read as no engine.
D4="${WORK}/clientonly"; isolate; stub docker
ostler_engine_provenance_before "$D4"
ostler_engine_provenance_after  "$D4"
unstub docker; restore
if [[ "$(field "${D4}/container-engine.json" owner)" == "none" ]]; then
    ok "the docker CLIENT alone is not an engine (owner=none)"
else
    bad "the client was counted as an engine" \
        "got '$(field "${D4}/container-engine.json" owner)' -- this is the walk defect"
fi
if [[ "$(field "${D4}/container-engine.json" client_docker)" == "present" ]]; then
    ok "...but the client IS recorded, because support needs to see that state"
else
    bad "the client was not recorded at all" \
        "client-present-engine-absent is the state that fooled the installer"
fi

# ── 5. ALL FOUR RUNTIMES MUST BE RECOGNISED ───────────────────────────────
# #994's guard knew colima and Docker Desktop only, so a box running OrbStack
# or Podman would have had Colima installed over a working engine. A record
# blind to the same two would repeat it one layer down.
for rt in colima orbstack podman; do
    isolate; stub "$rt"; got="$(ostler_engines_present)"; unstub "$rt"; restore
    if [[ "$got" == "$rt" ]]; then
        ok "runtime recognised: ${rt}"
    else
        bad "runtime NOT recognised: ${rt}" "ostler_engines_present returned '${got}'"
    fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
