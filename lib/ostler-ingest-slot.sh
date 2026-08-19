#!/usr/bin/env bash
#
# ostler-ingest-slot.sh
#
# Fair, time-bounded arbitration of the ONE shared Ollama ingest slot.
#
# ---------------------------------------------------------------------
# The defect this replaces
# ---------------------------------------------------------------------
# Five LaunchAgents contend for a single mkdir mutex
# (~/.ostler/workspace/ingest-ollama.lock.d): the four conversation
# feeds (email / iMessage / WhatsApp / spoken) and the wiki recompile.
# Before this lib they implemented THREE mutually incompatible policies
# on that one mutex:
#
#   * email + spoken      -- instant-yield if held.
#   * iMessage + WhatsApp -- if the feed has NEVER run, wait a flat 75s,
#                            then yield.
#   * wiki recompile      -- blocking `while ! mkdir` spin, unbounded.
#
# and NONE of them bounded the HOLD. A holder kept the slot for as long
# as its pipeline ran, and those pipelines loop over a whole document
# queue dispatching each one to pwg-convo (measured on the live v1.0.26
# box: 17s to 900s per document, per-document, in an unbounded loop).
#
# Measured on the box 2026-08-14: the email feed held the slot for over
# an hour while the iMessage feed -- which had NEVER completed a single
# pass -- woke every 15 minutes, waited its flat 75s, and yielded. It
# logged "this feed has NEVER RUN" forever. The moment the holder was
# stopped the waiting feed took the slot and drained normally, which is
# the proof that the feed was never slow: it was starved.
#
# The flat 75s patience was the whole bug: it is a CONSTANT, and it was
# being compared against a hold with NO BOUND. No constant can win that
# race. Widening the constant does not fix it, and neither does copying
# the same constant into the other feeds.
#
# ---------------------------------------------------------------------
# The contract this lib enforces
# ---------------------------------------------------------------------
# 1. BOUNDED HOLD. A holder may keep the slot indefinitely while nobody
#    wants it (so the multi-hour wiki summary backfill is undisturbed on
#    an idle box, which was the original reason no time-based steal
#    existed). The moment another feed enrols as a waiter, the holder is
#    bounded: at OSTLER_SLOT_MAX_HOLD_SECS the holder stops ITSELF at a
#    clean point and releases. Nothing is lost -- every pipeline is
#    watermarked and idempotent, so the next tick resumes.
#
#    The bound is HOLDER-ENFORCED, never waiter-enforced. A waiter never
#    kills a holder. That keeps the single-flight invariant absolute:
#    there is never a window where two pipelines drive Ollama at once.
#
# 2. DERIVED PATIENCE. A waiter no longer guesses. It reads the holder's
#    own recorded deadline out of the lock and waits until that deadline
#    plus a grace. Patience is therefore always >= the hold, which is
#    exactly the property the flat 75s constant lacked.
#
# 3. FIFO FAIRNESS. Waiters enrol in a queue directory. Only the
#    longest-waiting live feed attempts the lock, so a feed cannot be
#    beaten to the slot repeatedly by a luckier neighbour.
#
# 4. VISIBILITY. Every acquire / yield / completion is recorded per feed
#    under the slot state dir, so "this feed has never run" is a fact a
#    human can be shown rather than a line in a log nobody reads.
#
# ---------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------
#   ostler_slot_acquire <feed-label>   -> 0 acquired, 1 caller should
#                                         yield this tick (exit 0)
#   ostler_slot_run <cmd> [args...]    -> run the payload under the
#                                         max-hold watchdog; returns the
#                                         payload's rc, except a
#                                         deliberate max-hold stop which
#                                         is reported as 0 (it is a
#                                         scheduled yield, not a failure)
#   ostler_slot_release                -> idempotent; also runs on EXIT
#
# Callers MUST NOT install their own EXIT trap after ostler_slot_acquire.
#
# ---------------------------------------------------------------------
# Tunables (all optional)
# ---------------------------------------------------------------------
#   OSTLER_INGEST_SLOT=0             disable this lib entirely; the
#                                    caller keeps its own inline lock
#   OSTLER_INGEST_LOCK               lock dir (unchanged default, so a
#                                    tick that has not yet been rewired
#                                    still interlocks correctly)
#   OSTLER_SLOT_MAX_HOLD_SECS        max hold once someone is waiting
#                                    (default 900 = one tick interval)
#   OSTLER_SLOT_WAIT_SECS            patience floor for a HEALTHY feed
#                                    (default 75, i.e. prior behaviour)
#   OSTLER_SLOT_GRACE_SECS           slack added past a holder deadline
#                                    (default 60)
#   OSTLER_SLOT_POLL_SECS            poll interval (default 5)
#   OSTLER_SLOT_STARVE_AFTER_SECS    a feed unseen this long counts as
#                                    starving and waits out the holder
#                                    (default 21600 = 6h)
#   OSTLER_SLOT_LEGACY_MAX_HOLD_SECS assumed bound for a pre-lib holder
#                                    that recorded no deadline
#                                    (default 3600)
#   OSTLER_SLOT_STATE_DIR            per-feed state dir
#
# macOS ships bash 3.2, and the sealed ticks run under /bin/bash, so this
# file stays bash-3.2 clean: no associative arrays, no mapfile, no ${x^^}.
# British English throughout.

