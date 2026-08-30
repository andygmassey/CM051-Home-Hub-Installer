#!/usr/bin/env bash
# scripts/box_walk_probes/probes/launchagents_resolve_their_tools.sh
# ============================================================================
# CAN THE AGENTS THAT SHELL OUT TO HOMEBREW TOOLING ACTUALLY FIND IT?
#
# THE DEFECT, measured on the Mini 2026-08-20 after a real power cycle:
#
#   colima FATA: exec "limactl": executable file not found in $PATH
#
# launchd hands its jobs a minimal PATH -- /usr/bin:/bin:/usr/sbin:/sbin --
# unless the plist sets EnvironmentVariables:PATH. Homebrew is not in it. The
# assistant daemon is the correct owner of `colima start` (an FDA-less
# LaunchAgent cannot mount ~/Documents, which is why a bare colima agent is
# asserted AGAINST in tests/test_colima_autostart_mechanism.sh) -- but its
# plist sets six environment keys and PATH is not one of them.
#
# So the VM never boots, and Qdrant, Oxigraph, Redis, Vane, wiki-site and
# store-proxy are all gone until someone starts Colima by hand. Recovery
# proved the chain is exactly one link: with the Homebrew prefix on PATH,
# Colima came up in 75s and all six containers returned by themselves.
#
# WHY THIS IS A CLASS AND NOT A PLIST
#
#   24 ostler LaunchAgents on the box
#    6 carry a Homebrew-aware PATH
#   18 do not, and BOTH agents that broke that day are in the 18
#
# install.sh hard-codes `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin` in
# three plist templates and omits it everywhere else. The technique is known,
# used six times, omitted eighteen. Nothing decides, so each agent is correct
# or broken by accident.
#
# WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
#
# It asserts a DECLARED set: the agents we KNOW shell out to Homebrew-installed
# tooling must carry a PATH that can reach it. Each entry carries its reason
# below, because a required-list with no justification rots into a list nobody
# dares change.
#
# It does NOT assert all 24. Some are genuinely fine on /usr/bin -- stay-awake
# runs caffeinate. Failing 18 on day one produces a probe everyone ignores,
# which is worse than no probe. The rest are COUNTED and PRINTED so the number
# cannot quietly grow, but they do not fail the run.
#
# IT READS ONE KEY, NEVER THE DICT. These plists carry a service token and the
# owner's phone number and email in other EnvironmentVariables keys. This probe
# asks PlistBuddy for :EnvironmentVariables:PATH specifically and prints only
# whether the Homebrew prefix appears in it -- never the value, never the dict.
# `Print :EnvironmentVariables` on this box dumps a live secret to stdout.
# ============================================================================

set -uo pipefail

PROBE_NAME="launchagents_resolve_their_tools"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/probe.sh
. "${HERE}/../lib/probe.sh"

# The declared set, each with the reason it needs Homebrew on PATH.
#   assistant  -- owns `colima start`; colima resolves limactl through PATH
#   fda-rerun  -- runs the recurring FDA tick and its python toolchain
REQUIRED_AGENTS="com.creativemachines.ostler.assistant com.ostler.fda-rerun"

HOMEBREW_MARK="/opt/homebrew"

