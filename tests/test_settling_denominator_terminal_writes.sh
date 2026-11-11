#!/usr/bin/env bash
#
# test_settling_denominator_terminal_writes.sh
#
# STATIC GATE. Every channel that the Setting-up bar sums must have a call
# site that can make it TERMINAL. A new producer that writes a settling shard
# and never finishes it silently holds the bar below 100% for good; this test
# turns that into a red CI run instead.
#
# The map of sources, their terminal writes and their skip reasons is
# docs/setup_progress_terminal_map.md. This test enforces the part of it that
# can be checked by reading code:
#
#   1. DISCOVERY. Every file in the tree that calls a settling writer
#      (shell: settling_report / settling_report_measured / settling_complete /
#      settling_skip; python: report_settling_progress(...)) is listed in the
#      MANIFEST below. An unlisted writer fails the test. This is the part that
#      stops a new source appearing without anyone looking at it.
#
#   2. TERMINAL CALL SITE, per manifest row.
#      shell rows   must contain  settling_complete <channel>  or
#                                 settling_skip <channel>
#      python rows  must be in PYTHON_TERMINAL_BY_FINAL_EMIT, with the reason
#                   the terminal write is a final done==total emit rather than
#                   a settling_complete / settling_skip call. Those reasons are
#                   the BLOCKERS in the map; they are recorded here so they
#                   stay visible, not hidden.
#
#   3. EVERY CHANNEL. Each channel in the manifest has at least one terminal
#      writer.
#
# SELF-PROOF. The test runs its own check against a mutated copy of the email
# tick (the terminal call removed) and must see it FAIL. A check that cannot
# fail is not a check.
#
# Usage:
#   bash tests/test_settling_denominator_terminal_writes.sh
#   SETTLING_TREE=/path/to/other/checkout bash tests/...   # e.g. origin/main
#
# Exit 0 = every row terminal and no unlisted writer. Exit 1 = any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${SETTLING_TREE:-$REPO_ROOT}"
WORKFLOW="$REPO_ROOT/.github/workflows/tests-unwired-sweep-mz.yml"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# channel|file (relative to tree)|kind   kind = shell | python
MANIFEST='contacts|install.sh|shell
emails|vendor/email_source/bin/email-bundle-tick.sh|shell
calendar|vendor/ostler_fda/calendar.py|python
messages|vendor/ostler_fda/imessage.py|python
messages|vendor/ostler_fda/whatsapp_history.py|python'

# Python producers whose terminal write is a FINAL done==total emit, not a
# settling_complete / settling_skip call. Each reason is a known limit, not a
# clean pass; see docs/setup_progress_terminal_map.md (BLOCKERS B3, B2).
PYTHON_TERMINAL_BY_FINAL_EMIT='vendor/ostler_fda/calendar.py
vendor/ostler_fda/imessage.py
vendor/ostler_fda/whatsapp_history.py'

