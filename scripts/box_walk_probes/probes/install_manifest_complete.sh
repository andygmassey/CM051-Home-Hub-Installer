#!/usr/bin/env bash
# probes/install_manifest_complete.sh
# ============================================================================
# QUESTION: does the finished install CONTAIN everything a finished install is
#           declared to contain -- every required LaunchAgent, cron job,
#           artefact directory and vector collection on the roster -- and does it contain nothing that
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
    [ -r "$VERIFIER" ] || probe_cannot_run "verifier not readable at ${VERIFIER}"
    [ -r "$MANIFEST" ] || probe_cannot_run "manifest not readable at ${MANIFEST}"

    # ── REMOTE WALKS ARE MEASURED, NOT REFUSED ───────────────────────────
    #
    # This probe used to CANNOT-RUN whenever OSTLER_BOX_HOST was set, on the
    # correct observation that the verifier reads the TARGET's filesystem
    # (~/Library/LaunchAgents, the live config) and so cannot be run from here.
    # The conclusion drawn from it was wrong: "I cannot run where I am" is not
    # a reason to give up, it is a reason to run somewhere else.
    #
    # WHAT THAT COST, MEASURED. install_manifest_complete returned CANNOT-RUN
    # on v1.0.50, .51, .52, .61 and .63 -- every recorded walk -- because every
    # walk is driven remotely. Five cuts shipped with this gate never once
    # adjudicating, and alongside it ingest_coverage was CANNOT-RUN for four
    # cuts while five sources were failing behind it. A gate that has never
    # returned a verdict is indistinguishable from no gate, and the walk
    # summary counted it as "not measured" in a column nobody read.
    #
    # THE VERIFIER IS SELF-CONTAINED, so it can simply be carried to the
    # subject. Both files go over the existing ssh transport, are written to a
    # temp dir on the box, run there against the box's OWN $HOME, and are
    # removed. The exit code comes back over ssh unchanged, so the three-state
    # contract below is preserved exactly.
    #
    # DECODED WITH python3, NOT `base64 -d`. macOS shipped `base64` with -D and
    # without -d for years; picking the wrong one prints a usage error to
    # stderr and writes an EMPTY file, and an empty verifier "runs" and finds
    # nothing -- a false zero wearing the shape of a clean install. python3 is
    # already a hard requirement two lines below, so it costs nothing and
    # cannot differ between hosts.
    local out rc _payload
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        box_reachable || probe_cannot_run "OSTLER_BOX_HOST is set (${OSTLER_BOX_HOST}) but the box did not answer; a gate that cannot reach its subject has not passed"
        command -v python3 >/dev/null 2>&1 || probe_cannot_run "python3 not on PATH here; needed to encode the verifier for transport"
        _payload="$(python3 - "$VERIFIER" "$MANIFEST" <<'ENCODE'
import base64, sys
print(base64.b64encode(open(sys.argv[1], "rb").read()).decode())
print(base64.b64encode(open(sys.argv[2], "rb").read()).decode())
ENCODE
)" || probe_cannot_run "could not encode the verifier and manifest for transport"
        local _v64 _m64
        _v64="$(printf '%s\n' "$_payload" | sed -n 1p)"
        _m64="$(printf '%s\n' "$_payload" | sed -n 2p)"
        [ -n "$_v64" ] && [ -n "$_m64" ] || probe_cannot_run "encoded payload was empty; refusing to run a verifier that may be a zero-byte file"

        probe_examined 1 "scripts/verify_install_manifest.py carried to ${OSTLER_BOX_HOST} and run against ITS \$HOME"
        out="$(box_run_v "
d=\$(mktemp -d) || exit 2
printf '%s' '${_v64}' | python3 -c 'import sys,base64;open(sys.argv[1],\"wb\").write(base64.b64decode(sys.stdin.read()))' \"\$d/v.py\" || { rm -rf \"\$d\"; exit 2; }
printf '%s' '${_m64}' | python3 -c 'import sys,base64;open(sys.argv[1],\"wb\").write(base64.b64decode(sys.stdin.read()))' \"\$d/m.tsv\" || { rm -rf \"\$d\"; exit 2; }
[ -s \"\$d/v.py\" ] && [ -s \"\$d/m.tsv\" ] || { rm -rf \"\$d\"; exit 2; }
# 🔴 PICK AN INTERPRETER THAT CAN PARSE TOML, AND SAY WHICH ONE.
# The verifier reads the assistant config with tomllib (3.11+). The BOX's
# system python3 is 3.9.6 and has none, while the install ships 3.11.15 at
# ~/.ostler/python/bin/python3. Running under the system one turns the cron
# arm into CANNOT-RUN for a reason that has nothing to do with the install.
# Measured 2026-09-05 on archie@.240: system 3.9.6 tomllib=no, bundled
# 3.11.15 tomllib=yes.
_py=\"\"
for _c in \"\$HOME/.ostler/python/bin/python3\" \"\$HOME/.ostler/.venv/bin/python3\" python3; do
    command -v \"\$_c\" >/dev/null 2>&1 || [ -x \"\$_c\" ] || continue
    if \"\$_c\" -c 'import tomllib' >/dev/null 2>&1; then _py=\"\$_c\"; break; fi
done
[ -n \"\$_py\" ] || _py=python3
echo \"#PROBE_INTERPRETER \$_py (\$(\"\$_py\" -V 2>&1))\" >&2
\"\$_py\" \"\$d/v.py\" --manifest \"\$d/m.tsv\" --home \"\$HOME\" --exclude-type import_wire
_rc=\$?
rm -rf \"\$d\"
exit \$_rc
")"
        rc=$?
    else
        command -v python3 >/dev/null 2>&1 || probe_cannot_run "python3 not on PATH; the manifest verifier needs it"
        probe_examined 1 "scripts/verify_install_manifest.py against \$HOME on this box"
        # Same interpreter choice as the remote arm above, and for the same
        # reason: the cron arm needs tomllib, which arrived in 3.11.
        _py=""
        for _c in "$HOME/.ostler/python/bin/python3" "$HOME/.ostler/.venv/bin/python3" python3; do
            if "$_c" -c 'import tomllib' >/dev/null 2>&1; then _py="$_c"; break; fi
        done
        [ -n "$_py" ] || _py=python3
        probe_examined 1 "interpreter chosen for the verifier: ${_py} ($("$_py" -V 2>&1))"
        out="$("$_py" "$VERIFIER" --manifest "$MANIFEST" --home "$HOME" --exclude-type import_wire 2>&1)"
        rc=$?
    fi

    # BOX-OBSERVABLE types only. import_wire is a property of the SOURCE tree
    # (does a write path import the kinship guard), not of the installed artefact
    # on this box, so it is checked in CI (install-manifest-gate.yml) and excluded
    # here. This probe adjudicates launch_agent, cron_job, artefact_dir and
    # qdrant_collection -- the things a finished install actually exposes.
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
    probe_examined 4 "synthetic installs missing/adding one declared subject (negative control)"

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

    # CASE 4: a required qdrant collection missing -> must FAIL and NAME it. The
    # store is injected via the test seam so the control needs no live Qdrant.
    out="$(OSTLER_MANIFEST_QDRANT_OVERRIDE="people,preferences" python3 "$VERIFIER" --manifest "$MANIFEST" --home "$work" --config "$cfg" --only-type qdrant_collection 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q 'conversations' <<< "$out"; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a missing required qdrant collection (conversations) was not named. #615 absence would ship silently."
    fi

    probe_fail "negative control behaved correctly on all 4 cases (missing agent, undeclared agent, missing cron and missing qdrant collection each named)"
}

probe_main "$@"
