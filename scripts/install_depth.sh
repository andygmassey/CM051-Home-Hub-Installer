#!/usr/bin/env bash
# How FAR did an install get? The one number that makes a regression bisectable.
#
# WHY THIS EXISTS. On 2026-09-07 the installer went from completing (v1.0.68,
# 2026-09-05) to aborting at 12% (v1.0.73, 2026-09-07). Nothing recorded that
# change, so localising it meant reading 30 commits by hand. walks/<v>.tsv
# records what the POST-INSTALL probes said; it has no field for how deep the
# install itself reached, and walks/README.md already flags a related gap under
# "What the record cannot tell you: how DEEP the walk went".
#
# With a depth number per commit, `git bisect run` finds the culprit instead of
# a person doing it.
#
# USAGE
#   scripts/install_depth.sh <install-log>            report, exit 0
#   scripts/install_depth.sh --bisect N <install-log> exit 0 if depth >= N, else 1
#   scripts/install_depth.sh --self-test              prove the parser can fail
#
# READS BOTH LOG SHAPES, because the installer speaks two:
#   GUI mode  [gui-marker] STEP_BEGIN id=X ... idx=5 total=41
#   tty mode  the step TITLE printed on its own line, no index at all
# The tty path resolves a title to an index using install.sh's own ordered
# `progress "<title>" "<id>"` lines, so the two agree by construction rather
# than by a hand-kept second list that would drift.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${OSTLER_INSTALL_SH:-${SCRIPT_DIR}/../install.sh}"

die() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

# Ordered step list, taken from install.sh itself.
step_ids() {
    [[ -r "$INSTALL_SH" ]] || die "no install.sh at ${INSTALL_SH} (set OSTLER_INSTALL_SH)"
    /usr/bin/sed -nE 's/^[[:space:]]*progress[[:space:]]+"([^"]*)"[[:space:]]+"([a-z0-9_]+)".*/\2\t\1/p' "$INSTALL_SH"
}

depth_of() {
    local log="$1" total idx=0 id="" line
    [[ -r "$log" ]] || die "log not readable: ${log}"
    total="$(step_ids | wc -l | tr -d ' ')"
    [[ "$total" -gt 0 ]] || die "install.sh yielded 0 steps -- the progress() pattern no longer matches"

    # 1) GUI marker wire: authoritative, carries its own index.
    line="$(/usr/bin/grep -oE 'idx=[0-9]+ total=[0-9]+' "$log" 2>/dev/null | tail -1 || true)"
    if [[ -n "$line" ]]; then
        idx="${line#idx=}"; idx="${idx%% *}"
        id="$(/usr/bin/grep -oE 'STEP_BEGIN id=[a-z0-9_]+' "$log" 2>/dev/null | tail -1 | sed 's/.*id=//' || true)"
        printf '%s\t%s\t%s\tgui-marker\n' "$idx" "$total" "${id:-unknown}"
        return 0
    fi

    # 2) tty mode: last step TITLE that appears, resolved against install.sh order.
    # A title could in principle appear in prose rather than as a step
    # announcement, which would overstate the depth. So this ALSO counts how
    # many distinct step titles appear at all: if depth is 41 and only 3 titles
    # were seen, the number is not to be trusted, and the reader can see that
    # without having to know it. Reporting the corroboration beats asserting
    # the answer.
    local n=0 best=0 bid="" seen=0
    while IFS=$'\t' read -r sid stitle; do
        n=$((n + 1))
        [[ -n "$stitle" ]] || continue
        if /usr/bin/grep -qF -- "$stitle" "$log" 2>/dev/null; then
            best="$n"; bid="$sid"; seen=$((seen + 1))
        fi
    done < <(step_ids)
    printf '%s\t%s\t%s\ttitle-scan seen=%s\n' "$best" "$total" "${bid:-none}" "$seen"
}

self_test() {
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    local fails=0
    # A log that reached step 5 by the marker wire.
    printf '[gui-marker] STEP_BEGIN id=ollama_install phase=3 idx=5 total=41\n' > "$tmp/a.log"
    local got; got="$(depth_of "$tmp/a.log" | cut -f1)"
    [[ "$got" == "5" ]] && printf '  ok   marker wire reports 5\n' || { printf '  FAIL marker wire got %s want 5\n' "$got" >&2; fails=1; }
    # An EMPTY log must report 0, not silently pass as complete.
    : > "$tmp/b.log"
    got="$(depth_of "$tmp/b.log" | cut -f1)"
    [[ "$got" == "0" ]] && printf '  ok   empty log reports 0, not a pass\n' || { printf '  FAIL empty log got %s want 0\n' "$got" >&2; fails=1; }
    # CONTROL THAT MUST FAIL: depth 5 must NOT satisfy a --bisect floor of 41.
    if depth_of "$tmp/a.log" | awk -v n=41 '{exit ($1>=n)?0:1}'; then
        printf '  FAIL a depth-5 log satisfied a floor of 41\n' >&2; fails=1
    else
        printf '  ok   CONTROL: depth 5 does NOT satisfy floor 41\n'
    fi
    [[ "$fails" -eq 0 ]] && { printf 'SELF-TEST PASSED\n'; return 0; }
    printf 'SELF-TEST FAILED\n' >&2; return 1
}

case "${1:-}" in
    --self-test) self_test ;;
    --bisect)
        floor="${2:?--bisect needs a step floor}"; log="${3:?--bisect needs a log}"
        read -r d t id src < <(depth_of "$log")
        printf 'depth %s/%s (%s, via %s) floor %s\n' "$d" "$t" "$id" "$src" "$floor"
        [[ "$d" -ge "$floor" ]] ;;
    ""|-h|--help) printf 'usage: %s [--self-test|--bisect <floor>] <install-log>\n' "$0"; exit 0 ;;
    *)
        read -r d t id src < <(depth_of "$1")
        printf 'install_depth\t%s\n' "$d"
        printf 'install_total\t%s\n' "$t"
        printf 'install_last_step\t%s\n' "$id"
        printf 'install_depth_source\t%s\n' "$src"
        pct=0; [[ "$t" -gt 0 ]] && pct=$(( d * 100 / t ))
        printf 'install_depth_pct\t%s\n' "$pct" ;;
esac