# --- resolved configuration ------------------------------------------
_ostler_slot_ws() {
    printf '%s\n' "${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}"
}

_OSTLER_SLOT_DIR="${OSTLER_INGEST_LOCK:-$(_ostler_slot_ws)/ingest-ollama.lock.d}"
_OSTLER_SLOT_WAITERS="${_OSTLER_SLOT_DIR%.d}.waiters.d"
_OSTLER_SLOT_STATE="${OSTLER_SLOT_STATE_DIR:-$(_ostler_slot_ws)/ingest-slot}"
# MEASURED on the v1.0.33 box, 2026-08-17. The mechanism was not missing --
# waiters dir, max-hold and starve-after all exist and all worked. The RATIO
# between two of them guaranteed starvation:
#
#   MAX_HOLD 900s   a holder keeps the slot 15 minutes even with a waiter
#   WAIT      75s   a HEALTHY waiter gives up after 75 seconds
#
# A waiter's patience was 1/12th of a holder's right, so it could never
# outlast one. Observed: email-bundle held with 895s remaining while
# imessage-bundle got 4s. Twelve contentions in the log, email-bundle winning
# eight of them, and whatsapp/imessage/spoken all starved in turn.
#
# STARVE_AFTER 21600s meant the "this feed is starving" escalation fired only
# after SIX HOURS -- long after the install finished and the owner had already
# looked at an empty Messages surface and concluded the product was broken.
#
# MAX_HOLD is now 180s: longer than any feed's real work (imessage needed 4s)
# and comfortably above WAIT=75s, so a holder still finishes a unit of work
# but a waiter that keeps asking now outlives it. STARVE_AFTER 1800s puts the
# escalation inside the install window where somebody can act on it.
_OSTLER_SLOT_MAX_HOLD="${OSTLER_SLOT_MAX_HOLD_SECS:-180}"
_OSTLER_SLOT_WAIT="${OSTLER_SLOT_WAIT_SECS:-75}"
_OSTLER_SLOT_GRACE="${OSTLER_SLOT_GRACE_SECS:-60}"
_OSTLER_SLOT_POLL="${OSTLER_SLOT_POLL_SECS:-5}"
_OSTLER_SLOT_STARVE_AFTER="${OSTLER_SLOT_STARVE_AFTER_SECS:-1800}"
_OSTLER_SLOT_LEGACY_HOLD="${OSTLER_SLOT_LEGACY_MAX_HOLD_SECS:-3600}"
# How long a payload gets to honour SIGTERM before the watchdog escalates to
# SIGKILL. The wiki payload is `docker compose run`, where TERM to the client
# is not the same act as stopping the container, so this must be generous
# enough for a clean teardown and short enough that the hold stays a bound.
_OSTLER_SLOT_KILL_GRACE="${OSTLER_SLOT_KILL_GRACE_SECS:-30}"

