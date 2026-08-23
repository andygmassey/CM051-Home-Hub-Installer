#!/usr/bin/env bash
#
# test_container_runtime_precondition.sh
#
# THE DEFECT THIS PINS, MEASURED 2026-08-23 ON REAL HARDWARE
# ---------------------------------------------------------
# v1.0.38 walk, Mac mini. The install reported SUCCESS on a machine
# with no container runtime at all:
#
#     /opt/homebrew/bin/docker    EXISTS     <-- the CLI. A client only.
#     colima                      ABSENT
#     /Applications/Docker.app    ABSENT
#     podman / OrbStack           ABSENT
#     :8044 wiki                  000
#     :7878 Oxigraph              000
#     CONTROL  :8000 daemon 200 / :8089 ical 302   <-- native launchd, alive
#
# The zero is RAGGED and falls on an architectural line: the dead ports are
# exactly the Docker-hosted services, the live ones exactly the native
# launchd services. That is what makes it a measurement.
#
# ROOT CAUSE. install.sh gated the Colima install on the CLIENT:
#
#     if ! command -v docker &>/dev/null; then      # <-- WRONG QUESTION
#         brew install colima docker docker-compose
#
# On macOS `docker` is a client; the engine is a separate program. Any box
# that already had Homebrew's `docker` formula skipped the Colima install,
# then fell through the `command -v colima` arm (absent) and the Docker
# Desktop arm (absent). `ostler-wiki-site` and `ostler-wiki-compiler` are
# pinned BY DIGEST and cannot start without an engine.
#
# WHAT THIS GATE DOES THAT A GREP CANNOT
# --------------------------------------
# Controls 1-3 EXTRACT the real §3.2a post-condition block out of install.sh
# and EXECUTE it against stub binaries, so the test cannot pass against a
# copy of the logic or against a block that was deleted. Each control has a
# partner on the other side: the same block must PASS when an engine answers
# and FAIL when it does not, which is the only way "it failed" means the
# predicate works rather than the harness being broken.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_SH="${REPO_ROOT}/install.sh.strings.en-GB.sh"

PASS=0
FAIL=0
cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  Nothing was checked. This is not a passing gate." >&2
    exit 2
}
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at ${INSTALL_SH}"
[[ -f "$STRINGS_SH" ]] || cannot_run "strings catalogue not found at ${STRINGS_SH}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-runtime-gate.XXXXXX")" || cannot_run "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

# Comments are not code. Every shape assertion below runs against this.
CODE="${WORK}/install.code.sh"
sed 's/#.*//' "$INSTALL_SH" > "$CODE"

# ── extract the §3.2a post-condition block ──────────────────────────
#
# 🔴 THE TERMINATOR USED TO BE A NAME, AND A NAME IS NOT A BOUNDARY.
#
# It read `/^# ── 3\.2b Remove any stale/{f=0}`. When §3.2a-sup (the engine
# supervisor) was inserted BETWEEN 3.2a and 3.2b, the window silently grew to
# swallow it, the harness ran a block referencing $OSTLER_DIR that the harness
# never sets, and the CONTROL failed:
#
#     [FAIL] CONTROL BROKEN: the post-condition FAILED even with a working
#            engine. Every failure below would be meaningless.
#     runner-engine-ok.sh: line 86: OSTLER_DIR: unbound variable
#
# The control did its job -- it refused to let 24 passes be read as a
# measurement. But the defect it caught was in the test, not the product, and
# a name-pinned terminator will do this again to whoever inserts the next
# section. So the boundary is now STRUCTURAL: a section ends where the next
# section begins, whatever that section is called.
BLOCK="${WORK}/block.sh"
awk '/^# ── 3\.2a POST-CONDITION/{f=1; print; next} /^# ── /{f=0} f' \
    "$INSTALL_SH" > "$BLOCK"
[[ -s "$BLOCK" ]] || cannot_run "could not extract the 3.2a post-condition block from install.sh -- either it was removed or its anchors changed"
grep -q 'docker info' "$BLOCK" || cannot_run "the extracted 3.2a block contains no 'docker info' probe; extraction is wrong or the block is not the one under test"

