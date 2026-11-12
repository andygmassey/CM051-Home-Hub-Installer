#!/usr/bin/env bash
# tests/test_intelligence_scorecard_selftest.sh
# ============================================================================
# THE SCORECARD'S SCORER MUST BE ABLE TO FAIL.
#
# scripts/intelligence_scorecard/ grades an assistant against scripted
# scenarios. Before any live number from it is trusted, the scorer has to be
# shown to tell right from wrong on known answers:
#
#   1. its own --self-test: the scripted-correct stub goes all green, the dumb
#      stub goes red on at least three scenarios, and the silent, cold and
#      unreachable modes never produce a PASS;
#   2. a MUTANT of the scorer, with its FAIL verdict switched off, must make
#      that self-test go red. A self-test that stays green on a broken scorer
#      proves nothing, so the mutant is the control for the control.
#
# The mutant is applied with sed to a COPY in a private temp directory. The
# real file is never touched, and the copy is checked to contain the mutation,
# because a mutant that did not apply looks exactly like one that was not caught.
# ============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${here}/scripts/intelligence_scorecard"
fail=0

out="$(python3 "${src}/scorecard.py" --self-test 2>&1)"
rc=$?
printf '%s\n' "${out}"
if [ "${rc}" -ne 0 ]; then
    echo "FAIL: the scorer's self-test is red on the real scorer (rc=${rc})"
    fail=1
fi
case "${out}" in
    *"SELF-TEST GREEN"*) echo "ok    self-test reports GREEN on the real scorer" ;;
    *) echo "FAIL  self-test did not print GREEN"; fail=1 ;;
esac
case "${out}" in
    *"stub:dumb"*"FAIL"*) echo "ok    the dumb stub is scored, with FAILs" ;;
    *) echo "FAIL  the dumb stub line is missing or shows no FAIL"; fail=1 ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scorecard-mutant.XXXXXX")" || { echo "FAIL: no temp dir"; exit 1; }
cp "${src}/scorecard.py" "${src}/scenarios.py" "${src}/stub_hub.py" "${src}/telemetry.py" "${tmp}/"
# Switch the FAIL verdict off: a hard failure is reported as a PASS.
sed 's/    if hard_fail or prod_ctrl:/    if False:  # MUTANT/' "${tmp}/scorecard.py" > "${tmp}/scorecard.mutant.py" && mv "${tmp}/scorecard.mutant.py" "${tmp}/scorecard.py"
if /usr/bin/grep -q 'MUTANT' "${tmp}/scorecard.py"; then
    echo "ok    the mutation applied to the copy (FAIL verdict switched off)"
else
    echo "FAIL  the mutation did not apply, so the control proves nothing"; fail=1
fi
mout="$(python3 "${tmp}/scorecard.py" --self-test 2>&1)"
mrc=$?
rm -rf "${tmp}"
if [ "${mrc}" -ne 0 ]; then
    echo "ok    the self-test goes RED on the mutant (rc=${mrc})"
else
    echo "FAIL  the self-test stayed GREEN on a scorer that cannot FAIL"; fail=1
fi
case "${mout}" in
    *"SELF-TEST RED"*) ;;
    *) echo "FAIL  the mutant run did not print SELF-TEST RED"; fail=1 ;;
esac

if [ "${fail}" -ne 0 ]; then
    echo "intelligence scorecard self-test: FAILED"
    exit 1
fi
echo "intelligence scorecard self-test: PASS (real scorer green, mutant red)"
exit 0
