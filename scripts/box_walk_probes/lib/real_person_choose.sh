#!/usr/bin/env bash
# scripts/box_walk_probes/lib/real_person_choose.sh
# DMG #23. hub_screens_render_for_a_customer's assertion "chat: a real person's
# compiled page renders with their name" was NOT MEASURED on every full walk,
# because HUB_SCREENS_REAL_PERSON was set by an operator's shell on one walk and
# by nothing else. The runner owns it now (same class as OSTLER_SCREENS_ALLOW_WRITE).
#
# real_person_choose, called by run_box_walk.sh just before the first
# hub_screens_render* probe, reads the box's people API and its compiled wiki
# People pages over the same ssh/loopback path the probes use, and exports:
#   HUB_SCREENS_REAL_PERSON         the name (ENV ONLY; never printed, never logged)
#   HUB_SCREENS_REAL_PERSON_STATE   chosen | operator | cannot-run
#   HUB_SCREENS_REAL_PERSON_DETAIL  why, with counts (carries no name)
# Waits up to OSTLER_REAL_PERSON_BUDGET_S (default 600) for pages to exist. None
# found is cannot-run naming what was examined; never a pass.
# PRIVACY (binding): a real person's name. The log gets sha256(name)[:8] and the
# page path depth, nothing else.

_rpc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_rpc_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes \
            -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$OSTLER_BOX_HOST" "$1" 2>/dev/null
    else
        bash -lc "$1" 2>/dev/null
    fi
}

_rpc_box_raw() {  # like _rpc_box, but stderr reaches the caller
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes \
            -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

_rpc_fp() {  # sha256(name)[:8], from stdin-free arg via python so no name is on a command line
    HUB_RPC_N="$1" /usr/bin/python3 -c 'import hashlib,os;print(hashlib.sha256(os.environ["HUB_RPC_N"].encode()).hexdigest()[:8])'
}

real_person_choose() {
    export HUB_SCREENS_REAL_PERSON_STATE="cannot-run" HUB_SCREENS_REAL_PERSON_DETAIL=""
    if [ -n "${HUB_SCREENS_REAL_PERSON:-}" ]; then
        HUB_SCREENS_REAL_PERSON_STATE="operator"
        HUB_SCREENS_REAL_PERSON_DETAIL="operator-supplied"
        printf '  real person: operator-supplied, id=%s (name withheld)\n' "$(_rpc_fp "$HUB_SCREENS_REAL_PERSON")"
        export HUB_SCREENS_REAL_PERSON HUB_SCREENS_REAL_PERSON_STATE HUB_SCREENS_REAL_PERSON_DETAIL
        return 0
    fi
    local d budget step t0 now out state name depth seeds rc examined prc perr
    d="$(mktemp -d)" || { HUB_SCREENS_REAL_PERSON_DETAIL="no temp dir"; export HUB_SCREENS_REAL_PERSON_DETAIL; return 0; }
    chmod 700 "$d"
    budget="${OSTLER_REAL_PERSON_BUDGET_S:-600}"; step="${OSTLER_REAL_PERSON_STEP_S:-30}"
    t0="$(date +%s)"
    # The synthetic people this walk seeded: the grounding seed's person.
    printf '%s\n' "${OSTLER_GATE_KNOWN_PERSON:-}" > "$d/seed"
    examined="nothing read yet"
    while :; do
        # The token is read and used ON THE BOX; it never reaches this shell.
        _rpc_box 'curl -s --noproxy "*" --max-time 60 -H "Authorization: Bearer $(cat $HOME/.ostler/secrets/zeroclaw_admin_token)" "http://127.0.0.1:8000/api/v1/people?sort=recency"' > "$d/people" || : > "$d/people"
        # No manufactured empty input: a failed listing is CANNOT-RUN naming the error.
        _rpc_box_raw 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; docker exec ostler-wiki-site sh -c "cd /docs/docs/People && find . -name \"*.md\" -exec wc -c {} +"' > "$d/pages" 2> "$d/pages.err"
        prc=$?
        if [ "$prc" -ne 0 ]; then
            perr="$(head -c 200 "$d/pages.err" | tr '\n' ' ')"
            examined="wiki listing failed rc=${prc}: ${perr:-no stderr}"
            now="$(date +%s)"
            [ $((now - t0)) -ge "$budget" ] && break
            sleep "$step"; continue
        fi
        _rpc_box 'sed -n "s/^[[:space:]]*user_first_name[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p" $HOME/.ostler/assistant-config/config.toml | head -n 1' > "$d/owner" || : > "$d/owner"
        out="$(/usr/bin/python3 "$_rpc_dir/real_person_pick.py" --people "$d/people" --pages "$d/pages" --owner "$d/owner" --seed "$d/seed")"
        rc=$?
        state="$(printf '%s\n' "$out" | sed -n 's/^STATE //p')"
        examined="$(printf '%s\n' "$out" | sed -n 's/^EXAMINED //p')"
        if [ "$rc" -eq 0 ] && [ "$state" = "chosen" ]; then
            name="$(printf '%s\n' "$out" | sed -n 's/^NAME //p')"
            depth="$(printf '%s\n' "$out" | sed -n 's/^DEPTH //p')"
            rm -rf "$d"
            HUB_SCREENS_REAL_PERSON="$name"
            HUB_SCREENS_REAL_PERSON_STATE="chosen"
            HUB_SCREENS_REAL_PERSON_DETAIL="chosen from: ${examined}"
            export HUB_SCREENS_REAL_PERSON HUB_SCREENS_REAL_PERSON_STATE HUB_SCREENS_REAL_PERSON_DETAIL
            printf '  real person: chosen id=%s page_path_depth=%s (name withheld); examined %s\n' "$(_rpc_fp "$name")" "$depth" "$examined"
            return 0
        fi
        now="$(date +%s)"
        [ $((now - t0)) -ge "$budget" ] && break
        sleep "$step"
    done
    rm -rf "$d"
    unset HUB_SCREENS_REAL_PERSON
    HUB_SCREENS_REAL_PERSON_DETAIL="no real person with a compiled page after ${budget}s; examined ${examined:-nothing}"
    export HUB_SCREENS_REAL_PERSON_STATE HUB_SCREENS_REAL_PERSON_DETAIL
    printf '  real person: CANNOT-RUN, %s\n' "$HUB_SCREENS_REAL_PERSON_DETAIL"
    return 0
}