# And ASSERT the bound rather than trusting it. Exactly one section header --
# its own -- may appear in the extracted block. This is the assertion that
# would have caught the widening at the moment it happened instead of via a
# downstream unbound-variable error, and it is spelled without naming any
# neighbouring section, so it cannot rot the same way.
BLOCK_HEADERS="$(grep -c '^# ── ' "$BLOCK" || true)"
if [[ "${BLOCK_HEADERS:-0}" -ne 1 ]]; then
    cannot_run "the extracted block spans ${BLOCK_HEADERS} section headers, not 1 -- the extraction window has widened past §3.2a and nothing below would be measuring the post-condition alone"
fi

# ── harness: run the real block against stub binaries ────────────────
# Returns the block's exit status and writes its output to $WORK/out.
run_block() {
    local mode="$1"          # engine-ok | client-only | no-client
    local stubs="${WORK}/stubs-${mode}"
    rm -rf "$stubs"; mkdir -p "$stubs"

    if [[ "$mode" != "no-client" ]]; then
        cat > "${stubs}/docker" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "info" ]]; then
    if [[ "${STUB_ENGINE_UP:-0}" == "1" ]]; then
        echo "Server Version: 27.0.0"
        exit 0
    fi
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
    exit 1
fi
exit 0
STUB
        chmod +x "${stubs}/docker"
    fi

    local runner="${WORK}/runner-${mode}.sh"
    {
        echo 'set -Eeuo pipefail'
        # Stubs for the install.sh helpers the block calls. fail_with_code
        # records its CODE and exits 1, exactly as the real one does.
        echo 'progress() { :; }'
        echo 'info() { echo "[info] $*"; }'
        echo 'warn() { echo "[warn] $*"; }'
        echo 'ok()   { echo "[ok] $*"; }'
        echo 'fail_with_code() { echo "[fail] CODE=$1"; shift; echo "[fail] $*"; exit 1; }'
        echo 'INSTALL_LOG="/tmp/ostler-test.log"'
        # The real catalogue, so a missing MSG_* is caught here too.
        echo "source '${STRINGS_SH}'"
        cat "$BLOCK"
    } > "$runner"

    PATH="${stubs}:/usr/bin:/bin:/usr/sbin:/sbin" \
        STUB_ENGINE_UP="$([[ "$mode" == "engine-ok" ]] && echo 1 || echo 0)" \
        bash "$runner" >"${WORK}/out" 2>&1
    return $?
}

# ── CONTROL 1: an answering engine must PASS ────────────────────────
# The partner to controls 2 and 3. Without it, a block that failed on
# everything would look like a working guard.
if run_block engine-ok; then
    if grep -q '^\[ok\]' "${WORK}/out"; then
        pass "control: the post-condition PASSES when an engine answers ($(grep -m1 '^\[ok\]' "${WORK}/out"))"
    else
        failure "the post-condition exited 0 with an engine present but printed no ok line: $(cat "${WORK}/out")"
    fi
else
    failure "CONTROL BROKEN: the post-condition FAILED even with a working engine. Every failure below would be meaningless. Output: $(cat "${WORK}/out")"
fi

# ── CONTROL 2: THE MEASURED STATE. Client present, no engine. ───────
if run_block client-only; then
    failure "THE DEFECT IS BACK: docker client present, 'docker info' failing, and the post-condition returned SUCCESS. That is exactly the Mac mini's state on 2026-08-23. Output: $(cat "${WORK}/out")"
else
    if grep -q 'CODE=ERR-06-CONTAINER-ENGINE-ABSENT' "${WORK}/out"; then
        pass "client-without-engine fails with ERR-06-CONTAINER-ENGINE-ABSENT -- the exact measured state now stops the install"
    else
        failure "client-without-engine failed, but not with ERR-06-CONTAINER-ENGINE-ABSENT: $(cat "${WORK}/out")"
    fi
fi

# ── CONTROL 3: no client at all is a DIFFERENT, named failure ───────
if run_block no-client; then
    failure "no docker client at all and the post-condition still returned success"
