#!/usr/bin/env bash
# probes/install_manifest_complete.sh
# ============================================================================
# QUESTION: does the finished install CONTAIN everything a finished install is
#           declared to contain -- every required LaunchAgent, cron job and
#           artefact directory on the roster -- and does it contain nothing that
#           the roster does not account for? (The import_wire type is a SOURCE
#           property, checked in CI, not on the box; see run_probe.)
#
# WHY THIS PROBE EXISTS, AND WHY IT IS NOT ANOTHER ONE-OFF.
# For a month the same shape shipped: a thing a finished install must contain
# was silently absent and nothing counted it -- an empty [[cron.jobs]] block
# (#619), a usage-journal dir never created (#482), a kinship guard with no
# importer on a write path (#617), a LaunchAgent roster nobody had written down.
# Each was found by a human noticing. This is the class gate for all of them:
# a DECLARED manifest (scripts/install_manifest.tsv, hand-authored and NOT
# derived from install.sh) compared to what is actually present, both directions,
# every difference NAMED. The adjudication is scripts/verify_install_manifest.py;
# this probe runs it against the box and maps its verdict onto the walk's four
# states.
#
# WHY IT NAMES rather than counts. "23 LaunchAgents present" passes regardless of
# WHICH 23, and the failure mode is a specific one going missing while the count
# stays plausible. The verifier prints the missing and the undeclared by name.
#
# WHERE IT RUNS. On the box's own filesystem: the LaunchAgent and cron
# enumerators read ~/Library/LaunchAgents and the live config under this $HOME.
# So this probe runs the verifier LOCALLY. A remote invocation
# (OSTLER_BOX_HOST set) is CANNOT-RUN here, not a pass: the gate must read the
# target's filesystem, so run the suite ON the box.
# ============================================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="install_manifest_complete"
PROBE_QUESTION="does the install contain everything the manifest declares, and nothing undeclared?"

# scripts/verify_install_manifest.py sits two levels up from probes/.
_REPO_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="${_REPO_SCRIPTS}/verify_install_manifest.py"
MANIFEST="${_REPO_SCRIPTS}/install_manifest.tsv"

run_probe() {
    probe_examined 1 "scripts/verify_install_manifest.py against \$HOME on this box"

    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        probe_cannot_run "OSTLER_BOX_HOST is set (${OSTLER_BOX_HOST}); the manifest gate reads the target's own filesystem (~/Library/LaunchAgents, the live config), so run the box walk ON the box, not remotely"
    fi
    command -v python3 >/dev/null 2>&1 || probe_cannot_run "python3 not on PATH; the manifest verifier needs it"
    [ -r "$VERIFIER" ] || probe_cannot_run "verifier not readable at ${VERIFIER}"
    [ -r "$MANIFEST" ] || probe_cannot_run "manifest not readable at ${MANIFEST}"

    # BOX-OBSERVABLE types only. import_wire is a property of the SOURCE tree
    # (does a write path import the kinship guard), not of the installed artefact
    # on this box, so it is checked in CI (install-manifest-gate.yml) and excluded
    # here. This probe adjudicates launch_agent, cron_job and artefact_dir -- the
    # things a finished install actually exposes.
    local out rc
    out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$HOME" --exclude-type import_wire 2>&1)"
    rc=$?

    case "$rc" in
        0) probe_pass "$(printf '%s' "$out" | grep -E '^(PASS|install-manifest)' | tr '\n' ' ')" ;;
        1) probe_fail "install is not complete/consistent -- $(printf '%s' "$out" | grep -E '^(FAIL|    -)' | tr '\n' ' | ')" ;;
        2) probe_cannot_run "$(printf '%s' "$out" | grep -i 'cannot-run' | head -1)" ;;
        *) probe_fail "verifier returned an unexpected exit code ${rc}: $(printf '%s' "$out" | head -1)" ;;
    esac
}

# NEGATIVE CONTROL. Drive the REAL verifier against synthetic installs that are
# known-bad by construction: one missing a required LaunchAgent, one carrying an
# undeclared one, one missing a required cron job. Each must come back FAIL and
# NAME the offending subject. Exits probe_fail (rc 1) when every case is judged
# correctly -- the healthy result the runner expects. A probe_pass (rc 0) here
# means a control did NOT fire and the gate is blind.
self_test() {
    probe_examined 3 "synthetic installs missing/adding one declared subject (negative control)"

    command -v python3 >/dev/null 2>&1 || probe_cannot_run "python3 not on PATH for the negative control"
    [ -r "$VERIFIER" ] || probe_cannot_run "verifier not readable for the negative control"

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/ostler-manifest-ctl-XXXXXX")" || probe_cannot_run "could not create a control work dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local la="$work/Library/LaunchAgents"
    mkdir -p "$la" "$work/.ostler/assistant-config"
    # A COMPLETE synthetic install: every REQUIRED (unconditional) launch_agent
    # present, so the only failure in each case below is the one it injects.
    local L
    for L in com.ostler.stay-awake com.ostler.engine-supervisor com.ostler.ollama com.ostler.ollama-logrotate com.ostler.enrich com.ostler.export-scan com.ostler.doctor com.ostler.ical-server com.ostler.fda-rerun com.creativemachines.ostler.assistant com.creativemachines.ostler.email-ingest com.creativemachines.ostler.wiki-recompile com.creativemachines.ostler.editor-frontpage; do
        printf '<plist><dict><key>Label</key><string>%s</string></dict></plist>\n' "$L" > "$la/$L.plist"
    done
    printf '[[cron.jobs]]\nid = "morning-brief"\n[[cron.jobs]]\nid = "evening-wrap"\n' > "$work/.ostler/assistant-config/config.toml"
    local cfg="$work/.ostler/assistant-config/config.toml"

    local out rc
    # CASE 1: remove a REQUIRED launch agent (doctor; colima is only conditional)
    # -> must FAIL and NAME it.
    rm -f "$la/com.ostler.doctor.plist"
    out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$work" --config "$cfg" --only-type launch_agent 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q 'com.ostler.doctor' <<< "$out"; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a missing required LaunchAgent (com.ostler.doctor) was not named as a failure. The gate is blind to absence."
    fi
    printf '<plist><dict><key>Label</key><string>com.ostler.doctor</string></dict></plist>\n' > "$la/com.ostler.doctor.plist"

    # CASE 2: add an undeclared launch agent -> must FAIL and NAME it.
    printf '<plist><dict><key>Label</key><string>com.ostler.mystery</string></dict></plist>\n' > "$la/com.ostler.mystery.plist"
    out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$work" --config "$cfg" --only-type launch_agent 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q 'com.ostler.mystery' <<< "$out"; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an undeclared LaunchAgent (com.ostler.mystery) was not named. The produced-but-not-declared direction is dead."
    fi
    rm -f "$la/com.ostler.mystery.plist"

    # CASE 3: drop a required cron job -> must FAIL and NAME it.
    printf '[[cron.jobs]]\nid = "morning-brief"\n' > "$cfg"
    out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$work" --config "$cfg" --only-type cron_job 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q 'evening-wrap' <<< "$out"; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a missing required cron job (evening-wrap) was not named. #619 would pass this gate."
    fi

    probe_fail "negative control behaved correctly on all 3 cases (missing agent, undeclared agent and missing cron each named)"
}

probe_main "$@"
