#!/usr/bin/env bash
#
# WHO PUT THE CONTAINER ENGINE THERE.
# ===================================
#
# WHY THIS EXISTS, IN ONE SENTENCE: when a customer's wiki goes dark we
# currently cannot tell them whether we broke it or they did, and "not our
# fault" is not a defensible answer to someone whose product stopped working.
#
# ── THE DECISION THIS SERVES (Andy, 2026-08-24) ───────────────────────────
#
# CM044's locked directive says product code runs natively on the customer's
# Mac. The wiki and Oxigraph do not -- they are containers, and the v1.0.42
# walk proved that is load-bearing rather than incidental:
#
#     :8000 daemon      200   NATIVE   alive
#     :8089 ical-server 302   NATIVE   alive
#     :8044 wiki        000   DOCKER   dead
#     :7878 Oxigraph    000   DOCKER   dead
#
# A ragged zero splitting exactly on the architectural seam. Andy accepted
# that we keep containers for v1.0 and OWN the engine's lifecycle, with
# retiring the dependency filed post-launch. He asked whether we could write
# something to absolve us if a customer disrupts what we install.
#
# The honest answer, and the one implemented here: a disclaimer does not do
# that job. EVIDENCE does. This file records what was on the box BEFORE we
# touched it and what we put there, so a health card can say the true thing --
#
#     "Colima: installed by Ostler, currently stopped"      (ours to fix)
#     "Docker Desktop: was already here, not managed by us" (theirs to fix)
#
# -- rather than an unfalsifiable "unsupported configuration".
#
# 🔴 AND THE LIMIT, STATED HERE SO NOBODY LEANS ON IT: this would NOT have
# covered 2026-08-23. Nobody touched that Mac. Our own unbounded stdout buffer
# drove macOS into jetsam, jetsam killed the 4 GB Colima VM, and our recovery
# path only ran at daemon startup so it never fired. No provenance record and
# no clause covers a defect of ours killing a dependency of ours. This file
# narrows what we must apologise for; it does not narrow what we must fix.
#
# ── DESIGN CONSTRAINTS ────────────────────────────────────────────────────
#
#   · bash 3.2. macOS ships 3.2 and always will -- no associative arrays.
#   · no jq. It is not present on a fresh customer Mac at the point this runs.
#   · NEVER claim we installed something we did not. The whole value is that
#     the record can be trusted when it says "not ours", so every entry is
#     derived from a before/after diff, never asserted.
#   · absent != stopped. This records PRESENCE, not liveness. Liveness is the
#     engine classifier's job and conflating them is how we got here.

# Runtimes we recognise. Order is not significance -- all four are equal, and
# the walk found a guard that knew only two of them, which is precisely how a
# customer running OrbStack gets a second engine installed over the top.
_OSTLER_ENGINE_RUNTIMES="colima orbstack podman"

# Docker Desktop's location, overridable ONLY so this function can be tested.
# It was a hardcoded absolute path first, and that made the module untestable:
# the developer's own /Applications/Docker.app leaked into every "no engine"
# case and the harness silently measured this Mac instead of the scenario. The
# test control caught it. A probe you cannot point somewhere else is a probe
# you cannot prove, and in production nothing sets this.
_OSTLER_DOCKER_DESKTOP="${_OSTLER_DOCKER_DESKTOP:-/Applications/Docker.app}"

# Emit a space-separated list of engines currently present on this box.
# Docker Desktop is an app bundle, not a binary on PATH, so it is probed
# separately -- a `command -v` sweep alone cannot see it.
ostler_engines_present() {
    local found="" rt
    for rt in $_OSTLER_ENGINE_RUNTIMES; do
        command -v "$rt" >/dev/null 2>&1 && found="${found}${rt} "
    done
    [[ -d "$_OSTLER_DOCKER_DESKTOP" ]] && found="${found}docker-desktop "
    # The CLIENT is recorded but never counted as an engine. It is here
    # because its presence WITHOUT an engine is the exact state that fooled
    # the installer on the walk box, and a support engineer wants to see it.
    printf '%s' "${found% }"
}

