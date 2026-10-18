#!/usr/bin/env bash
# tests/test_every_walk_ssh_gives_up_on_a_dead_link.sh
#
# v1.0.102 candidate 4: the driver's wifi dropped mid-probe and one ssh sat 42
# minutes on a connection the box had already closed. ConnectTimeout bounds the
# CONNECT only. Every ssh the walk's probe phase makes must also carry
# ServerAliveInterval, so a dead link returns 255 (CANNOT-RUN) within about a
# minute instead of hanging the walk.
#
# Scope: every file the probe phase runs (scripts/box_walk_probes/**, the
# recorder and post_walk_qa.sh). A CONTROL proves the scanner finds an ssh
# without the option, so a scan that matches nothing cannot pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
arm() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; else fail=$((fail+1)); printf '  [FAIL] %s\n%s\n' "$1" "${3:-}"; fi; }

# An ssh INVOCATION: `ssh -o` or `/usr/bin/ssh -o` at a command position, not
# in a comment. The options may continue on the next line after a backslash,
# so each hit is joined with its continuation lines before it is judged.
scan() { # scan <file...> -> prints file:line of every ssh call lacking ServerAliveInterval
    python3 - "$@" <<'PY'
import re, sys
pat = re.compile(r'(^|[\s(;|&`"$])(/usr/bin/)?ssh\s+-o\b')
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    for i, raw in enumerate(lines):
        if raw.lstrip().startswith("#") or not pat.search(raw):
            continue
        j, call = i, raw
        while call.rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1; call = call.rstrip()[:-1] + " " + lines[j]
        if "ServerAliveInterval" not in call:
            print("%s:%d" % (path, i + 1))
PY
}

cd "$HERE"
files="$(find scripts/box_walk_probes -name '*.sh' -type f; printf '%s\n' scripts/post_walk_qa.sh scripts/record_walk.sh)"
calls="$(printf '%s\n' $files | xargs grep -c -E '(/usr/bin/)?ssh +-o' | awk -F: '{t+=$2} END{print t+0}')"
bad="$(scan $files)"
arm "every ssh the probe phase makes carries ServerAliveInterval (${calls} call line(s) examined)" "$([ -z "$bad" ] && [ "$calls" -gt 0 ] && echo 0 || echo 1)" "$bad"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'box(){ ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$1"; }\n' > "$T/bare.sh"
printf 'x=$(/usr/bin/ssh -o BatchMode=yes \\\n    -o ServerAliveInterval=15 "$H" true)\n' > "$T/ok.sh"
printf '# ssh -o ConnectTimeout=8 is only mentioned here\n' > "$T/comment.sh"
arm "CONTROL: a bare ssh is found" "$([ -n "$(scan "$T/bare.sh")" ] && echo 0 || echo 1)"
arm "CONTROL: the option on a continuation line counts" "$([ -z "$(scan "$T/ok.sh")" ] && echo 0 || echo 1)"
arm "CONTROL: a comment is not a call" "$([ -z "$(scan "$T/comment.sh")" ] && echo 0 || echo 1)"

printf '\n== %d pass / %d fail / %d total ==\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
