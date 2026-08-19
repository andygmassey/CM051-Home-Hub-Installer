#!/usr/bin/env bash
# probes/launchd_no_ephemeral_paths.sh
# ============================================================================
# QUESTION: does any installed LaunchAgent EXECUTE from a path under /tmp or a
#           mktemp staging directory?
#
# WHY IT MATTERS. Task #177: the ollama-logrotate LaunchAgent shipped with a
# /tmp/ostler-prelaunch-XXXX/ path baked in, because install.sh rendered the
# template while still running out of its own staging directory. Everything
# works. The agent runs, the box looks perfect. Then macOS clears /tmp, or the
# customer reboots, and the agent silently stops existing.
#
# THE FAILURE MODE IS INVISIBLE AT INSTALL TIME AND FATAL A WEEK LATER. Nothing
# in the install log mentions it. That is precisely the shape a probe should
# own and a human box walk cannot.
#
# ---------------------------------------------------------------------------
# WHY THIS PARSES THE PLIST INSTEAD OF GREPPING IT
#
# The first version grepped raw XML, and on its first real run against the
# v1.0.31 box it reported:
#
#     FAIL -- 1 of 20 LaunchAgent plists reference an ephemeral path
#     com.creativemachines.ostler.whatsapp-keepalive.plist: /tmp/
#
# That was WRONG. The match sat inside an XML comment -- a citation of a
# diagnosis document, "See defib /tmp/tnm_brief_..._2026-05-02.md". Parsing the
# same file properly returns ZERO functional ephemeral paths: the agent runs
# from ~/.ostler/OstlerAssistant.app and logs to ~/.ostler/logs.
#
# A grep over raw XML measures PROSE. The defect lives in EXECUTABLE VALUES.
# Those are different surfaces, and a gate whose surface differs from its
# defect's is wrong in both directions -- it can miss a real path hidden in an
# unexpected key, and it can flag a harmless comment forever.
#
# So this reads the plist with plistlib and inspects only the keys macOS
# actually executes or writes to. A comment may now say whatever it likes.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="launchd_no_ephemeral_paths"
PROBE_QUESTION="does any installed LaunchAgent execute from /tmp or a mktemp staging dir?"

AGENT_DIR="${OSTLER_LAUNCHAGENT_DIR:-\$HOME/Library/LaunchAgents}"

# Sent to whichever machine holds the plists. Prints one HIT/UNPARSEABLE line
# per offending file, then "TOTAL <n>" so the caller takes its denominator from
# the same pass that produced the verdict rather than a second, separate count.
#
# ---------------------------------------------------------------------------
# AND WHY IT SHELLS OUT TO plutil RATHER THAN USING plistlib
#
# The plistlib version then failed 8 of 20 agents on the same box with
# "not well-formed (invalid token)". Also wrong. Those plists carry `--` inside
# XML comments, which the XML spec forbids and Python's strict parser rejects.
# Apple's parser tolerates it: `plutil -lint` returns OK, and `launchctl list`
# shows the agents loaded and running with live PIDs.
#
# LAUNCHD DECIDES WHETHER AN AGENT RUNS, SO LAUNCHD IS THE AUTHORITY. A probe
# that uses a stricter parser than the thing it models reports defects that do
# not exist, which costs exactly as much trust as missing ones. So this shells
# out to plutil -- the same parser macOS itself uses -- and reads its JSON.
# ---------------------------------------------------------------------------
_ANALYSER='
import glob, json, os, subprocess, sys

# Only keys launchd actually resolves as paths. Everything else in the file --
# comments, labels, human notes -- is prose and must not be scanned.
PATH_KEYS = ("Program", "WorkingDirectory", "StandardOutPath",
             "StandardErrorPath", "RootDirectory")
EPHEMERAL = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")

def offending(value):
    out = []
    if isinstance(value, str):
        if value.startswith(EPHEMERAL):
            out.append(value)
    elif isinstance(value, list):
        for v in value:
            out.extend(offending(v))
    elif isinstance(value, dict):
        for v in value.values():
            out.extend(offending(v))
    return out

files = sorted(glob.glob(os.path.join(sys.argv[1], "*.plist")))
total = 0
for f in files:
    total += 1
    try:
        # plutil is macOS own parser -- the same one launchd uses. Anything it
        # accepts, launchd accepts, which is the only definition of "valid"
        # that matters here.
        raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", f],
                             capture_output=True, check=True).stdout
        doc = json.loads(raw)
    except Exception as e:
        # An unparseable plist is NOT a clean plist. Say so out loud rather
        # than letting it slip through the loop as an implicit pass. But note
        # this now means plutil itself refused, which launchd would too.
        print("UNPARSEABLE %s: %s" % (f, e))
        continue
    hits = []
    for k in PATH_KEYS:
        if k in doc:
            hits.extend(offending(doc[k]))
    hits.extend(offending(doc.get("ProgramArguments", [])))
    if hits:
        print("HIT %s: %s" % (f, ", ".join(sorted(set(hits)))))