else
    if grep -q 'CODE=ERR-06-CONTAINER-CLIENT-MISSING' "${WORK}/out"; then
        pass "a missing client fails with its own code, distinct from a missing engine"
    else
        failure "missing client did not produce ERR-06-CONTAINER-CLIENT-MISSING: $(cat "${WORK}/out")"
    fi
fi

# ── 4. the Colima install must not be gated on the CLIENT ───────────
#
# SCOPED DELIBERATELY. `if ! command -v docker` is CORRECT where its body
# is a fail_with_code -- there are two such post-conditions and they must
# stay. It is wrong only where its body INSTALLS the engine, because there
# it asks about the client to decide about the engine. So the predicate is
# scoped to the guard that actually reaches `brew install colima`.
INSTALL_LINE="$(grep -n 'brew install colima' "$CODE" | head -1 | cut -d: -f1)"
if [[ -z "${INSTALL_LINE:-}" ]]; then
    failure "no 'brew install colima' in install.sh -- the engine is never installed at all"
else
    GUARD_FROM=$(( INSTALL_LINE > 6 ? INSTALL_LINE - 6 : 1 ))
    GUARD="$(sed -n "${GUARD_FROM},${INSTALL_LINE}p" "$CODE")"
    if grep -q 'command -v docker' <<<"$GUARD"; then
        failure "the brew-install-colima branch is still guarded by 'command -v docker' -- that tests for the CLIENT to decide about the ENGINE, which is the root cause of the 2026-08-23 finding"
    else
        pass "the brew-install-colima branch is not guarded by the presence of the docker CLIENT"
    fi
    if grep -q 'command -v colima' <<<"$GUARD"; then
        pass "the Colima install is reached from a Colima-shaped condition"
    else
        failure "the guard on brew install colima no longer mentions colima: ${GUARD}"
    fi
fi
# The two legitimate client post-conditions must SURVIVE. Removing them to
# make check 4 green would trade one silent failure for another.
# Counted into a variable rather than piped into a condition: a
# `producer | grep -q` under pipefail inverts on EPIPE. See
# tests/test_pipefail_shortcircuit_inversion.sh.
CLIENT_CHECKS="$(grep -c 'command -v docker' "$CODE" || true)"
if (( ${CLIENT_CHECKS:-0} > 0 )); then
    pass "client-presence checks still exist (${CLIENT_CHECKS}) where their body is a refusal"
else
    failure "every 'command -v docker' check was removed; a missing client would now go unnoticed"
fi

# ── 5. Phase 1 must tell the client and the engine apart ────────────
for var in HAS_DOCKER_CLIENT HAS_CONTAINER_ENGINE; do
    if grep -q "${var}=" "$CODE"; then
        pass "Phase 1 records ${var}"
    else
        failure "Phase 1 does not record ${var}; client and engine are conflated again"
    fi
done

# ── 6. the post-condition must sit OUTSIDE the HAS_DOCKER branch ────
# A floor inside one arm of the ladder is not a floor. Measured by line
# number against the `fi` that closes the 3.2 block.
POSTCOND_LINE="$(grep -n '^# ── 3.2a POST-CONDITION' "$INSTALL_SH" | head -1 | cut -d: -f1)"
DOCKER_SECTION_LINE="$(grep -n '^# ── 3.2 Docker' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "${POSTCOND_LINE:-}" && -n "${DOCKER_SECTION_LINE:-}" ]] && (( POSTCOND_LINE > DOCKER_SECTION_LINE )); then
    pass "the post-condition (line ${POSTCOND_LINE}) follows the whole §3.2 ladder (line ${DOCKER_SECTION_LINE})"
else
    failure "could not establish that the post-condition follows §3.2 (postcond=${POSTCOND_LINE:-none} section=${DOCKER_SECTION_LINE:-none})"
fi

# ── 7. Phase 4 must probe :8044 ─────────────────────────────────────
if grep -q '127.0.0.1:8044' "$CODE"; then
    pass "install.sh probes 127.0.0.1:8044"
else
    failure "nothing in install.sh probes :8044 -- the one URL the customer is told to open is the one nothing checks"
fi
if grep -q 'MSG_WARN_WIKI_NOT_RESPONDING' "$CODE"; then
    pass "a dead wiki has its own health-check warning"
