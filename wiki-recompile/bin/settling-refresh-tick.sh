#!/usr/bin/env bash
#
# settling-refresh-tick.sh
#
# Every 15 minutes (com.creativemachines.ostler.settling-refresh, StartInterval
# 900) refresh settling.json only, so the setup status screen (wiki panel and
# home card) is not frozen for the 24 h between full wiki compiles.
#
# Runs exactly the CM044 settling-only contract command (no LLM, no Oxigraph,
# no page rendering, target under 10 s). The wiki-compiler image's ENTRYPOINT
# is already `python -m compiler` (CM044 docker/Dockerfile.compiler), so only
# the compiler's own flags follow the service name:
#   docker compose --profile compile run --rm -T wiki-compiler --settling-only
# Adding `python -m compiler.compile` here reaches argparse as positionals and
# fails with exit 2 on every tick (v1.0.130 walk: settling.json never written).
#
# Overlap rules (exit 0 and a log line when skipped, never an error):
#   1. Its own lock, so a slow run is never doubled up by the next tick.
#   2. The wiki-recompile tick lock (${OSTLER_DIR}/.wiki-recompile.lock, the
#      same atomic mkdir + pid mutex): only CHECKED here, never taken, so this
#      agent can never delay the daily recompile.
#   settling.json itself is NOT locked here. CM044's --settling-only is the one
#   writer and serialises every write under <output_dir>/.settling.lock
#   (fcntl.flock) inside the compiler; a second lock on the file from this
#   script would compete with it. The shared background-LLM slot is not taken
#   either: no LLM is used, and the full compile holds that slot for hours.
#
# RunAtLoad is on in the plist: the daily full compile no longer writes
# settling.json, so on a first install the file does not exist until the first
# tick, and that tick runs at install bootstrap.
#
# It keeps running after setup completes, on purpose: the compiler decides
# completeness (a new channel or a changed population re-opens the bar), and a
# second copy of that rule here would drift. A completed run is the same
# sub-10-second no-LLM job every 15 minutes.
#
# Failure: a non-zero compile exit propagates so launchd records it in
# settling-refresh.err. Output is summarised, not echoed (it can name people).
set -euo pipefail

# Appended, not prepended: the plist sets the full PATH, and a prepend would
# put a host docker ahead of a test stub.
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin:/opt/homebrew/bin"
OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

LOCK_MAX_AGE_MIN="${SETTLING_LOCK_MAX_AGE_MIN:-30}"
WIKI_LOCK_MAX_AGE_MIN="${WIKI_LOCK_MAX_AGE_MIN:-360}"

# True when $1 is a lock dir held by a live pid younger than $2 minutes.
lock_held() {
    local dir="$1" max="$2" pid
    [ -d "$dir" ] || return 1
    [ -n "$(find "$dir" -maxdepth 1 -mmin -"$max" -print 2>/dev/null)" ] || return 1
    pid="$(cat "${dir}/pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

if lock_held "${OSTLER_DIR}/.wiki-recompile.lock" "$WIKI_LOCK_MAX_AGE_MIN"; then
    log "wiki-recompile baseline holds its lock; skipping this settling refresh"
    exit 0
fi

LOCK_DIR="${OSTLER_DIR}/.settling-refresh.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if lock_held "$LOCK_DIR" "$LOCK_MAX_AGE_MIN"; then
        log "previous settling refresh still running; skipping"
        exit 0
    fi
    log "reclaiming stale settling-refresh lock"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "could not acquire settling-refresh lock after reclaim; another tick won the race; skipping"
        exit 0
    fi
fi
printf '%s\n' "$$" > "${LOCK_DIR}/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

cd "$OSTLER_DIR"
log "settling refresh start (settling-only, no LLM)"
_out="$(mktemp -t settling-refresh.XXXXXX)"
rc=0
docker compose --profile compile run --rm -T wiki-compiler \
    --settling-only </dev/null >"$_out" 2>&1 || rc=$?
log "settling refresh: compile output withheld (it can name people): $(wc -l <"$_out" | tr -d ' ') lines, exit ${rc}"
rm -f "$_out"
if [ "$rc" -ne 0 ]; then
    log "settling refresh FAILED (exit ${rc}); settling.json not refreshed"
    exit "$rc"
fi
log "settling refresh done"
