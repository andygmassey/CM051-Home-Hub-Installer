#!/usr/bin/env bash
#
# tests/test_assistant_fetch_version_tracks_daemon.sh
#
# Contract: install.sh's fetch-FALLBACK default for the ostler-assistant
# daemon (OSTLER_ASSISTANT_VERSION:-X) must track the BUNDLED daemon
# version baked into the DMG (gui/Makefile DAEMON_VERSION ?= X).
#
# Why this exists: at the v0.4.6 cut the Makefile DAEMON_VERSION was bumped
# 0.4.5 -> 0.4.6 but install.sh's fetch default was left at 0.4.4, and the
# last-resort ASSISTANT_FALLBACK_VERSION still pointed at hub-v0.4.1 -- a
# release that had since been removed from ostler-ai/ostler-releases, so the
# fallback would 404 and strand any customer who hit the fetch path (older
# DMG / corrupted extraction / OSTLER_ASSISTANT_FORCE_DOWNLOAD=1 in CI).
# The bundled-app path is preferred on a normal install, so this is not
# launch-blocking, but a stale fetch default silently degrades the fallback.
#
# This test locks the invariant so the next daemon bump cannot leave the
# fetch path tracking an old version. It does NOT hard-code a version
# number -- it derives both sides from the real files and compares.
#
# Synthetic only. Pure bash. Read-only (parses the two tracked files).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
MAKEFILE="${SCRIPT_DIR}/../gui/Makefile"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
[[ -f "$MAKEFILE" ]]   || fail "gui/Makefile not found"

# 1. Bundled daemon version -- source of truth (gui/Makefile DAEMON_VERSION ?= X).
DAEMON_VERSION="$(grep -E '^DAEMON_VERSION[[:space:]]*\?=' "$MAKEFILE" \
    | head -1 | sed -E 's/^DAEMON_VERSION[[:space:]]*\?=[[:space:]]*//' | tr -d '[:space:]')"
[[ -n "$DAEMON_VERSION" ]] || fail "could not read DAEMON_VERSION from gui/Makefile"
echo "PASS: gui/Makefile DAEMON_VERSION = ${DAEMON_VERSION}"

# 2. install.sh fetch-fallback default (OSTLER_ASSISTANT_VERSION:-X on the
#    assignment line, not the progress string).
FETCH_DEFAULT="$(grep -E '^OSTLER_ASSISTANT_VERSION="\$\{OSTLER_ASSISTANT_VERSION:-' "$INSTALL_SH" \
    | head -1 | sed -E 's/.*:-([0-9][0-9.]*)\}".*/\1/')"
[[ -n "$FETCH_DEFAULT" ]] || fail "could not read OSTLER_ASSISTANT_VERSION default from install.sh"
echo "PASS: install.sh OSTLER_ASSISTANT_VERSION default = ${FETCH_DEFAULT}"

# 3. The invariant: fetch default tracks the bundled daemon.
[[ "$FETCH_DEFAULT" == "$DAEMON_VERSION" ]] \
    || fail "fetch default (${FETCH_DEFAULT}) does not track bundled DAEMON_VERSION (${DAEMON_VERSION}); bump install.sh's OSTLER_ASSISTANT_VERSION default to match the DMG-bundled daemon"
echo "PASS: install.sh fetch default tracks the bundled daemon (${FETCH_DEFAULT})"

# 4. The last-resort fallback must be a DIFFERENT, non-empty version (a
#    fallback that equals the primary is not a meaningful retry) and must
#    not be the known-removed hub-v0.4.1 tag.
FALLBACK_VERSION="$(grep -E '^ASSISTANT_FALLBACK_VERSION=' "$INSTALL_SH" \
    | head -1 | sed -E 's/^ASSISTANT_FALLBACK_VERSION="?([0-9][0-9.]*)"?.*/\1/')"
[[ -n "$FALLBACK_VERSION" ]] || fail "could not read ASSISTANT_FALLBACK_VERSION from install.sh"
[[ "$FALLBACK_VERSION" != "$FETCH_DEFAULT" ]] \
    || fail "ASSISTANT_FALLBACK_VERSION (${FALLBACK_VERSION}) equals the primary default; a fallback must be a different version to be a meaningful retry"
[[ "$FALLBACK_VERSION" != "0.4.1" ]] \
    || fail "ASSISTANT_FALLBACK_VERSION is 0.4.1 -- hub-v0.4.1 was removed from ostler-ai/ostler-releases and would 404"
echo "PASS: ASSISTANT_FALLBACK_VERSION = ${FALLBACK_VERSION} (distinct, not the removed 0.4.1)"

echo ""
echo "ALL ASSISTANT FETCH-VERSION CONTRACT TESTS PASSED"