_OSTLER_SLOT_FEED=""
_OSTLER_SLOT_HELD=0
_OSTLER_SLOT_DEADLINE=0
_OSTLER_SLOT_WATCHDOG_PID=""

_ostler_slot_now() { date +%s; }

_ostler_slot_log() { echo "ostler-slot[${_OSTLER_SLOT_FEED:-?}]: $*"; }

# --- per-feed state --------------------------------------------------
# One key=value file per feed. Deliberately plain text: it is read by
# Doctor, by the tests, and by a human with `cat`, and it must never be
# able to fail a tick, so every write is best-effort.
_ostler_slot_state_file() {
    printf '%s\n' "$_OSTLER_SLOT_STATE/$1.state"
}

_ostler_slot_state_get() {
    # _ostler_slot_state_get <feed> <key> -- prints value or empty
    local f
    f="$(_ostler_slot_state_file "$1")"
    [ -f "$f" ] || return 0
    # Exact key match at line start; the value is everything after "=".
    sed -n "s/^$2=//p" "$f" 2>/dev/null | tail -1
}

_ostler_slot_state_set() {
    # _ostler_slot_state_set <feed> <key> <value> -- best effort
    local f tmp
    f="$(_ostler_slot_state_file "$1")"
    mkdir -p "$_OSTLER_SLOT_STATE" 2>/dev/null || return 0
    tmp="$f.$$"
    if [ -f "$f" ]; then
        grep -v "^$2=" "$f" 2>/dev/null > "$tmp" || true
    else
        : > "$tmp" 2>/dev/null || return 0
    fi
    printf '%s=%s\n' "$2" "$3" >> "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

_ostler_slot_bump() {
    # _ostler_slot_bump <feed> <key> -- increment an integer counter
    local cur
    cur="$(_ostler_slot_state_get "$1" "$2")"
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    _ostler_slot_state_set "$1" "$2" "$((cur + 1))"
}

# Has this feed EVER completed a pass? This is the fact the operator
# needs, and it is the input to both the starvation policy and the
# Doctor card.
ostler_slot_feed_never_ran() {
    local completed
    completed="$(_ostler_slot_state_get "$1" last_completed)"
    case "$completed" in ''|0|*[!0-9]*) return 0 ;; esac
    return 1
}

# --- waiter queue ----------------------------------------------------
_ostler_slot_enrol() {
    mkdir -p "$_OSTLER_SLOT_WAITERS" 2>/dev/null || return 0
    printf '%s %s\n' "$(_ostler_slot_now)" "$$" \
        > "$_OSTLER_SLOT_WAITERS/$_OSTLER_SLOT_FEED" 2>/dev/null || true

    # START THE HOLDER'S CLOCK, because THIS is the moment the contract says
    # the hold becomes bounded: "A holder may keep the slot indefinitely while
    # nobody wants it. The moment another feed enrols as a waiter, the holder
    # is bounded."
    #
    # The deadline used to be anchored to ACQUISITION, which is a different
    # event, and the gap between them is the whole point of the design -- the
    # multi-hour uncontended backfill. Anchored at acquire, that backfill's
    # deadline is already hours past before any waiter exists, so the holder
    # was preempted within one poll of the first tick that woke, every tick,
    # and could never finish. It also made the waiter's logged "deadline in
    # Ns" go negative, which is what #783 measured 51 times.
    #
    # Written ONCE, by whichever waiter enrols first, and never refreshed: a
    # second waiter must not hand the holder another full MAX_HOLD. `set -C`
    # makes the create atomic, so concurrent enrolments cannot race to reset
    # it.
    #
    # ZERO GRACE FOR A LATE WAITER IS CHOSEN, NOT AN OVERSIGHT. Nothing clears
    # bounded_from while the holder lives, so a waiter arriving long after an
    # earlier waiter withdrew finds the deadline already elapsed and preempts
    # on the next poll, where the FIRST waiter granted a full MAX_HOLD. That is
    # deliberate: the bound exists to cap how long ONE holder may occupy the
    # slot once anyone has wanted it, not to give the holder a fresh allowance
    # per arrival. Clearing it on withdrawal would let a holder be renewed
    # indefinitely by a stream of waiters that each give up -- the unbounded
    # hold this library exists to remove, rebuilt out of grace periods.
    if [ -d "$_OSTLER_SLOT_DIR" ] && [ ! -f "$_OSTLER_SLOT_DIR/bounded_from" ]; then
        ( set -C; printf '%s\n' "$(_ostler_slot_now)" \
            > "$_OSTLER_SLOT_DIR/bounded_from" ) 2>/dev/null || true
    fi
}