# ---------------------------------------------------------------------------
# THE BODY, factored so the negative control drives the SAME code.
#   path_has_homebrew <plist>  -> echoes YES | NO-PATH | NO-HOMEBREW
# Reads ONE key. Never the dict.
# ---------------------------------------------------------------------------
path_has_homebrew() {
    _ph_v="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PATH" "$1" 2>/dev/null)"
    if [ -z "$_ph_v" ]; then
        echo "NO-PATH"
        return 0
    fi
    case "$_ph_v" in
        *"$HOMEBREW_MARK"*) echo "YES" ;;
        *)                  echo "NO-HOMEBREW" ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box at '${OSTLER_BOX_HOST}' did not answer over ssh, so no plist could be read. Not a pass."
    fi

    # 🔴 $HOME MUST EXPAND ON THE BOX, NOT HERE. This line used to read
    #     _dir="$HOME/Library/LaunchAgents"
    # in plain double quotes, so it expanded in the CONTROLLER's shell and the
    # probe then listed the OPERATOR'S OWN LaunchAgents directory over ssh.
    #
    # MEASURED 2026-08-30, first ssh-driven walk (archie3@the Studio):
    #     "no *ostler*.plist under /Users/andy/Library/LaunchAgents"
    # -- /Users/andy, while the box account is archie3. A PASS on 18 plists
    # became a false CANNOT-RUN, and the record recorded coverage lost that was
    # never lost. It was invisible for as long as the walk ran LOCALLY on the
    # box, because there the two homes are the same directory.
    #
    # SAME CLASS AS #1284's -K path: a value expanded on the wrong side of the
    # transport. Classified across the suite the same day: 11 probes mention
    # $HOME, 4 hand it to a remote command, and 3 of those 4 already escape it
    # (`\$HOME`) or single-quote it, so they were always correct. This was the
    # only genuine instance -- but a mention count would have said 11.
    #
    # Resolve ONCE on the box and use the absolute result everywhere, so the
    # operator-facing message names the directory that was really examined.
    _dir="$(box_run 'printf "%s" "$HOME/Library/LaunchAgents"')"
    if [ -z "$_dir" ]; then
        probe_cannot_run "could not resolve \$HOME on the box, so no LaunchAgents directory could be named -- nothing was examined and this is not a pass."
    fi
    case "$_dir" in
        /*) : ;;
        *)  probe_cannot_run "the box resolved its LaunchAgents directory to '${_dir}', which is not an absolute path. Refusing to list it rather than examine an unknown location." ;;
    esac

    _listing="$(box_run "ls ${_dir}/*ostler*.plist 2>/dev/null")"
    if [ -z "$_listing" ]; then
        probe_cannot_run "no *ostler*.plist under ${_dir} on the box. Nothing was examined, which is not the same as nothing being wrong."
    fi

    _total=0; _with=0; _req_bad=""; _other_bad=""
    for _p in $_listing; do
        _total=$((_total + 1))
        _label="$(basename "$_p" .plist)"
        _v="$(box_run "/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' '${_p}' 2>/dev/null")"
        case "$_v" in
            *"$HOMEBREW_MARK"*) _with=$((_with + 1)); continue ;;
        esac
        # No Homebrew on this one. Required, or merely counted?
        case " $REQUIRED_AGENTS " in
            *" $_label "*) _req_bad="${_req_bad} ${_label}" ;;
            *)             _other_bad="${_other_bad} ${_label}" ;;
        esac
    done

    probe_examined "$_total" "ostler LaunchAgent plist(s), reading EnvironmentVariables:PATH only"
    probe_note "with a Homebrew-aware PATH: ${_with} of ${_total}"

    if [ -n "$_other_bad" ]; then
        probe_note "no Homebrew PATH, NOT in the required set (counted, not failed):"
        for _o in $_other_bad; do probe_note "    ${_o}"; done
    fi

    if [ -n "$_req_bad" ]; then
        probe_note "REQUIRED and missing:"
        for _r in $_req_bad; do probe_note "    ${_r}"; done
        probe_fail "agent(s) that shell out to Homebrew tooling have no Homebrew prefix on PATH:${_req_bad}. launchd gives /usr/bin:/bin:/usr/sbin:/sbin, so colima cannot resolve limactl and the container stack does not survive a reboot."
    fi
    probe_pass "all $(printf '%s' "$REQUIRED_AGENTS" | wc -w | tr -d ' ') required agent(s) carry a Homebrew-aware PATH; ${_with} of ${_total} agents overall"
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Must come back FAIL, per the probe contract.
# Synthetic plists in a temp dir so it is deterministic with or without a box.
# Both directions: a checker stuck on "missing" would satisfy a one-sided
# control while being useless.
# ---------------------------------------------------------------------------
self_test() {
    _st_d="$(mktemp -d)"
    trap 'rm -rf "$_st_d"' EXIT

    _mk() { # _mk <file> <path-value-or-empty>
        {
            printf '<?xml version="1.0" encoding="UTF-8"?>\n'
            printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            printf '<plist version="1.0"><dict>\n'
            printf '  <key>Label</key><string>synthetic</string>\n'
            printf '  <key>EnvironmentVariables</key><dict>\n'
            printf '    <key>SOME_OTHER_KEY</key><string>irrelevant</string>\n'
            [ -n "$2" ] && printf '    <key>PATH</key><string>%s</string>\n' "$2"
            printf '  </dict>\n</dict></plist>\n'
        } > "$1"
    }

    _mk "$_st_d/good.plist"    "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    _mk "$_st_d/nopath.plist"  ""
    _mk "$_st_d/nobrew.plist"  "/usr/bin:/bin:/usr/sbin:/sbin"

    if [ "$(path_has_homebrew "$_st_d/good.plist")" != "YES" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a plist WITH the Homebrew prefix read as missing. This probe would red every correct agent."
    fi
    if [ "$(path_has_homebrew "$_st_d/nopath.plist")" != "NO-PATH" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a plist with NO PATH key was not reported as missing. That is the exact shape of com.ostler.fda-rerun."
    fi
    # The one most likely to be got wrong: a PATH exists but has no Homebrew.
    # An 'is the key present' check passes this and misses the defect.
    if [ "$(path_has_homebrew "$_st_d/nobrew.plist")" != "NO-HOMEBREW" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a PATH that exists but omits the Homebrew prefix read as acceptable. Presence of the key is not the assertion; reachability of the tooling is."
    fi

    probe_examined 3 "synthetic plists (negative control)"
    probe_fail "negative control behaved correctly on 3 plists (Homebrew present passes; no PATH key and a PATH without Homebrew both fail)"
}

probe_main "$@"