print("TOTAL %d" % total)
'

analyse_dir() {
    local dir="$1"
    if [ "${SELF_TEST_LOCAL:-0}" -eq 0 ]; then
        box_run "python3 -c '$_ANALYSER' \"$dir\""
    else
        python3 -c "$_ANALYSER" "$dir"
    fi
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; no plists inspected"
    fi

    local out total
    out="$(analyse_dir "$AGENT_DIR")"
    total="$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p')"
    total="${total:-0}"

    # Zero is NOT a pass. An installed Hub always has several agents. Zero
    # means a wrong path, an unreadable directory, or a python3 that never
    # ran -- all "did not look", not "found nothing".
    if [ "$total" -eq 0 ]; then
        probe_examined 0 "LaunchAgent plists"
        probe_cannot_run "found 0 plists in $AGENT_DIR -- an installed Hub always has several, so this is a bad path, an unreadable dir, or a missing python3, not a clean box"
    fi

    probe_examined "$total" "LaunchAgent plists in $AGENT_DIR (parsed, not grepped)"

    local unparseable hits
    unparseable="$(printf '%s\n' "$out" | grep -c '^UNPARSEABLE ' || true)"
    hits="$(printf '%s\n' "$out" | grep '^HIT ' || true)"

    if [ "${unparseable:-0}" -gt 0 ]; then
        printf '%s\n' "$out" | grep '^UNPARSEABLE ' | while read -r l; do probe_note "$l"; done
        probe_fail "$unparseable of $total plists could not be parsed. An unreadable agent is not a clean agent, and this probe will not report a pass over files it could not open."
    fi

    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | while read -r l; do probe_note "$l"; done
        local n
        n="$(printf '%s\n' "$hits" | grep -c .)"
        probe_fail "$n of $total LaunchAgents execute from or write to an ephemeral path; these die when /tmp is cleared or the box reboots (task #177)"
    fi

    probe_pass "all $total LaunchAgents resolve to durable paths in every executable key"
}

self_test() {
    local fixture
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    SELF_TEST_LOCAL=1

    # 1. BAD: executes from /tmp. Must be caught.
    cat > "$fixture/com.ostler.bad.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.ostler.bad</string>
  <key>ProgramArguments</key><array>
    <string>/tmp/ostler-prelaunch-A1B2/rotate.sh</string>
  </array>
</dict></plist>
PLIST

    # 2. GOOD, AND THE REGRESSION CASE THAT MATTERS: a durable agent whose
    #    COMMENT mentions a /tmp path. This is the real whatsapp-keepalive
    #    shape the grep version flagged on the live box. It must pass.
    cat > "$fixture/com.ostler.good.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- See diagnosis at /tmp/some_brief_2026-05-02.md for background. -->
  <key>Label</key><string>com.ostler.good</string>
  <key>ProgramArguments</key><array>
    <string>/Users/example/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant</string>
    <string>channel</string><string>doctor</string>
  </array>
  <key>StandardOutPath</key><string>/Users/example/.ostler/logs/a.log</string>
</dict></plist>
PLIST

    local out total hits
    out="$(analyse_dir "$fixture")"
    total="$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p')"
    hits="$(printf '%s\n' "$out" | grep '^HIT ' || true)"
    probe_examined "${total:-0}" "fixture plists (negative control)"

    if [ "${total:-0}" -ne 2 ]; then
        probe_fail "negative control should hold 2 plists, counted ${total:-0} -- the counter is wrong, so no verdict from this probe is trustworthy"
    fi

    if ! printf '%s' "$hits" | grep -q 'com.ostler.bad'; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: missed an agent whose ProgramArguments is /tmp/ostler-prelaunch-A1B2/rotate.sh. This probe cannot detect task #177."
    fi

    if printf '%s' "$hits" | grep -q 'com.ostler.good'; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: flagged a durable agent because a COMMENT cites a /tmp path. This is the exact false positive the grep version produced against com.creativemachines.ostler.whatsapp-keepalive on the v1.0.31 box."
    fi

    probe_fail "negative control behaved correctly (caught the /tmp executable, ignored the /tmp mentioned only in a comment)"
}

probe_main "$@"