_ostler_slot_withdraw() {
    [ -n "$_OSTLER_SLOT_FEED" ] || return 0
    rm -f "$_OSTLER_SLOT_WAITERS/$_OSTLER_SLOT_FEED" 2>/dev/null || true
}

# Reap entries whose owning shell is gone, so a crashed waiter can never
# wedge the queue for the feeds behind it.
_ostler_slot_reap_waiters() {
    local f ts pid
    [ -d "$_OSTLER_SLOT_WAITERS" ] || return 0
    for f in "$_OSTLER_SLOT_WAITERS"/*; do
        [ -f "$f" ] || continue
        ts=""; pid=""
        read -r ts pid < "$f" 2>/dev/null || true
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null || true
    done
}

_ostler_slot_waiters_present() {
    local f
    _ostler_slot_reap_waiters
    [ -d "$_OSTLER_SLOT_WAITERS" ] || return 1
    for f in "$_OSTLER_SLOT_WAITERS"/*; do
        [ -f "$f" ] && return 0
    done
    return 1
}

# FIFO: the longest-waiting live feed. Glob order is lexicographic, so
# an exact timestamp tie resolves deterministically by feed name.
_ostler_slot_oldest_waiter() {
    local f ts pid best_ts best_feed
    best_ts=""; best_feed=""
    _ostler_slot_reap_waiters
    [ -d "$_OSTLER_SLOT_WAITERS" ] || return 0
    for f in "$_OSTLER_SLOT_WAITERS"/*; do
        [ -f "$f" ] || continue
        ts=""; pid=""
        read -r ts pid < "$f" 2>/dev/null || true
        case "$ts" in ''|*[!0-9]*) continue ;; esac
        if [ -z "$best_ts" ] || [ "$ts" -lt "$best_ts" ]; then
            best_ts="$ts"
            best_feed="$(basename "$f")"
        fi
    done
    printf '%s\n' "$best_feed"
}

# --- lock metadata ---------------------------------------------------
_ostler_slot_meta() {
    # _ostler_slot_meta <name> -- prints the value or empty
    cat "$_OSTLER_SLOT_DIR/$1" 2>/dev/null || true
}

_ostler_slot_holder_pid() { _ostler_slot_meta pid; }

_ostler_slot_holder_alive() {
    local h
    h="$(_ostler_slot_holder_pid)"
    [ -n "$h" ] || return 1
    kill -0 "$h" 2>/dev/null
}

# When does the current holder have to be out by? A holder that recorded
# its own deadline is authoritative. A PRE-LIB holder recorded nothing,
# so we fall back to the lock's mtime plus a generous legacy bound --
# that keeps a waiter's patience finite during the upgrade window instead
# of inheriting the old unbounded wait.
_ostler_slot_holder_deadline() {
    local acquired hold bounded
    hold="$(_ostler_slot_meta max_hold)"
    case "$hold" in ''|*[!0-9]*) hold="" ;; esac

    # THE CLOCK STARTS AT CONTENTION, NOT AT ACQUISITION. `bounded_from` is
    # written by the first waiter to enrol. Until that exists the hold is
    # deliberately unbounded, which is the design: an idle box must be allowed
    # to finish a multi-hour backfill undisturbed.
    #
    # Anchoring to acquired_at instead made the deadline for exactly that
    # backfill already hours past before any waiter appeared, so the holder was
    # preempted within one poll every tick and the waiter's logged "deadline in
    # Ns" ran negative (#783, 51 events on .224).
    bounded="$(_ostler_slot_meta bounded_from)"
    case "$bounded" in ''|*[!0-9]*) bounded="" ;; esac
    if [ -n "$bounded" ] && [ -n "$hold" ]; then
        printf '%s\n' "$((bounded + hold))"
        return 0
    fi

    acquired="$(_ostler_slot_meta acquired_at)"
    case "$acquired" in ''|*[!0-9]*) acquired="" ;; esac
    if [ -n "$acquired" ] && [ -n "$hold" ]; then
        # No waiter has enrolled yet, so there is no bound to report. Answer
        # with acquire + hold anyway rather than nothing: this branch is only
        # reached by a caller ASKING about an uncontended holder, and a finite
        # honest-if-early answer beats an empty string a caller must guess at.
        printf '%s\n' "$((acquired + hold))"
        return 0
    fi
    acquired="$(stat -f %m "$_OSTLER_SLOT_DIR" 2>/dev/null || stat -c %Y "$_OSTLER_SLOT_DIR" 2>/dev/null || true)"
    case "$acquired" in ''|*[!0-9]*) acquired="$(_ostler_slot_now)" ;; esac
    printf '%s\n' "$((acquired + _OSTLER_SLOT_LEGACY_HOLD))"
}

_ostler_slot_take() {
    # Atomic. mkdir is the only primitive that is atomic on every POSIX
    # filesystem and macOS ships no flock(1).
    mkdir "$_OSTLER_SLOT_DIR" 2>/dev/null || return 1
    _OSTLER_SLOT_HELD=1
    _OSTLER_SLOT_DEADLINE=$(( $(_ostler_slot_now) + _OSTLER_SLOT_MAX_HOLD ))
    printf '%s\n' "$$" > "$_OSTLER_SLOT_DIR/pid" 2>/dev/null || true
    printf '%s\n' "$_OSTLER_SLOT_FEED" > "$_OSTLER_SLOT_DIR/holder" 2>/dev/null || true
    printf '%s\n' "$(_ostler_slot_now)" > "$_OSTLER_SLOT_DIR/acquired_at" 2>/dev/null || true
    printf '%s\n' "$_OSTLER_SLOT_MAX_HOLD" > "$_OSTLER_SLOT_DIR/max_hold" 2>/dev/null || true
    _ostler_slot_withdraw
    _ostler_slot_state_set "$_OSTLER_SLOT_FEED" last_acquired "$(_ostler_slot_now)"
    _ostler_slot_state_set "$_OSTLER_SLOT_FEED" consecutive_yields 0
    trap 'ostler_slot_release' EXIT
    return 0
}

# A holder whose shell is gone leaves the directory behind. Reclaiming it
# is safe precisely because the PID is dead.
_ostler_slot_reclaim_if_dead() {
    _ostler_slot_holder_alive && return 1
    rm -rf "$_OSTLER_SLOT_DIR" 2>/dev/null || true
    return 0
}

# --- public: acquire -------------------------------------------------
ostler_slot_acquire() {
    _OSTLER_SLOT_FEED="${1:-unknown}"

    if [ "${OSTLER_INGEST_SLOT:-1}" = "0" ]; then
        _ostler_slot_log "arbitration disabled by OSTLER_INGEST_SLOT=0."
        return 1
    fi

    mkdir -p "$(dirname "$_OSTLER_SLOT_DIR")" 2>/dev/null || true
    _ostler_slot_state_set "$_OSTLER_SLOT_FEED" feed "$_OSTLER_SLOT_FEED"

    # Uncontended: take it and go.
    if _ostler_slot_take; then
        return 0
    fi

    # Contended. Enrol FIRST, so the holder can see that someone is
    # waiting and start counting down its bounded hold.
    _ostler_slot_enrol
    trap '_ostler_slot_withdraw' EXIT

    local starving=0 patience_floor
    if ostler_slot_feed_never_ran "$_OSTLER_SLOT_FEED"; then
        starving=1
    else
        local last_done now
        last_done="$(_ostler_slot_state_get "$_OSTLER_SLOT_FEED" last_completed)"
        now="$(_ostler_slot_now)"
        case "$last_done" in
            ''|*[!0-9]*) starving=1 ;;
            *) [ "$((now - last_done))" -ge "$_OSTLER_SLOT_STARVE_AFTER" ] && starving=1 ;;
        esac
    fi

    if [ "$starving" = "1" ]; then
        # Patience DERIVED from the holder's recorded deadline, never a
        # bare constant. This is the property the old flat 75s lacked.
        local deadline limit
        deadline="$(_ostler_slot_holder_deadline)"
        limit=$(( deadline + _OSTLER_SLOT_GRACE ))
        patience_floor=$(( $(_ostler_slot_now) + _OSTLER_SLOT_WAIT ))
        [ "$limit" -lt "$patience_floor" ] && limit="$patience_floor"
        _ostler_slot_log "slot held by $(_ostler_slot_holder_pid) ($(_ostler_slot_meta holder)); this feed is starving, waiting for the holder's bounded hold to expire (deadline in $(( deadline - $(_ostler_slot_now) ))s)."
    else
        local limit
        limit=$(( $(_ostler_slot_now) + _OSTLER_SLOT_WAIT ))
        _ostler_slot_log "slot held by $(_ostler_slot_holder_pid) ($(_ostler_slot_meta holder)); this feed is healthy, waiting up to ${_OSTLER_SLOT_WAIT}s."
    fi

    local me
    while [ "$(_ostler_slot_now)" -lt "$limit" ]; do
        sleep "$_OSTLER_SLOT_POLL"

        # Keep our enrolment fresh so the reaper never drops us.
        [ -f "$_OSTLER_SLOT_WAITERS/$_OSTLER_SLOT_FEED" ] || _ostler_slot_enrol

        if [ -d "$_OSTLER_SLOT_DIR" ] && ! _ostler_slot_holder_alive; then
            _ostler_slot_reclaim_if_dead
        fi

        if [ ! -d "$_OSTLER_SLOT_DIR" ]; then
            # FIFO: only the longest-waiting feed may take the free slot.
            me="$(_ostler_slot_oldest_waiter)"
            if [ -n "$me" ] && [ "$me" != "$_OSTLER_SLOT_FEED" ]; then
                continue
            fi
            if _ostler_slot_take; then
                _ostler_slot_log "acquired the slot after waiting."
                return 0
            fi
        fi

        # A starving waiter re-derives its limit: if the holder changed,
        # the new holder's deadline governs from here.
        if [ "$starving" = "1" ]; then
            local d2
            d2="$(_ostler_slot_holder_deadline)"
            [ "$((d2 + _OSTLER_SLOT_GRACE))" -gt "$limit" ] && limit=$(( d2 + _OSTLER_SLOT_GRACE ))
        fi
    done

    _ostler_slot_bump "$_OSTLER_SLOT_FEED" consecutive_yields
    _ostler_slot_state_set "$_OSTLER_SLOT_FEED" last_yield "$(_ostler_slot_now)"
    if [ "$starving" = "1" ]; then
        _ostler_slot_log "STARVED: still could not get the slot; this feed has produced nothing yet. Holder $(_ostler_slot_holder_pid) ($(_ostler_slot_meta holder)) has exceeded its bounded hold. Yielding; the next tick retries."
    else
        _ostler_slot_log "slot still busy; yielding this tick (next tick retries)."
    fi
    _ostler_slot_withdraw
    return 1
}

# --- holder-side max-hold watchdog -----------------------------------
# Terminates the PAYLOAD, never the holder shell, so the EXIT trap still
# runs and the lock is released cleanly rather than left for the reaper.
# Signal a whole process tree. Children first, so a parent cannot reap and
# orphan them mid-walk.
_ostler_slot_signal_tree() {
    local sig="$1" pid="$2" kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        _ostler_slot_signal_tree "$sig" "$kid"
    done
    kill -"$sig" "$pid" 2>/dev/null || true
}

# STOP THE PAYLOAD, AND VERIFY THAT IT STOPPED.
#
# This used to be a single TERM to the tree, after which the watchdog
# returned. Nothing checked whether anything died, nothing escalated, and the
# watchdog was gone -- so a payload that ignored or was slow on SIGTERM kept
# the shared slot indefinitely with the only enforcer already exited. That is
# not a bound, and it is the mechanism behind a waiter blocked 536s past a
# deadline on .224 (#783).
#
# TERM -> poll -> KILL -> poll. Returns 0 only when the payload is actually
# gone, and prints WHICH limb ended it so a log can distinguish "asked nicely
# and it worked" from "had to kill it" from "could not stop it at all". A
# watchdog that cannot say whether it succeeded is reporting that it acted,
# not that it worked.
_ostler_slot_kill_tree() {
    local pid="$1" waited=0

    _ostler_slot_signal_tree TERM "$pid"
    while [ "$waited" -lt "$_OSTLER_SLOT_KILL_GRACE" ]; do
        kill -0 "$pid" 2>/dev/null || { _ostler_slot_log "payload stopped on SIGTERM after ${waited}s."; return 0; }
        sleep 1
        waited=$(( waited + 1 ))
    done

    _ostler_slot_log "payload ignored SIGTERM for ${_OSTLER_SLOT_KILL_GRACE}s; escalating to SIGKILL so the slot is genuinely released."
    _ostler_slot_signal_tree KILL "$pid"
    waited=0
    while [ "$waited" -lt "$_OSTLER_SLOT_KILL_GRACE" ]; do
        kill -0 "$pid" 2>/dev/null || { _ostler_slot_log "payload stopped on SIGKILL."; return 0; }
        sleep 1
        waited=$(( waited + 1 ))
    done

    # Unkillable (uninterruptible sleep, or a pid we may not signal). Say so
    # LOUDLY rather than returning as though the slot were free: a caller that
    # believes a stuck holder has yielded is worse off than one that knows.
    _ostler_slot_log "COULD NOT STOP the payload (pid $pid) with TERM or KILL. The slot is still held. This is not a yield."
    return 1
}

_ostler_slot_watchdog() {
    local work_pid="$1" now deadline
    while :; do
        sleep "$_OSTLER_SLOT_POLL"
        kill -0 "$work_pid" 2>/dev/null || return 0
        [ -d "$_OSTLER_SLOT_DIR" ] || return 0
        now="$(_ostler_slot_now)"
        # Read the deadline EVERY poll rather than using the value fixed at
        # acquire time: it does not exist until a waiter enrols, and the whole
        # correction in #783 is that enrolment is the event that starts it.
        deadline="$(_ostler_slot_holder_deadline)"
        case "$deadline" in ''|*[!0-9]*) continue ;; esac
        [ "$now" -ge "$deadline" ] || continue
        # Nobody waiting: a long backfill on an idle box is not a
        # problem, so let it run. This is why the wiki summary pass is
        # still allowed to take hours.
        _ostler_slot_waiters_present || continue
        : > "$_OSTLER_SLOT_DIR/preempted" 2>/dev/null || true
        _ostler_slot_log "reached the ${_OSTLER_SLOT_MAX_HOLD}s maximum hold with another feed waiting; stopping cleanly so the waiting feed gets a turn. Progress is watermarked; the next tick resumes."
        # THE WATCHDOG MUST NOT DISCARD ITS OWN VERDICT.
        #
        # _ostler_slot_kill_tree returns 1 when TERM and KILL both failed, and
        # says so loudly. This used to be `kill_tree; return 0` -- computing a
        # verdict and throwing it away, then exiting and leaving NO ENFORCER
        # behind. That is precisely the shape this whole fix exists to close,
        # sitting inside the fix (#861 residual, Archie).
        #
        # On failure we do NOT return: we fall through to the next poll and try
        # again, so an enforcer remains for as long as the payload does. The
        # loop's own guards terminate it -- the `kill -0` at the top returns 0
        # once the payload is finally gone, and the slot-dir check returns 0 if
        # the slot was released underneath us -- so retrying cannot spin
        # forever on a dead process.
        if _ostler_slot_kill_tree "$work_pid"; then
            return 0
        fi
        _ostler_slot_log "stop attempt failed; the watchdog is STAYING UP and will retry each poll rather than exit and leave the slot unenforced."
    done
}

# --- public: run the payload ----------------------------------------
ostler_slot_run() {
    if [ "$_OSTLER_SLOT_HELD" != "1" ]; then
        # Not holding (arbitration disabled / caller used its own lock).
        "$@"
        return $?
    fi

    "$@" &
    local work_pid=$!
    printf '%s\n' "$work_pid" > "$_OSTLER_SLOT_DIR/work_pid" 2>/dev/null || true

    _ostler_slot_watchdog "$work_pid" &
    _OSTLER_SLOT_WATCHDOG_PID=$!

    # `wait` on a signalled child makes the shell print "Terminated: 15"
    # to stderr, which launchd files as an error for what is in fact a
    # deliberate, correct yield. Silence only that reaping report.
    local rc=0
    wait "$work_pid" 2>/dev/null || rc=$?

    if [ -n "$_OSTLER_SLOT_WATCHDOG_PID" ]; then
        kill "$_OSTLER_SLOT_WATCHDOG_PID" 2>/dev/null || true
        wait "$_OSTLER_SLOT_WATCHDOG_PID" 2>/dev/null || true
        _OSTLER_SLOT_WATCHDOG_PID=""
    fi

    if [ -f "$_OSTLER_SLOT_DIR/preempted" ]; then
        # A scheduled yield is not a failure -- reporting it as one would
        # make launchd log a hard error for correct behaviour. But it is
        # NOT a completed pass either: recording it as one would tell the
        # starvation detector this feed is healthy when it has still
        # never finished a drain, which is precisely the blindness that
        # let the live box report a feed as fine while it produced
        # nothing. A preempted feed stays "starving" and keeps priority.
        _ostler_slot_state_set "$_OSTLER_SLOT_FEED" last_preempted "$(_ostler_slot_now)"
        _ostler_slot_bump "$_OSTLER_SLOT_FEED" preempt_count
        return 0
    fi

    if [ "$rc" = "0" ]; then
        _ostler_slot_state_set "$_OSTLER_SLOT_FEED" last_completed "$(_ostler_slot_now)"
    fi
    return "$rc"
}

# --- public: release -------------------------------------------------
ostler_slot_release() {
    if [ -n "$_OSTLER_SLOT_WATCHDOG_PID" ]; then
        kill "$_OSTLER_SLOT_WATCHDOG_PID" 2>/dev/null || true
        _OSTLER_SLOT_WATCHDOG_PID=""
    fi
    _ostler_slot_withdraw
    if [ "$_OSTLER_SLOT_HELD" = "1" ]; then
        _OSTLER_SLOT_HELD=0
        rm -rf "$_OSTLER_SLOT_DIR" 2>/dev/null || true
    fi
    return 0
}