# Snapshot the pre-existing state. MUST be called before any brew install.
# Writes a marker we can diff against later; if it is missing at `after` time
# we say so rather than guessing, because a guess here is worse than a gap.
ostler_engine_provenance_before() {
    local dir="${1:?provenance dir required}"
    mkdir -p "$dir" 2>/dev/null || return 0
    {
        printf 'schema=1\n'
        printf 'phase=before\n'
        printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf 'engines=%s\n' "$(ostler_engines_present)"
        printf 'client_docker=%s\n' \
            "$(command -v docker >/dev/null 2>&1 && echo present || echo absent)"
    } > "${dir}/.engine-before" 2>/dev/null || return 0
}

# Write the durable record. Diffs against the `before` snapshot to derive --
# never assert -- what Ostler added.
#
# owner semantics, and they are the whole point:
#   customer  an engine was already here. We did not install it, we do not
#             manage it, and if it goes away that is theirs. We still SAY SO
#             clearly rather than failing silently.
#   ostler    the box had no engine and we installed one. Ours to keep alive,
#             ours to apologise for.
#   none      no engine before, none after. The install could not provide one.
ostler_engine_provenance_after() {
    local dir="${1:?provenance dir required}"
    local out="${dir}/container-engine.json"
    mkdir -p "$dir" 2>/dev/null || return 0

    local before_engines="" before_seen=false
    if [[ -r "${dir}/.engine-before" ]]; then
        before_seen=true
        before_engines="$(sed -n 's/^engines=//p' "${dir}/.engine-before")"
    fi
    local now_engines; now_engines="$(ostler_engines_present)"

    # Derived, not asserted: anything present now and absent before is ours.
    #
    # 🔴 THE `before_seen` GUARD IS LOAD-BEARING AND ITS ABSENCE WAS A REAL BUG,
    # caught by this module's own test. Without it, a missing snapshot makes
    # `before_engines` empty, the diff below concludes EVERY engine on the box
    # was added by us, and we claim a customer's own Docker Desktop as ours --
    # on precisely the upgrade path where the snapshot does not exist because
    # the prior install predates this file. An empty diff with owner=unknown is
    # the honest output: no evidence, therefore no claim.
    local added="" e f seen
    if [[ "$before_seen" == true ]]; then
        for e in $now_engines; do
            seen=false
            for f in $before_engines; do [[ "$e" == "$f" ]] && seen=true; done
            [[ "$seen" == false ]] && added="${added}${e} "
        done
    fi
    added="${added% }"

    local owner
    if [[ "$before_seen" == false ]]; then
        # No snapshot. Do not guess -- an unknown owner is honest and a wrong
        # one gets quoted back at us by a customer holding a broken wiki.
        owner="unknown"
    elif [[ -n "$before_engines" ]]; then
        owner="customer"
    elif [[ -n "$now_engines" ]]; then
        owner="ostler"
    else
        owner="none"
    fi

    _ospv_json_list() {  # bash 3.2, no jq: quote a space-separated list
        local first=true item
        printf '['
        for item in $1; do
            [[ "$first" == true ]] || printf ', '
            printf '"%s"' "$item"; first=false
        done
        printf ']'
    }

    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "recorded_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '  "owner": "%s",\n' "$owner"
        printf '  "engines_before": %s,\n'  "$(_ospv_json_list "$before_engines")"
        printf '  "engines_after": %s,\n'   "$(_ospv_json_list "$now_engines")"
        printf '  "installed_by_ostler": %s,\n' "$(_ospv_json_list "$added")"
        printf '  "client_docker": "%s",\n' \
            "$(command -v docker >/dev/null 2>&1 && echo present || echo absent)"
        printf '  "note": "PRESENCE only. Whether an engine is RUNNING is a separate question and a separate probe."\n'
        printf '}\n'
    } > "$out" 2>/dev/null || return 0
    chmod 644 "$out" 2>/dev/null || true
}
