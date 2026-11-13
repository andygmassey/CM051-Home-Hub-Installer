#!/usr/bin/env bash
#
# test_settling_denominator_terminal_writes.sh
#
# STATIC GATE. Every channel that the Setting-up bar sums must have a call
# site that can make it TERMINAL. A new producer that writes a settling shard
# and never finishes it silently holds the bar below 100% for good; this test
# turns that into a red CI run instead.
#
# THE ONE LIST. The fixed channel set (the bar's denominator) is
# lib/settling_channels.json. It is the only list of channels in CM051. CM044's
# compiler/hydration.py reads the same file at runtime (installed to
# ~/.ostler/state/settling_channels.json by install.sh). This gate reads it too,
# and fails when the writer MANIFEST below names a different set of channels.
#
# The map of sources, their terminal writes and their skip reasons is
# docs/setup_progress_terminal_map.md. This test enforces the part of it that
# can be checked by reading code:
#
#   0.  ONE LIST. lib/settling_channels.json parses.
#   0b. AGREEMENT. The channels in the JSON are exactly the channels in MANIFEST
#       below, in both directions. A disagreement is reported as DISAGREE.
#   5.  INSTALLED. install.sh copies the JSON to the state dir CM044 reads.
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
#      python rows  must carry complete=True and skip_reason="<code>" emits.
#                   There is NO allowlist: done==total is not terminal.
#
#   3. EVERY CHANNEL. Each channel in the manifest has at least one terminal
#      writer.
#
# SELF-PROOF. The test runs its own check against a mutated copy of the email
# tick (the terminal call removed) and must see it FAIL. It also runs against a
# copy whose JSON drops emails and must see DISAGREE. A check that cannot fail
# is not a check.
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

# channels_from_json <file>  -> one channel per line. Exit 1 with the reason on
# stderr if the file is missing, unparseable, empty, or lists a channel twice.
channels_from_json() {
    python3 -I -c '
import json, sys
try:
    chans = json.load(open(sys.argv[1], encoding="utf-8"))["channels"]
    assert isinstance(chans, list) and chans, "no channels list"
    assert all(isinstance(c, str) and c.strip() for c in chans), "non-string channel"
    assert len(set(chans)) == len(chans), "channel listed twice"
except Exception as exc:
    sys.stderr.write("unusable %s: %s: %s\n" % (sys.argv[1], type(exc).__name__, exc))
    sys.exit(1)
print("\n".join(chans))
' "$1"
}

