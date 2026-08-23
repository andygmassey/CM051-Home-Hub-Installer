#!/usr/bin/env bash
#
# ostler-container-engine.sh -- classify the container runtime into FOUR states.
#
# ══════════════════════════════════════════════════════════════════════
# WHY FOUR STATES, MEASURED ON THE WALK BOX 2026-08-23
# ══════════════════════════════════════════════════════════════════════
#
# Andrews-Mac-mini, live, while this was written:
#
#     /opt/homebrew/bin/colima        PRESENT
#     /opt/homebrew/bin/docker        PRESENT
#     /opt/homebrew/bin/limactl       PRESENT
#     /Applications/Docker.app        ABSENT
#     pgrep -f 'limactl|qemu'         0 processes
#     docker info                     rc=1, socket does not exist
#     colima status                   "colima is not running"
#     :8044 -> 000   :7878 -> 000     (docker-hosted)
#     :8000 -> 200   :8089 -> 302     (native launchd -- the CONTROL)
#
# The engine was INSTALLED AND STOPPED. Jetsam killed the Colima VM after
# the installer's unbounded output buffer took the machine to 4.27 GB and
# macOS ran out of application memory (eight JetsamEvent reports on the box,
# 16:10 to 17:33 on 2026-08-23). No reboot was involved; uptime was 2 days.
#
# THAT IS WHY "IS A RUNTIME INSTALLED" IS THE WRONG QUESTION. It returns
# HEALTHY on that box while the wiki is dark. Three of the four states below
# look identical to a naive probe, and the one that bit us is the one in the
# middle.
#
#     absent              nothing is installed. Needs an INSTALL.
#     installed_stopped   installed, no engine answering. Needs a START.
#                         <-- the measured state, and the recoverable one
#     running_no_wiki     engine answers, the wiki container is not up.
#                         Needs a CONTAINER start, not an engine start.
#     up                  engine answers and the wiki container is running.
#
# The distinction is not academic: the repair differs in every case, and a
# fix command that cannot work is worse than none because the customer runs
# it, watches it fail, and stops trusting the page that offered it.
#
# ══════════════════════════════════════════════════════════════════════
# USE
# ══════════════════════════════════════════════════════════════════════
#
#   source lib/ostler-container-engine.sh   -> ostler_engine_state, and
#                                              OSTLER_ENGINE_* variables
#   bash   lib/ostler-container-engine.sh   -> prints the state, exits:
#
#     0  up
#     1  absent | installed_stopped | running_no_wiki   (a real fault)
#     2  CANNOT-RUN -- could not determine (no PATH to a docker client at
#        all, so the question was never asked). NEVER reported as healthy.
#
# READ-ONLY. It starts nothing and changes nothing, so it is safe to run
# against a box being preserved as a fixture.

# Homebrew is not on a launchd agent's PATH. Every probe below resolves
# absolute paths first for exactly that reason: an earlier diagnosis of this
# same box reported "no container engine installed" because it was measured
# in a shell without /opt/homebrew/bin, and everything was installed.
OSTLER_ENGINE_BREW_PREFIX="${OSTLER_ENGINE_BREW_PREFIX:-/opt/homebrew}"
# Intel Homebrew / Docker Desktop's symlink target. Overridable for the same
# reason as the prefix above: the test matrix has to be able to construct an
# "absent" box on a developer Mac that really does have Docker Desktop.
OSTLER_ENGINE_ALT_PREFIX="${OSTLER_ENGINE_ALT_PREFIX:-/usr/local}"
OSTLER_ENGINE_DESKTOP_PATH="${OSTLER_ENGINE_DESKTOP_PATH:-/Applications/Docker.app}"

