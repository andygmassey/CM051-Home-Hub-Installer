#!/usr/bin/env bash
#
# test_store_auth_covers_every_interpreter.sh
#
# #595 / #210 -- THE FRONT PAGE COULD NEVER POPULATE ON ANY INSTALL, AND THE
# WIRING THAT SHOULD HAVE PREVENTED IT HAD 100% COVERAGE.
#
# Measured on .231 2026-08-31: 12 services under ~/.ostler/services, 9 with a
# .venv and 3 without -- cm059-editor, ical-server, ostler_hygiene. Twelve
# *auth*.pth files existed, one per venv. The wiring was not leaky; it was
# COMPLETE OVER THE WRONG POPULATION. It enumerates `.venv` directories, so a
# service without one is outside it BY CONSTRUCTION rather than by oversight.
#
# The editor's tick script bakes an ABSOLUTE PYTHON_BIN of
# <root>/python/bin/python3.11 and runs the BUNDLED interpreter directly. That
# interpreter had no ostler_store_auth.pth, so interest_profile.py reached
# Oxigraph with no credential, took a 401, fail-closed, emitted a
# settling-only feed -- and EXITED 0. launchd recorded success on all three
# ticks. The customer saw "Your Front Page is still settling in", forever.
#
# 📌 A GATE CAN HAVE FULL COVERAGE OF THE WRONG POPULATION. That is not a weak
# gate. It is a gate answering a different question, and it stays green
# through every instance.
#
# WHAT THIS TEST IS, AND IS NOT.
# It reads the SHIPPING installer and asserts the wiring reaches the bundled
# interpreter as well as the venvs -- the sibling of
# test_shipped_compose_licence_mount.sh, which exists because "a guard on the
# dev compose says nothing about the artefact".
#
# It is a STATIC check of the installer's source. It CANNOT see a service that
# arrives on a box after install.sh has run. That limb needs a RUNTIME
# enumeration on the box, and it has a hard constraint measured by Archie
# 2026-08-31: service directory ctimes show cm052 arriving TWENTY-NINE MINUTES
# after the main provisioning block finished (cm059-editor 22:16:18, cm052
# 22:45:15). A runtime gate placed where services are "obviously" provisioned
# would enumerate 11 of 12 and PASS -- reproducing this very defect inside its
# own fix. That gate must run at the TRUE end of install and carry its own
# floor. It is NOT in this file and is NOT claimed by it.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN, not a pass" >&2; exit 1; }

# ── Control FIRST, before any count is trusted. ──────────────────────
# Every assertion below counts occurrences in install.sh. If the wiring
# function is absent entirely, all of them report a confident zero for a
# reason unrelated to #595. Establish the denominator before reading it.
fn_defs="$(grep -cE '^_ostler_wire_store_auth_pth\(\)' "$INSTALL_SH")"
if [ "$fn_defs" -lt 1 ]; then
    echo "FAIL: _ostler_wire_store_auth_pth is not defined in install.sh --" >&2
    echo "      this test's subject is absent, so its zeros mean nothing." >&2
    echo "      CANNOT-RUN, not a pass." >&2
    exit 1
fi
pass "control: the wiring function is defined (${fn_defs} definition)"

# ── 1. THE FLOOR. ────────────────────────────────────────────────────
# 14 call sites existed before this fix and the 15th is the bundled
# interpreter. A floor, not an equality: adding a venv is normal and must not
# red the build. REMOVING coverage is the regression this catches.
#
# Why a floor at all: a gate that enumerates "whatever it finds" cannot tell a
# complete population from a truncated one. The number is what makes a
# shrinking denominator visible instead of silent -- the same reason the
# `-m venv` control of 20 made the --system-site-packages zero trustworthy.
CALL_FLOOR=15
call_sites="$(grep -cE '_ostler_wire_store_auth_pth "' "$INSTALL_SH")"
if [ "$call_sites" -ge "$CALL_FLOOR" ]; then
    pass "store-auth wiring call sites: ${call_sites} (floor ${CALL_FLOOR})"
else
    failure "store-auth wiring call sites fell to ${call_sites}, below the floor of \
${CALL_FLOOR}. Something that used to reach the data stores with a credential \
no longer does, and the failure is SILENT at runtime: an unwired interpreter \
takes a 401, fail-closes, and exits 0 (#595)."
fi

# ── 2. THE BUNDLED INTERPRETER IS WIRED. ─────────────────────────────
# The specific gap. Asserted separately from the floor so that deleting THIS
# call fails with a message about the Front Page, not about arithmetic.
if grep -qE '_ostler_wire_store_auth_pth "\$PYTHON3_BIN"' "$INSTALL_SH"; then
    pass "the BUNDLED interpreter (\$PYTHON3_BIN) is wired, not just the venvs"
else
    failure "no wiring call for \$PYTHON3_BIN. The bundled interpreter is what \
every service WITHOUT its own venv runs -- cm059-editor, ical-server and \
ostler_hygiene as measured on .231. Without this the Front Page can never \
populate on any install (#595/#210)."
fi

# ── 3. THE FUNCTION CAN ACCEPT A NON-VENV INTERPRETER. ───────────────
# The call in (2) is useless without this. The relocated tree ships
# bin/python3.11 and NO bin/python3 -- measured on install.sh: 6 occurrences
# of `python/bin/python3.11`, ZERO of `python/bin/python3` exact, and zero
# `ln -s` creating an alias. Against the old venv-only guard the call would
# fail `-x`, hit its `|| warn`, and land back in the same silence: present,
# green, and inert.
if grep -qE 'bin/python3\.11"\s*\]\]' "$INSTALL_SH"; then
    pass "the wiring function accepts a relocated interpreter (bin/python3.11 arm)"
else
    failure "_ostler_wire_store_auth_pth has no bin/python3.11 arm. The bundled \
tree ships no bin/python3, so the call in (2) would fail its guard and warn \
into exactly the silence this fixes -- a call site that exists and does nothing."
fi

# ── 4. THE FUNCTION MUST NOT REGRESS TO THE HARDCODED PATH. ──────────
# If anyone reinstates `"${_venv}/bin/python3" -c ...` in the body, the three
# accepted shapes collapse back to one and (3) becomes decorative.
hardcoded="$(grep -cE '"\$\{_venv\}/bin/python3" -c' "$INSTALL_SH")"
if [ "$hardcoded" -eq 0 ]; then
    pass "the function interrogates the RESOLVED interpreter, not a hardcoded path"
else
    failure "the wiring function still calls \"\${_venv}/bin/python3\" directly \
(${hardcoded} site(s)). That reintroduces the venv-only assumption underneath \
the resolution, so a relocated interpreter resolves and is then never asked \
where its site-packages are."
fi

# ── 5. SCOPE HONESTY: the blind spot is NAMED, not silently covered. ─
# ical-server and ostler_hygiene are in the same population as cm059-editor
# and NOBODY HAS MEASURED what they do without a store credential. This fix
# gives them one; it does not prove they were broken or that they are now
# correct. If that sentence ever leaves the installer, the next reader will
# assume the question was answered.
if grep -qE 'ical-server, ostler_hygiene|ical-server and ostler_hygiene' "$INSTALL_SH"; then
    pass "the un-measured siblings are named in the installer, not silently implied covered"
else
    failure "install.sh no longer names ical-server / ostler_hygiene as the other \
members of this population. They were never measured without a credential; \
dropping the note turns an open question into an assumed answer."
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$FAILED"
