#!/usr/bin/env bash
#
# THE INSTALLER MUST INSTALL THE DOCKER CLI, NOT ASSUME IT FROM COLIMA.
# =====================================================================
#
# THE DEFECT (measured 2026-11-14, fresh macOS account, Homebrew has colima
# but no docker CLI). install.sh set ENGINE_PRESENT=true as soon as `colima`
# was on PATH, then skipped `brew install colima docker docker-compose`.
# `colima start` died with "dependency check failed for docker: docker not
# found", and its stderr went to /dev/null, so the install sat on "Starting
# Docker" for 314 s and aborted with the generic ERR-99 code.
#
# THE FIX. The brew install is gated on ENGINE_PRESENT *or* on DOCKER_CLI_PRESENT
# being false (the docker CLI and a compose provider both on PATH). colima start
# stderr is appended to INSTALL_LOG, and the failure message names colima's last
# FATA line.
#
# HOW THIS TEST RUNS THE REAL CODE. It extracts the live slice of install.sh
# from the `ENGINE_PRESENT=false` line through the colima `if` block, and runs
# that slice under /bin/bash with a stub PATH holding stub colima, docker,
# docker-compose, brew and sleep. No real binary is reachable.
#
# Hermeticity: /Applications/Docker.app, /opt/homebrew/bin/brew and the
# homebrew cli-plugins path are rewritten to paths inside the stub directory,
# so a real Docker or Homebrew on the host cannot answer for the stubs. This is
# the one divergence from production, applied identically to every arm,
# including the red run on main.
#
# USAGE
#   tests/test_docker_cli_presence_gates_the_colima_install.sh [install.sh]
#   The optional argument runs the same arms against another install.sh. That
#   is how the red-on-main evidence is produced (pass a `git show origin/main:`
#   copy).
#
# CANNOT-RUN is not a pass: an unreadable file or a slice boundary that cannot
# be found exits 2 and says so.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${1:-${REPO_ROOT}/install.sh}"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo
echo "== the docker CLI is installed when colima is the only runtime =="
echo

if [[ ! -r "$INSTALL_SH" || ! -r "$STRINGS" ]]; then
    echo "CANNOT-RUN: ${INSTALL_SH} or ${STRINGS} is not readable. Nothing was measured. NOT a pass." >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dockercli.XXXXXX")"
cleanup() { rm -rf "$WORK"; }   # our own mktemp path, nothing else
trap cleanup EXIT

# extract_slice <install.sh> <out>: the colima block, closed by one `fi`.
extract_slice() {
    local src="$1" out="$2" s e
    s="$(grep -n '^    ENGINE_PRESENT=false' "$src" | head -1 | cut -d: -f1)"
    e="$(awk -v s="${s:-0}" 'NR>s && /^    elif \[\[ -d "\/Applications\/Docker.app" \]\]; then$/ {print NR; exit}' "$src")"
    [[ -n "$s" && -n "$e" ]] || return 1
    sed -n "${s},$((e-1))p" "$src" > "$out"
    printf '    fi\n' >> "$out"
    SLICE_LINES="${s}-$((e-1))"
}

if ! extract_slice "$INSTALL_SH" "$WORK/probe.slice"; then
    echo "CANNOT-RUN: colima block boundaries not found in ${INSTALL_SH}. NOT a pass." >&2
    exit 2
fi
echo "  install.sh under test: ${INSTALL_SH}"
echo "  colima block: lines ${SLICE_LINES}"
echo

# ── THE HARNESS: install.sh's helpers, as recorders ───────────────────────
cat > "$WORK/harness.sh" <<'HARNESS'
set -u
info() { echo "INFO $*"; }
ok()   { echo "OK $*"; }
warn() { echo "WARN $*"; }
progress() { :; }
fail() { echo "FAIL $*"; exit 3; }
fail_with_code() { local code="$1"; shift; echo "CODE ${code}"; fail "$*"; }
export HOME="${STUB}/sandbox-home"; mkdir -p "$HOME"
export PATH="${STUB}/bin:/usr/bin:/bin"
export INSTALL_LOG="${STUB}/install.log"; : > "$INSTALL_LOG"
SCRIPT_DIR="${REPO_ROOT}"
HAS_DOCKER=false
source "${STRINGS}"
source "${STUB}/slice.sh"
echo "REACHED_END"
HARNESS

# ── STUBS ─────────────────────────────────────────────────────────────────
write_stubs() {
    local stub="$1"
    mkdir -p "$stub/bin" "$stub/plugins"
    cat > "$stub/bin/colima" <<'EOF'
#!/usr/bin/env bash
echo "colima $*" >> "${STUB}/colima.calls"
case "$1" in
    start)
        if [[ -n "${COLIMA_FATAL:-}" ]]; then
            echo "FATA[0000] ${COLIMA_FATAL}" >&2; exit 1
        fi
        if [[ ! -x "${STUB}/bin/docker" ]]; then
            echo 'FATA[0000] dependency check failed for docker: docker not found' >&2; exit 1
        fi
        touch "${STUB}/colima.running"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$stub/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB}/docker.calls"
