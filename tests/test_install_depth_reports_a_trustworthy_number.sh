#!/usr/bin/env bash
# scripts/install_depth.sh is the number that makes an install regression
# bisectable. A depth tool that cannot fail is worse than none, because a
# silent 41/41 reads as "it completed".
#
# WHY IT EXISTS: on 2026-09-07 the installer went from completing (v1.0.68,
# 2026-09-05) to aborting at step 5 (v1.0.73). Nothing recorded the depth, so
# localising the regression meant reading 30 commits by hand.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${D}/../scripts/install_depth.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
chk() { if [[ "$2" == "$3" ]]; then printf 'ok   %s -- %s\n' "$1" "$2"; else printf 'FAIL %s -- got %s want %s\n' "$1" "$2" "$3" >&2; fails=$((fails+1)); fi; }

[[ -x "$TOOL" ]] || { printf 'FAIL: %s is not executable\n' "$TOOL" >&2; exit 1; }

# The tool's own self-test carries a control that must fail.
"$TOOL" --self-test >/dev/null 2>&1 && printf 'ok   self-test passes (it contains a must-fail control)\n' \
  || { printf 'FAIL self-test did not pass\n' >&2; fails=$((fails+1)); }

# The marker wire is authoritative and must be read exactly.
printf '[gui-marker] STEP_BEGIN id=config_save phase=3 idx=6 total=41\n' > "$WORK/g.log"
chk "gui marker depth" "$("$TOOL" "$WORK/g.log" | awk -F'\t' '$1=="install_depth"{print $2}')" "6"
chk "gui marker step"  "$("$TOOL" "$WORK/g.log" | awk -F'\t' '$1=="install_last_step"{print $2}')" "config_save"

# An empty log MUST report 0. A depth tool that reports nothing as complete is
# the failure mode that matters.
: > "$WORK/e.log"
chk "empty log is 0 not complete" "$("$TOOL" "$WORK/e.log" | awk -F'\t' '$1=="install_depth"{print $2}')" "0"

# --bisect must REFUSE a shallow log. This is the control: if it accepted, every
# bisect run would report "good" and the search would converge on nothing.
if "$TOOL" --bisect 41 "$WORK/g.log" >/dev/null 2>&1; then
    printf 'FAIL --bisect 41 accepted a depth-6 log\n' >&2; fails=$((fails+1))
else
    printf 'ok   CONTROL: --bisect 41 refuses a depth-6 log\n'
fi
"$TOOL" --bisect 6 "$WORK/g.log" >/dev/null 2>&1 && printf 'ok   --bisect 6 accepts a depth-6 log\n' \
  || { printf 'FAIL --bisect 6 rejected a depth-6 log\n' >&2; fails=$((fails+1)); }

[[ $fails -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$fails" >&2; exit 1; }
printf '\nall assertions passed\n'