# check_tree <root>  -> prints PASS/FAIL lines, returns number of failures
check_tree() {
    local root="$1" n=0 line channel file kind
    local -a seen_channels=()
    local json_channels=""

    # 0. ONE LIST: the fixed channel set comes from the JSON file.
    if json_channels="$(channels_from_json "$root/lib/settling_channels.json")"; then
        ok "fixed channel set: $(printf '%s' "$json_channels" | tr '\n' ' ')"
    else
        bad "lib/settling_channels.json is missing or unusable in $root; the fixed channel set has no source"
        n=$((n+1)); json_channels=""
    fi

    # 0b. AGREEMENT: the JSON and the writer MANIFEST name the same channels.
    local manifest_channels
    manifest_channels="$(printf '%s\n' "$MANIFEST" | cut -d'|' -f1 | sort -u)"
    if [ "$(printf '%s\n' "$json_channels" | sort -u)" = "$manifest_channels" ]; then
        ok "DISAGREE check: lib/settling_channels.json and the writer MANIFEST name the same channels"
    else
        bad "DISAGREE: lib/settling_channels.json names [$(printf '%s' "$json_channels" | tr '\n' ' ')] but the writer MANIFEST names [$(printf '%s' "$manifest_channels" | tr '\n' ' ')]"
        n=$((n+1))
    fi

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
            # Python writers: NO allowlist. A done==total emit is not terminal
            # (the CM044 reader counts only explicit markers), so the file must
            # carry BOTH markers: complete=True on the finishing emit, and a
            # skip_reason="<code>" for a run with nothing available.
            if ! /usr/bin/grep -q 'report_settling_progress(' "$root/$file"; then
                bad "$channel: $file no longer calls report_settling_progress"
                n=$((n+1))
            elif ! /usr/bin/grep -qE 'complete=True' "$root/$file"; then
                bad "$channel: $file has NO complete=True emit, so a finished run stays open at done==total"
                n=$((n+1))
            elif ! /usr/bin/grep -qE 'skip_reason="[a-z_]+"' "$root/$file"; then
                bad "$channel: $file has NO skip_reason=\"<code>\" emit, so a run with nothing available stays open"
                n=$((n+1))
            else
                ok "$channel: $file has complete=True and skip_reason=\"<code>\" emits (no allowlist)"
                seen_channels+=("$channel")
            fi
        fi
    done <<EOF
$MANIFEST
EOF

    # 3. EVERY CHANNEL in the ONE LIST has at least one terminal writer.
    local ch
    while IFS= read -r ch; do
        [ -n "$ch" ] || continue
        if printf '%s\n' "${seen_channels[@]:-}" | /usr/bin/grep -qxF "$ch"; then
            ok "channel $ch has a terminal writer"
        else
            bad "channel $ch has NO terminal writer"; n=$((n+1))
        fi
    done <<LIST_EOF
$json_channels
LIST_EOF

    # 5. INSTALLED: install.sh copies the JSON to the state dir CM044 reads.
    if /usr/bin/grep -qF 'lib/settling_channels.json" "${OSTLER_DIR}/state/"' "$root/install.sh" 2>/dev/null; then
        ok "install.sh installs settling_channels.json to ~/.ostler/state"
    else
        bad "install.sh does not install lib/settling_channels.json to ~/.ostler/state; CM044 falls back to its built-in copy"
        n=$((n+1))
    fi

    return "$n"
}

printf '== test_settling_denominator_terminal_writes ==\n'
printf '  tree: %s\n' "$TREE"

check_tree "$TREE"
rc_real=$?

# SELF-PROOF: remove the emails terminal call from a copy and require a FAIL.
MUT="$(mktemp -d)"
MUT2="$(mktemp -d)"
trap 'rm -rf "$MUT" "$MUT2"' EXIT
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

# SELF-PROOF 3: the python writers carry no allowlist. Strip complete=True from a
# copy of calendar.py and require a FAIL naming it.
MUT3="$(mktemp -d)"
mkdir -p "$MUT3/vendor/ostler_fda" "$MUT3/vendor/email_source/bin" "$MUT3/lib"
cp "$TREE/install.sh" "$MUT3/install.sh"
cp "$TREE/lib/settling_channels.json" "$MUT3/lib/" 2>/dev/null
cp "$TREE/vendor/email_source/bin/email-bundle-tick.sh" "$MUT3/vendor/email_source/bin/"
cp "$TREE/vendor/ostler_fda/"*.py "$MUT3/vendor/ostler_fda/"
sed -e 's/complete=True/complete=False/' "$TREE/vendor/ostler_fda/calendar.py" > "$MUT3/vendor/ostler_fda/calendar.py"
mut3_out="$(check_tree "$MUT3" 2>&1)"
rm -rf "$MUT3"
if printf '%s\n' "$mut3_out" | /usr/bin/grep -q 'calendar: .*NO complete=True'; then
    ok "self-proof: stripping complete=True from calendar.py makes this check FAIL (no allowlist)"
else
    bad "self-proof: the check did not FAIL on a calendar.py with complete=True removed"
fi

# SELF-PROOF 2: a JSON that drops emails must make the agreement check report DISAGREE.
mkdir -p "$MUT2/lib"
printf '%s\n' '{"schema": 1, "channels": ["contacts", "calendar", "messages"]}' > "$MUT2/lib/settling_channels.json"
mut2_out="$(check_tree "$MUT2" 2>&1)"
if printf '%s\n' "$mut2_out" | /usr/bin/grep -q 'DISAGREE:'; then
    ok "self-proof: a JSON that drops emails makes the agreement check report DISAGREE"
else
    bad "self-proof: the agreement check did not report DISAGREE on a JSON that drops emails"
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