_ostler_engine_which() {
    # $1 = binary name. Prints an absolute path or nothing.
    local name="$1" p
    for p in "${OSTLER_ENGINE_BREW_PREFIX}/bin/${name}" "${OSTLER_ENGINE_ALT_PREFIX}/bin/${name}"; do
        [ -x "$p" ] && { printf '%s' "$p"; return 0; }
    done
    # Last resort. Suppressible, and the tests suppress it: a CI runner with
    # a real /usr/bin/docker on PATH would otherwise make the "absent" case
    # of the four-state matrix impossible to construct, and the matrix would
    # lose a state silently. Production leaves it on.
    [ "${OSTLER_ENGINE_ALLOW_PATH_LOOKUP:-1}" = "1" ] || return 0
    command -v "$name" 2>/dev/null || true
}

# Classify. Sets:
#   OSTLER_ENGINE_STATE      absent | installed_stopped | running_no_wiki | up
#   OSTLER_ENGINE_DOCKER     path to the docker CLI, or empty
#   OSTLER_ENGINE_COLIMA     path to colima, or empty
#   OSTLER_ENGINE_DESKTOP    yes | no
#   OSTLER_ENGINE_DETAIL     one line of evidence for the state
# Returns the exit code documented above.
ostler_engine_state() {
    OSTLER_ENGINE_DOCKER="$(_ostler_engine_which docker)"
    OSTLER_ENGINE_COLIMA="$(_ostler_engine_which colima)"
    OSTLER_ENGINE_DESKTOP=no
    [ -d "$OSTLER_ENGINE_DESKTOP_PATH" ] && OSTLER_ENGINE_DESKTOP=yes

    # No client at all: the question cannot be asked. CANNOT-RUN, not a
    # verdict about the engine -- those are different findings and only one
    # of them is actionable.
    if [ -z "$OSTLER_ENGINE_DOCKER" ]; then
        if [ -z "$OSTLER_ENGINE_COLIMA" ] && [ "$OSTLER_ENGINE_DESKTOP" = no ]; then
            OSTLER_ENGINE_STATE="absent"
            OSTLER_ENGINE_DETAIL="no docker client, no colima, no Docker Desktop"
            return 1
        fi
        OSTLER_ENGINE_STATE="unknown"
        OSTLER_ENGINE_DETAIL="an engine is installed but the docker client is not on PATH, so it could not be queried"
        return 2
    fi

    # THE ONLY QUESTION THAT SEPARATES A CLIENT FROM A RUNTIME. On macOS
    # `docker` is a client; `docker info` is the round trip to an engine.
    local info_err
    if ! info_err="$("$OSTLER_ENGINE_DOCKER" info 2>&1 >/dev/null)"; then
        if [ -n "$OSTLER_ENGINE_COLIMA" ] || [ "$OSTLER_ENGINE_DESKTOP" = yes ]; then
            OSTLER_ENGINE_STATE="installed_stopped"
            OSTLER_ENGINE_DETAIL="${info_err%%$'\n'*}"
            return 1
        fi
        OSTLER_ENGINE_STATE="absent"
        OSTLER_ENGINE_DETAIL="docker client present, no engine installed behind it"
        return 1
    fi

    # Engine answers. Is the wiki actually up? An engine that runs and a
    # wiki that does not is a third, different repair.
    local wiki_state
    wiki_state="$("$OSTLER_ENGINE_DOCKER" ps -a --filter 'name=wiki-site' --format '{{.State}}' 2>/dev/null | head -1)"
    if [ "$wiki_state" = "running" ]; then
        OSTLER_ENGINE_STATE="up"
        OSTLER_ENGINE_DETAIL="engine answering, wiki container running"
        return 0
    fi
    OSTLER_ENGINE_STATE="running_no_wiki"
    OSTLER_ENGINE_DETAIL="engine answering, wiki container is '${wiki_state:-not present}'"
    return 1
}

# Standalone invocation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ostler_engine_state
    _rc=$?
    printf 'state=%s\n' "$OSTLER_ENGINE_STATE"
    printf 'detail=%s\n' "$OSTLER_ENGINE_DETAIL"
    printf 'docker=%s\n' "${OSTLER_ENGINE_DOCKER:-none}"
    printf 'colima=%s\n' "${OSTLER_ENGINE_COLIMA:-none}"
    printf 'docker_desktop=%s\n' "$OSTLER_ENGINE_DESKTOP"
    exit "$_rc"
fi