# check_tree <root>  -> prints PASS/FAIL lines, returns number of failures
check_tree() {
    local root="$1" n=0 line channel file kind
    local -a seen_channels=()

    # 1. DISCOVERY: every writer call site must be in the manifest.
    local found
    found="$(cd "$root" && {
        /usr/bin/grep -lE 'settling_(report|report_measured|complete|skip)[[:space:]]+[a-z]' install.sh 2>/dev/null
        /usr/bin/grep -lE 'settling_(report|report_measured|complete|skip)[[:space:]]+[a-z]' vendor/email_source/bin/*.sh 2>/dev/null
        /usr/bin/grep -lE 'report_settling_progress\(' vendor/ostler_fda/*.py 2>/dev/null
    } | sort -u | /usr/bin/grep -v '^vendor/ostler_fda/settling_progress.py$' || true)"
    local listed; listed="$(printf '%s\n' "$MANIFEST" | cut -d'|' -f2 | sort -u)"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if printf '%s\n' "$listed" | /usr/bin/grep -qxF "$file"; then
            ok "writer $file is listed in the manifest" >/dev/null
        else
            bad "UNLISTED settling writer: $file calls a settling writer but is not in the manifest. Map it in docs/setup_progress_terminal_map.md and add a row here." ; n=$((n+1))
        fi
    done <<EOF
$found
EOF

    # 2. TERMINAL CALL SITE per manifest row.
    while IFS='|' read -r channel file kind; do
        [ -n "$channel" ] || continue
        if [ ! -f "$root/$file" ]; then
            bad "manifest writer missing from tree: $file ($channel)"; n=$((n+1)); continue
        fi
        if [ "$kind" = shell ]; then
            if /usr/bin/grep -qE "settling_(complete|skip)[[:space:]]+${channel}([[:space:]]|\$)" "$root/$file"; then
                ok "$channel: $file has a settling_complete/settling_skip call site"
                seen_channels+=("$channel")
            else
                bad "$channel: $file has NO settling_complete / settling_skip call site, so this source cannot reach a terminal state"
                n=$((n+1))
            fi
        else
            if printf '%s\n' "$PYTHON_TERMINAL_BY_FINAL_EMIT" | /usr/bin/grep -qxF "$file"; then
                if /usr/bin/grep -q 'report_settling_progress(' "$root/$file"; then
                    ok "$channel: $file terminal by final done==total emit (allowlisted, see map)"
                    seen_channels+=("$channel")
                else
                    bad "$channel: $file no longer calls report_settling_progress; the allowlist entry is stale"
                    n=$((n+1))
                fi
            else
                bad "$channel: $file is a python writer with no allowlisted terminal write"
                n=$((n+1))
            fi
        fi
    done <<EOF
$MANIFEST
EOF

    # 3. EVERY CHANNEL has at least one terminal writer.
    local ch
    for ch in $(printf '%s\n' "$MANIFEST" | cut -d'|' -f1 | sort -u); do
        if printf '%s\n' "${seen_channels[@]:-}" | /usr/bin/grep -qxF "$ch"; then
            ok "channel $ch has a terminal writer"
        else
            bad "channel $ch has NO terminal writer"; n=$((n+1))
        fi
    done

    return "$n"
}

printf '== test_settling_denominator_terminal_writes ==\n'
printf '  tree: %s\n' "$TREE"

check_tree "$TREE"
rc_real=$?

# SELF-PROOF: remove the emails terminal call from a copy and require a FAIL.
MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT
mkdir -p "$MUT/vendor/email_source/bin" "$MUT/vendor/ostler_fda"
cp "$TREE/install.sh" "$MUT/install.sh"
cp "$TREE/vendor/ostler_fda/"*.py "$MUT/vendor/ostler_fda/"
sed -e 's/settling_complete emails/true emails/' -e 's/settling_skip emails/true emails/' \
    "$TREE/vendor/email_source/bin/email-bundle-tick.sh" > "$MUT/vendor/email_source/bin/email-bundle-tick.sh"
mut_out="$(check_tree "$MUT" 2>&1)"
mut_rc=$?
if [ "$mut_rc" -ge 1 ] && printf '%s\n' "$mut_out" | /usr/bin/grep -q 'emails: .*NO settling_complete'; then
    ok "self-proof: removing the emails terminal call makes this check FAIL ($mut_rc failure(s))"
else
    bad "self-proof: the check did not FAIL on a tree with the emails terminal call removed (rc=$mut_rc)"
fi

if /usr/bin/grep -q 'test_settling_denominator_terminal_writes.sh' "$WORKFLOW"; then
    ok "test is wired into tests-unwired-sweep-mz.yml"
else
    bad "test is not invoked by any workflow (unwired)"
fi

if [ "$rc_real" -eq 0 ]; then
    ok "every settling writer is listed and every channel has a terminal write ($rc_real failures)"
else
    bad "$rc_real failure(s) in the tree at $TREE"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
