#!/usr/bin/env bash
# ============================================================================
# test_dedupe_deps_reach_the_consumer_venv.sh -- the venv that INSTALLS the
# dedupe dependencies is not the venv that IMPORTS them.            (#1137)
# ============================================================================
#
# THE DEFECT, measured on .228 on 2026-08-27 with the SAME PYTHONPATH on both
# interpreters:
#
#     ~/.ostler/import-pipeline/.venv   identity_resolver.resolver -> OK
#     ~/.ostler/.venv                   identity_resolver.resolver ->
#                                       ModuleNotFoundError: No module named 'rapidfuzz'
#
# pip list in the pipeline venv: qdrant-client 1.19.0, RapidFuzz 3.14.5. Both
# present. The service venv had neither. And the service venv is the one that
# runs the consumer:
#
#     pid 52627 -> $HOME/.ostler/.venv/bin/python3 .../ical-server.py
#
# which imports the layer IN-PROCESS -- ical-server.py:535 imports
# identity_resolver.compartment at module level, :5381 wraps
# identity_resolver.tidy.TidyEngine, dispatched at :6920.
#
# WHY IT HID. Both interpreters get import-pipeline on PYTHONPATH, so the CODE
# resolves in both and only the DEPENDENCIES are missing. identity_resolver is
# on disk, importable, in exactly the right place. compartment is stdlib-only
# so it imports fine; tidy needs rapidfuzz and fails at CALL time behind
# try/except into degraded:true. The service starts clean and nothing reports
# a fault.
#
# #1115 fixed WHICH requirements files get installed. It did not change WHERE
# they go, so it does not cover this and a post-#1115 install still ships the
# layer dark.
#
# WHAT THIS TEST PROTECTS. Not the presence of a fix -- the SHAPE of it. The
# tempting "simplification" is to name rapidfuzz and qdrant-client directly in
# install.sh. That list drifts from the requirements files the moment either
# moves, and a declaration that has drifted from its installation is this same
# bug in different clothes. So (3) asserts the consumer install is driven by
# PIPELINE_REQS, and (4) asserts nobody has hardcoded the package names.
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL="${REPO_ROOT}/install.sh"

PASS=0
FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$INSTALL" ]]; then
    printf '  [FAIL] install.sh not found at %s -- this test could not run, which is not a pass\n' "$INSTALL"
    exit 1
fi

# ---------------------------------------------------------------------------
# (0) CONTROL. The predicate must be able to find something that is certainly
#     there. Every absence below is worthless if the file is not being read.
# ---------------------------------------------------------------------------
if grep -q 'PIPELINE_REQS=""' "$INSTALL"; then
    pass "(0) CONTROL: install.sh is readable and PIPELINE_REQS is present, so an absence below means absent"
else
    failure "(0) CONTROL FAILED: cannot find PIPELINE_REQS in install.sh. Nothing below can be trusted"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
fi

# ---------------------------------------------------------------------------
# (1) The consumer venv must receive an install at all.
# ---------------------------------------------------------------------------
CONSUMER_PIP="$(grep -c '"${OSTLER_VENV}/bin/pip" install' "$INSTALL" || true)"
if [[ "${CONSUMER_PIP:-0}" -ge 1 ]]; then
    pass "(1) install.sh pip-installs into OSTLER_VENV, the venv the consumer runs under"
else
    failure "(1) nothing installs into OSTLER_VENV. The dedupe layer imports in-process there and will be dark (#1137)"
fi

# ---------------------------------------------------------------------------
# (2) It must be reached on the ordinary path, not only behind an escape hatch.
# ---------------------------------------------------------------------------
if grep -q 'into OSTLER_VENV, the consumer' "$INSTALL"; then
    pass "(2) the consumer install logs itself, so an operator reading the pip log can see it ran"
else
    failure "(2) the consumer install leaves no trace in PIPELINE_PIP_LOG -- a silent step cannot be audited after a bad install"
fi

# ---------------------------------------------------------------------------
# (3) THE SHAPE THAT MATTERS. Driven by PIPELINE_REQS, the same declaration the
#     pipeline venv uses. One declaration, two installations.
# ---------------------------------------------------------------------------
# `cmd | grep -q` in a CONDITION under `set -o pipefail` INVERTS: grep -q exits
# on first match, the upstream grep takes SIGPIPE, and pipefail reports the
# whole pipeline as failed -- on a match. tests/test_pipefail_shortcircuit_
# inversion.sh ratchets against exactly this and caught it here. Remedy B:
# count in a substitution, compare the number.
REQS_DRIVEN="$(grep -B6 -A4 '"${OSTLER_VENV}/bin/pip" install' "$INSTALL" | grep -c 'PIPELINE_REQS' || true)"
if [[ "${REQS_DRIVEN:-0}" -ge 1 ]]; then
    pass "(3) the consumer install is driven by PIPELINE_REQS, so it cannot drift from the requirements files"
else
    failure "(3) the consumer install is NOT driven by PIPELINE_REQS. A separate list drifts the moment either side moves"
fi

# ---------------------------------------------------------------------------
# (4) NEGATIVE. The package names must not be hardcoded at the install site.
#     Naming them here is the drift this whole defect is made of.
# ---------------------------------------------------------------------------
HARDCODED="$(grep -n 'pip" install' "$INSTALL" | grep -ciE 'rapidfuzz|qdrant[-_]client' || true)"
if [[ "${HARDCODED:-0}" -eq 0 ]]; then
    pass "(4) no pip install line names rapidfuzz or qdrant-client directly -- the requirements files stay the single declaration"
else
    failure "(4) ${HARDCODED} pip install line(s) hardcode a package name. That list will drift from the requirements files (#1137)"
fi

# ---------------------------------------------------------------------------
# (5) A failure installing into the consumer venv must be as loud as a failure
#     installing into the pipeline venv. Shipping the layer dark silently is
#     the entire defect; a fix that fails quietly reproduces it.
# ---------------------------------------------------------------------------
EXIT_WIRED="$(grep -A8 '"${OSTLER_VENV}/bin/pip" install' "$INSTALL" | grep -c 'PIPELINE_PIP_EXIT=' || true)"
if [[ "${EXIT_WIRED:-0}" -ge 1 ]]; then
    pass "(5) a consumer-venv pip failure sets PIPELINE_PIP_EXIT, so it reaches the same warn-and-fail path"
else
    failure "(5) a consumer-venv pip failure is swallowed. The layer would ship dark exactly as it does today"
fi

# ---------------------------------------------------------------------------
# (6) An absent consumer venv must be RECORDED, not skipped in silence.
#     "Could not" and "did not need to" print identically otherwise.
# ---------------------------------------------------------------------------
if grep -q 'SKIPPED: %s/bin/pip absent' "$INSTALL"; then
    pass "(6) an absent consumer venv is written to the pip log rather than passed over in silence"
else
    failure "(6) if OSTLER_VENV/bin/pip is absent the step vanishes with no record -- an absence reading as a success"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