else
    failure "no wiki health-check warning string is referenced"
fi

# ── 8. the wiki 'running' claim must rest on a probe ────────────────
# INSTRUMENT AND DEFECT ON THE SAME SURFACE: the claim names a URL, so the
# evidence must be that URL and not the exit code of `docker compose up -d`.
WIKI_CLAIM_CONTEXT="$(grep -B4 'MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044' "$CODE" || true)"
if grep -q 'WIKI_PORT_UP' <<<"$WIKI_CLAIM_CONTEXT"; then
    pass "the 'wiki running at :8044' line is printed only when :8044 answered"
else
    failure "MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044 is not guarded by a port probe -- 'docker compose up -d' exiting 0 is not evidence that the page loads"
fi

# ── 9. Phase 4 must not erase earlier verdicts ──────────────────────
# #839's zero-pages HEALTHY=false, and the new :8044 one, both sit ABOVE
# Phase 4. A bare `HEALTHY=true` there overwrote them unconditionally.
if grep -Eq '^HEALTHY=true$' "$CODE"; then
    failure "Phase 4 re-initialises HEALTHY=true, erasing every verdict recorded before it (the zero-pages check among them)"
else
    pass "Phase 4 does not re-initialise HEALTHY, so earlier verdicts survive to the summary"
fi
if grep -q 'HEALTHY:=true' "$CODE"; then
    pass "HEALTHY is initialised only when unset"
else
    failure "HEALTHY has no initialiser at all; under set -u the health check would abort"
fi

# ── 10. the new codes are catalogued and correctly shaped ───────────
for code_id in ERR-06-CONTAINER-ENGINE-ABSENT ERR-06-CONTAINER-CLIENT-MISSING; do
    if grep -q "$code_id" "$CODE"; then
        pass "${code_id} is referenced in install.sh"
    else
        failure "${code_id} is not referenced in install.sh"
    fi
done
for key in MSG_FAIL_CONTAINER_ENGINE_ABSENT MSG_FAIL_CONTAINER_CLIENT_MISSING \
           MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE MSG_OK_CONTAINER_ENGINE_ANSWERED \
           MSG_OK_WIKI_HEALTHY MSG_WARN_WIKI_NOT_RESPONDING MSG_WARN_WIKI_PORT_NOT_ANSWERING; do
    if grep -q "^${key}=" "$STRINGS_SH"; then
        pass "${key} is in the en-GB catalogue"
    else
        failure "${key} is referenced but not defined in ${STRINGS_SH}"
    fi
done

# ── 11. anti-vacuity for the comment stripping ──────────────────────
# The header of THIS file quotes `if ! command -v docker`. Prove the
# stripped-code predicate would still fire on real code, so check 4's
# absence is a measurement and not a stripping artefact.
DOCTORED="${WORK}/doctored.sh"
printf 'if ! command -v docker &>/dev/null; then\n    brew install colima docker docker-compose\nfi\n' > "$DOCTORED"
D_LINE="$(grep -n 'brew install colima' "$DOCTORED" | head -1 | cut -d: -f1)"
D_FROM=$(( D_LINE > 6 ? D_LINE - 6 : 1 ))
D_GUARD="$(sed -n "${D_FROM},${D_LINE}p" "$DOCTORED")"
if grep -q 'command -v docker' <<<"$D_GUARD"; then
    pass "anti-vacuity: the root-cause predicate fires on a doctored file carrying the exact pre-fix guard, so its absence in install.sh is a measurement"
else
    failure "anti-vacuity: the root-cause predicate does not fire on a file that reproduces the defect -- check 4 proves nothing"
fi
COMMENTED="${WORK}/commented.sh"
printf '# if ! command -v docker &>/dev/null; then\n' > "$COMMENTED"
sed 's/#.*//' "$COMMENTED" > "${COMMENTED}.code"
if grep -Eq 'if ! command -v docker' "${COMMENTED}.code"; then
    failure "anti-vacuity: comment stripping does not work, so a commented-out line would trip check 4"
else
    pass "anti-vacuity: comment stripping removes a commented instance, so check 4 reads code only"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