# Compose as the CLI sees it: a plugin in ~/.docker/cli-plugins. Local, no daemon.
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then [[ -x "${HOME}/.docker/cli-plugins/docker-compose" ]] && exit 0 || exit 1; fi
# The daemon answers only once colima has started, as on a real box.
if [[ "${1:-}" == info ]]; then [[ -f "${STUB}/colima.running" ]] && exit 0 || exit 1; fi
exit 0
EOF
    printf '#!/usr/bin/env bash\necho "open $*" >> "${STUB}/open.calls"; exit 0\n' > "$stub/bin/open"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/bin/docker-compose"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/bin/sleep"
    # brew: `install` creates each named binary (docker only when
    # BREW_DELIVERS_DOCKER=1). shellenv prints nothing, so eval is a no-op.
    cat > "$stub/bin/brew" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == shellenv ]] && exit 0
echo "brew $*" >> "${STUB}/brew.calls"
shift
for pkg in "$@"; do
    case "$pkg" in
        colima)  printf '#!/usr/bin/env bash\ncase "$1" in start) echo "FATA[0000] dependency check failed for docker: docker not found" >&2; [[ -x "${STUB}/bin/docker" ]] || exit 1; touch "${STUB}/colima.running"; exit 0;; *) exit 0;; esac\n' > "${STUB}/bin/colima" ;;
        docker)  [[ "${BREW_DELIVERS_DOCKER:-1}" == 1 ]] && printf '#!/usr/bin/env bash\necho "docker $*" >> "${STUB}/docker.calls"; if [[ "${1:-}" == info ]]; then [[ -f "${STUB}/colima.running" ]] && exit 0 || exit 1; fi; exit 0\n' > "${STUB}/bin/docker" ;;
        docker-compose) printf '#!/usr/bin/env bash\nexit 0\n' > "${STUB}/bin/docker-compose" ;;
    esac
