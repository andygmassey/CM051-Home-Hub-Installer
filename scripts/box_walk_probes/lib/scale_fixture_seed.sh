# scale_fixture_seed.sh -- sourced by run_box_walk.sh. Defines scale_fixture_apply.
#
# v1.0.107 cut #16 console walk: Qdrant ran out of file descriptors under the
# real volume of a real Mac, and the synthetic walk could not see it because its
# seed is a handful of rows. This step puts that volume through the INSTALLED
# hydrate path at walk time, before the probes read the box:
#   1. stage lib/scale_fixture.py on the box
#   2. generate the deterministic synthetic fixture there (4,200 people in three
#      export shapes, 9,000 reminders, 6,000 notes; seed 108)
#   3. replay the reminders and notes through /usr/local/bin/ostler-knowledge
#      convert + embed, the exact flags install.sh uses, into
#      reminders_knowledge and apple_notes_knowledge; the step logs land in
#      ~/.ostler/diagnostics/<stamp>-scale-fixture/, where
#      qdrant_has_fd_headroom_and_writes_land reads their counts.
#
# The replay is long by design (the SST count grows with the wall time of
# paced writes): about 18 minutes at 40 ms an embed. OSTLER_WALK_SCALE=0 skips
# it (recorded as skipped, never as passed); OSTLER_WALK_SCALE_BUDGET_S bounds it
# (default 5400). The fixture is synthetic: cast names, example.com, the Ofcom
# drama range. The outcome is written to ~/.walk-scale-fixture-run.

_sfs_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" "$OSTLER_BOX_HOST" "$1"
    else
        bash -c "$1"
    fi
}

scale_fixture_apply() {
    local here state rc
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf 'Scale fixture (v1.0.107 #16: Qdrant fd exhaustion under real volume)\n'
    if [ "${OSTLER_WALK_SCALE:-1}" = "0" ]; then
        printf '  SKIPPED (OSTLER_WALK_SCALE=0): the scale replay was not run.\n\n'
        printf 'skipped rc=0\n' > "${HOME}/.walk-scale-fixture-run"
        return 0
    fi
    local dir='$HOME/.ostler/walk-scale-fixture'
    _sfs_box "mkdir -p ${dir} && printf %s '$(base64 < "${here}/scale_fixture.py" | tr -d '\n')' | base64 -d > ${dir}/scale_fixture.py" \
        || { printf '  CANNOT-RUN: could not stage scale_fixture.py on the box\n\n'; printf 'failed-stage rc=2\n' > "${HOME}/.walk-scale-fixture-run"; return 1; }
    rc=0
    _sfs_box "cd ${dir} && { [ -f fixture/manifest.json ] || python3 scale_fixture.py generate --out fixture >/dev/null; } \
        && perl -e 'alarm shift; exec @ARGV' ${OSTLER_WALK_SCALE_BUDGET_S:-5400} python3 scale_fixture.py replay --fixture fixture" \
        > "${HOME}/.walk-scale-fixture-replay.json" 2>&1 || rc=$?
    case "$rc" in
        0) state="replayed" ;;
        142) state="budget-expired" ;;
        *) state="replay-rc-${rc}" ;;
    esac
    printf '  %s (rc=%s); step counts are read by qdrant_has_fd_headroom_and_writes_land\n\n' "$state" "$rc"
    printf '%s rc=%s\n' "$state" "$rc" > "${HOME}/.walk-scale-fixture-run"
    return 0
}
