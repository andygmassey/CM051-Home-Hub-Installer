#!/usr/bin/env bash
# scripts/box_walk_probes/probes/care_rules_present_in_workspace_agents_md.sh
#
# Does the installed assistant workspace carry the care rules? install.sh runs
# care/write_agents_md.sh, which renders care/AGENTS_CARE.md.tmpl into
# ~/.ostler/assistant-config/workspace/AGENTS.md (ASSISTANT_WORKSPACE_DIR). The
# daemon reads that file, so a missing or half-rendered one means a customer in
# crisis gets no helpline.
#
# Read over the box transport (ssh when OSTLER_BOX_HOST is set). The box side
# prints a STATE line plus the two lines graded; the rest of the file never
# leaves the box. No database is opened.
#
#   PASS        file present, "# Care rules" heading present, helpline sentence
#               rendered (a real line or the generic ZZ line) with no
#               unresolved {{placeholder}}
#   FAIL        file missing, heading missing, or helpline sentence missing
#   CANNOT-RUN  transport failed, or the file exists and cannot be read
#
# Scope is set in scripts/walk_promote_scope.tsv (shipped row: BLOCKING; no row =
# blocking). The DMG capability row is owned elsewhere.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="care_rules_present_in_workspace_agents_md"
PROBE_QUESTION="does the assistant workspace AGENTS.md exist on the box, with the '# Care rules' heading and a rendered helpline sentence?"

# Box side. $HOME is expanded on the box, not here.
_BOX_READ='f="$HOME/.ostler/assistant-config/workspace/AGENTS.md"
if [ ! -e "$f" ]; then echo "STATE=missing"
elif [ ! -r "$f" ]; then echo "STATE=unreadable"
else
  echo "STATE=ok"
  if grep -qx "# Care rules" "$f"; then echo "HEADING=yes"; else echo "HEADING=no"; fi
  l="$(grep -m1 "Always include this, with the number exactly as written:" "$f")"
  if [ -n "$l" ]; then echo "HELPLINE_LINE=$l"; else echo "HELPLINE_LINE="; fi
fi'

# grade <capture>: prints one reason, returns 0 PASS, 1 FAIL, 78 CANNOT-RUN.
grade() {
    local cap="$1" state heading line tail
    state="$(sed -n 's/^STATE=//p' "$cap" | head -1)"
    case "$state" in
        missing)    echo "AGENTS.md is missing from the assistant workspace"; return 1 ;;
        unreadable) echo "AGENTS.md exists but could not be read"; return 78 ;;
        ok) ;;
        *)          echo "the box returned no STATE line (transport or shell failure)"; return 78 ;;
    esac
    heading="$(sed -n 's/^HEADING=//p' "$cap" | head -1)"
    [ "$heading" = "yes" ] || { echo "AGENTS.md has no '# Care rules' heading"; return 1; }
    line="$(sed -n 's/^HELPLINE_LINE=//p' "$cap" | head -1)"
    [ -n "$line" ] || { echo "AGENTS.md has no helpline sentence"; return 1; }
    case "$line" in *'{{'*) echo "helpline sentence has an unresolved placeholder"; return 1 ;; esac
    tail="${line#*exactly as written:}"
    tail="$(printf '%s' "$tail" | sed 's/If they are in immediate danger:.*//; s/[[:space:]]//g')"
    [ -n "$tail" ] || { echo "helpline sentence is empty"; return 1; }
    echo "AGENTS.md has the Care rules heading and a rendered helpline sentence"
    return 0
}

self_test() {
    local d cap; d="$(mktemp -d)"; cap="${d}/cap"
    printf 'STATE=missing\n' > "$cap"
    probe_examined 1 "canned captures"
    grade "$cap" >/dev/null; local rc=$?
    rm -rf "$d"
    [ "$rc" -eq 1 ] || probe_pass "SELF-TEST BROKEN: a missing file did not go red"
    probe_fail "negative control behaved: a missing AGENTS.md went red"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local cap reason rc; cap="$(mktemp)"
    box_run "$_BOX_READ" > "$cap"
    reason="$(grade "$cap")"; rc=$?
    rm -f "$cap"
    case "$rc" in
        0)  probe_examined 1 "workspace AGENTS.md"; probe_pass "$reason" ;;
        1)  probe_examined 1 "workspace AGENTS.md"; probe_fail_or_advisory "$reason" ;;
        *)  probe_cannot_run "$reason" ;;
    esac
}

probe_main "$@"