done
chmod +x "${STUB}"/bin/*
exit 0
EOF
    chmod +x "$stub"/bin/*
}

# run_arm <name> <install.sh> <colima 0|1> <docker 0|1> <compose 0|1>
#         <brew_delivers_docker 0|1> <colima_fatal or empty>
# Sets RC, OUT, LOG, BREW_CALLED (yes|no), COLIMA_CALLED (yes|no).
run_arm() {
    local name="$1" src="$2" has_colima="$3" has_docker="$4" has_compose="$5"
    local brew_delivers="$6" fatal="$7" desktop="${8:-0}"
    local stub="${WORK}/arm-${name}"
    rm -rf "$stub"; write_stubs "$stub"
    [[ "$has_colima"  == 1 ]] || rm -f "$stub/bin/colima"
    [[ "$has_docker"  == 1 ]] || rm -f "$stub/bin/docker"
    [[ "$has_compose" == 1 ]] || rm -f "$stub/bin/docker-compose"
    # Docker Desktop: its app bundle exists, and compose is only the plugin in
    # ~/.docker/cli-plugins (no Homebrew compose binary, no Homebrew plugin).
    if [[ "$desktop" == 1 ]]; then
        mkdir -p "$stub/Docker.app" "$stub/sandbox-home/.docker/cli-plugins"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/sandbox-home/.docker/cli-plugins/docker-compose"
        chmod +x "$stub/sandbox-home/.docker/cli-plugins/docker-compose"
    fi
    if ! extract_slice "$src" "$stub/slice.raw"; then
        echo "CANNOT-RUN: colima block not found in ${src} for arm ${name}. NOT a pass." >&2
        exit 2
    fi
    sed -e "s#/Applications/Docker.app#${stub}/Docker.app#g" \
        -e "s#/opt/homebrew/bin/brew#${stub}/bin/brew#g" \
        -e "s#/opt/homebrew/lib/docker/cli-plugins#${stub}/plugins#g" \
        "$stub/slice.raw" > "$stub/slice.sh"
    cp "$WORK/harness.sh" "$stub/harness.sh"
    OUT="$(env -i STUB="$stub" REPO_ROOT="$REPO_ROOT" STRINGS="$STRINGS" \
            BREW_DELIVERS_DOCKER="$brew_delivers" COLIMA_FATAL="$fatal" \
            /bin/bash "$stub/harness.sh" 2>&1)"
    RC=$?
    LOG="$(cat "$stub/install.log" 2>/dev/null)"
    [[ -f "$stub/brew.calls"   ]] && BREW_CALLED=yes   || BREW_CALLED=no
    [[ -f "$stub/colima.calls" ]] && COLIMA_CALLED=yes || COLIMA_CALLED=no
}

# ── THE FOUR CLI ARMS ─────────────────────────────────────────────────────
# colima only: the defect. Must install docker and reach the end of the block.
run_arm colima_only "$INSTALL_SH" 1 0 0 1 ""
if [[ "$RC" -eq 0 && "$BREW_CALLED" == yes ]] && grep -q 'REACHED_END' <<< "$OUT" \
   && grep -q 'brew install colima docker docker-compose' "$WORK/arm-colima_only/brew.calls"; then
    ok "colima only: brew installs docker and the block completes"
else
    bad "colima only: docker CLI not installed, block did not complete" \
        "rc=${RC} brew=${BREW_CALLED} out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# docker only: no engine, so the engine path installs colima and docker.
run_arm docker_only "$INSTALL_SH" 0 1 0 1 ""
if [[ "$RC" -eq 0 && "$BREW_CALLED" == yes ]] && grep -q 'REACHED_END' <<< "$OUT"; then
    ok "docker only: brew installs colima and the block completes"
else
    bad "docker only: block did not complete" "rc=${RC} brew=${BREW_CALLED} out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# both: engine and CLI present, so nothing is installed (control).
run_arm both "$INSTALL_SH" 1 1 1 1 ""
if [[ "$RC" -eq 0 && "$BREW_CALLED" == no ]] && grep -q 'REACHED_END' <<< "$OUT"; then
    ok "both: no brew call, block completes (control)"
else
    bad "both: unexpected brew call or failure" "rc=${RC} brew=${BREW_CALLED}"
fi

# Docker Desktop: docker CLI on PATH, compose ONLY as the plugin in
# ~/.docker/cli-plugins, no Homebrew compose, no colima. Desktop's engine is
# present, so nothing may be installed. The current branch predicate asks for
# a docker-compose binary and so reinstalls over Desktop: this arm goes red.
run_arm desktop "$INSTALL_SH" 0 1 0 1 "" 1
if [[ "$RC" -eq 0 && "$BREW_CALLED" == no ]] && grep -q 'REACHED_END' <<< "$OUT"; then
    ok "Docker Desktop (compose plugin only): no brew call, block completes"
else
    bad "Docker Desktop (compose plugin only): brew would shadow Desktop's CLI" \
        "rc=${RC} brew=${BREW_CALLED} out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# neither: a clean machine installs the lot.
run_arm neither "$INSTALL_SH" 0 0 0 1 ""
if [[ "$RC" -eq 0 && "$BREW_CALLED" == yes ]] && grep -q 'REACHED_END' <<< "$OUT"; then
    ok "neither: brew installs the runtime and the CLI, block completes"
else
    bad "neither: block did not complete" "rc=${RC} brew=${BREW_CALLED} out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# ── STDERR ARM: colima's reason reaches the log and the failure message ───
run_arm stderr "$INSTALL_SH" 1 1 1 1 "no forwarded port"
if grep -q 'FATA\[0000\] no forwarded port' <<< "$LOG" && grep -q 'colima said: .*no forwarded port' <<< "$OUT"; then
    ok "colima start stderr reaches INSTALL_LOG and the failure message names it"
else
    bad "colima start reason is discarded" \
        "rc=${RC} log_has_fatal=$(grep -c 'no forwarded port' <<< "$LOG") out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# ── POST-CONDITION ARM: brew reports success but delivers no docker ───────
run_arm no_delivery "$INSTALL_SH" 1 0 0 0 ""
if [[ "$RC" -ne 0 ]] && grep -q 'ERR-06-DMG48-DOCKER-CLI-MISSING-AFTER-BREW' <<< "$OUT"; then
    ok "brew that delivers no docker is caught by the post-condition"
else
    bad "post-condition did not fire on a brew that delivered no docker" \
        "rc=${RC} out: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)"
fi

# ── MUTANT: the OLD predicate on a colima-only stub PATH must go RED ──────
# The mutant is the file with the decision reverted to ENGINE_PRESENT alone,
# which is what main shipped. Applied-check first: a mutant that did not apply
# looks exactly like a mutant that was not caught.
MUT="$WORK/mutant-install.sh"
sed 's/if \[\[ "\$ENGINE_PRESENT" == false || "\$DOCKER_CLI_PRESENT" == false \]\]; then/if [[ "$ENGINE_PRESENT" == false ]]; then/' "$INSTALL_SH" > "$MUT"
if cmp -s "$INSTALL_SH" "$MUT"; then
    echo "  (mutant not applicable: this install.sh has no DOCKER_CLI_PRESENT decision to revert)"
else
    if grep -q 'DOCKER_CLI_PRESENT == false' "$MUT"; then
        echo "CANNOT-RUN: mutant edit did not remove the decision. NOT a pass." >&2
        exit 2
    fi
    run_arm mutant "$MUT" 1 0 0 1 ""
    if [[ "$RC" -ne 0 && "$BREW_CALLED" == no ]]; then
        ok "MUTANT (old predicate, colima-only) is RED: rc=${RC}, no docker install"
    else
        bad "MUTANT (old predicate, colima-only) was NOT caught" "rc=${RC} brew=${BREW_CALLED}"
    fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
