#!/usr/bin/env bash
#
# THE INSTALLER MUST NOT INFER A CONTAINER ENGINE FROM A CONTAINER CLIENT.
# =======================================================================
#
# FOUND ON A REAL BOX, v1.0.42 upgrade walk, Andy's Mac mini, 2026-08-23.
# The install reported SUCCESS and the wiki was dead. Measured on the box:
#
#     8000  daemon/assistant   200      <-- native launchd, alive
#     8089  ical-server        302      <-- native launchd, alive
#     8044  wiki               000      <-- Docker-hosted, dead
#     7878  Oxigraph           000      <-- Docker-hosted, dead
#
#     /Applications/Docker.app          ABSENT
#     colima / orbstack / podman        ABSENT
#     /opt/homebrew/bin/docker          EXISTS
#
# A ragged zero, not a uniform one: the dead ports are exactly the
# Docker-hosted services and the live ones exactly the native services. The
# split falls on an architectural line, which is what makes it trustworthy.
#
# THE DEFECT. install.sh guards the runtime install with:
#
#     if ! command -v docker &>/dev/null; then
#         brew install colima docker docker-compose
#     fi
#
# `command -v docker` finds the CLIENT. On macOS the Docker CLI is only a
# client -- the engine comes from Colima, Docker Desktop, OrbStack or Podman.
# A box that once had Docker Desktop and lost it keeps `/opt/homebrew/bin/
# docker` behind. The installer sees the client, concludes the runtime is
# handled, SKIPS installing Colima, and walks on with no engine at all.
#
# This is the house defect class: THE VERDICT IS INVARIANT TO THE DEFECT.
# The predicate returns the same answer whether or not a container can run.
#
# WHAT THIS TEST ASSERTS
#   1. the runtime guard consults something that implies an ENGINE, not just
#      the presence of the `docker` binary
#   2. every runtime we support is considered, not only Colima -- a box with
#      OrbStack or Podman has an engine and must not be forced to install a
#      second one
#   3. `ostler-wiki-site` / `ostler-wiki-compiler` are still pinned BY DIGEST,
#      so the runtime is genuinely load-bearing and this guard is not
#      decoration
#
# WHY A SOURCE-TEXT TEST. The real path needs a Mac with no engine, which CI
# does not have and which is exactly the state that produced the defect. The
# predicate itself is a property of the text and can be asserted here, on
# every PR, for free.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

echo
echo "== the container-runtime guard must test the ENGINE, not the client =="
echo

# ── 0. CANNOT-RUN FIRST ───────────────────────────────────────────────────
# If install.sh is not readable, every assertion below reports a confident
# verdict about nothing.
if [[ ! -r "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: ${INSTALL_SH} is not readable." >&2
    echo "  Nothing was measured. This is NOT a pass -- exit 2." >&2
    exit 2
fi
ok "CANNOT-RUN check: install.sh is readable"

# Comments are not code. This repo has been bitten by gates that scored
# prose -- strip comments before counting anything.
CODE="$(sed 's/#.*//' "$INSTALL_SH")"

# ── CONTROL, RUN FIRST AND MUST BE NON-ZERO ───────────────────────────────
# Proves the comment-stripped body is intact and greppable. Without this a
# broken `sed` would make every assertion below pass for free on an empty
# string -- the uniform-zero trap.
CTRL="$(grep -c 'docker' <<< "$CODE")"
if [[ "$CTRL" -ge 10 ]]; then
    ok "CONTROL: comment-stripped body still mentions docker ${CTRL} times (non-zero)"
else
    bad "CONTROL FAILED: only ${CTRL} docker references after stripping comments" \
        "the body is empty or sed ate it; every assertion below would be vacuous"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 1. THE RUNTIME-INSTALL GUARD MUST NOT BE A CLIENT CHECK ───────────────
# This is the defect proper, and the assertion is deliberately SCOPED to the
# decision that matters rather than to every `command -v docker` in the file.
#
# Two bare client checks are LEGITIMATE and must stay:
#   · the message-selection ladder (`elif command -v docker` -> "installed but
#     not running") -- it picks wording, it gates nothing
#   · the DMG#48 post-condition after `brew install` -- "did brew actually
#     deploy the CLI binary?" is a question ABOUT THE CLIENT, correctly asked
#
# A blunt "no bare command -v docker anywhere" predicate flags both, and a
# test that cries wolf gets switched off. So: take the 40 lines immediately
# preceding the `brew install colima` line -- the window containing whatever
# decides to run it -- and assert THAT window is engine-aware.
WINDOW="$(awk '/brew install colima/{ for(i=NR-40;i<NR;i++) print buf[i]; exit } { buf[NR]=$0 }' <<< "$CODE")"

if [[ -z "$WINDOW" ]]; then
    bad "CANNOT-RUN: found no 'brew install colima' line to scope the guard to" \
        "either the runtime install moved or was removed; this assertion measured nothing"
elif grep -qE 'command -v docker' <<< "$WINDOW"; then
    bad "the runtime-install decision still consults 'command -v docker'" \
        "the CLIENT is present on any box that ever had Docker Desktop; it does not imply an ENGINE"
else
    ok "the runtime-install guard does not decide from 'command -v docker'"
fi

# ...and it must positively consider a real engine, not merely avoid the
# client. Absence of the wrong predicate is not presence of the right one.
if grep -qE 'colima|orbstack|podman|Docker\.app' <<< "$WINDOW"; then
    ok "the runtime-install guard positively tests for an engine"
else
    bad "the runtime-install guard names no engine" \
        "it avoids the client check but asserts nothing in its place"
fi

# ── 2. AN ENGINE PREDICATE MUST EXIST ─────────────────────────────────────
# `docker info` is the cheapest honest engine probe: it fails when no daemon
# is reachable, which is the actual question.
if grep -qE 'docker info' <<< "$CODE"; then
    ok "an engine-reachability predicate (docker info) exists"
else
    bad "no 'docker info' anywhere in the code body" \
        "nothing asks whether a container can actually run"
fi

# ── 3. EVERY SUPPORTED RUNTIME MUST BE CONSIDERED ─────────────────────────
# Measured absent on the walk box: colima, orbstack, podman, Docker Desktop.
# A box carrying any ONE of them has an engine. Forcing a second install on
# someone who already runs OrbStack is a defect in the other direction.
for rt in colima orbstack podman; do
    if grep -qi "$rt" <<< "$CODE"; then
        ok "runtime considered: ${rt}"
    else
        bad "runtime NOT considered: ${rt}" \
            "a box running ${rt} has an engine; the installer must not ignore it"
    fi
done

# ── 4. THE RUNTIME IS LOAD-BEARING, SO THE GUARD IS NOT DECORATION ────────
# If these pins ever stop being digest-pinned images, this whole test is
# guarding a dependency that no longer exists -- and should be deleted rather
# than left passing vacuously.
for img in ostler-wiki-site ostler-wiki-compiler; do
    if grep -q "${img}@sha256:" <<< "$CODE"; then
        ok "${img} is still digest-pinned (a real engine is genuinely required)"
    else
        bad "${img} is no longer digest-pinned in install.sh" \
            "either the wiki stopped needing a container engine, or the pin was lost"
    fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
