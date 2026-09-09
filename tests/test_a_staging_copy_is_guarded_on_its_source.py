#!/usr/bin/env python3
"""A vendored tree must be re-staged on every install, so a fix can reach a box.

WHY THIS EXISTS. MEASURED on the v1.0.81 walk box, 2026-09-09.

install.log run 20260909T082840Z:

    :1016 STEP_BEGIN id=cm019_setup ... idx=16 total=40
    :1022 LOG info "Preference enrichment already set up"
    :1027 STEP_END id=cm019_setup status=ok elapsed_s=0

cm019_setup is guarded by ``[[ ! -x "$CM019_PY" ]]``, and that guard encloses
the ``rm -rf``, the ``cp -R`` of the bundle AND the pip install. The venv had
survived from a previous install, so the whole block was skipped and the box
kept the PREVIOUS DMG's vendored cm019 code while the install reported success.

THE CONSEQUENCE IS THE POINT: a fix landed in vendor/cm019_preferences/ does not
reach any box that already has that venv. The walk box that is supposed to
demonstrate a v1.0.82 vendored fix would run last week's code and the probe
would not move, with nothing in the log to say why.

THE PROPERTY, NOT THE INSTANCE. This does not assert "cm019 is broken", which
would go green when cm019 is fixed and blind to the next one. It asserts that NO
staging copy is guarded on the ABSENCE of something, which is what a
destination-presence skip looks like. Measured across install.sh: fourteen
staging copies, thirteen guarded on the SOURCE existing, one on absence. The
convention is already the repo's own; this keeps it.

Three states: PASS, FAIL, and a refusal if nothing was enumerated, because a
scan that found no staging copies has not proved they are all correct.
"""
from __future__ import annotations

import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(REPO, "install.sh")

# A copy that stages vendored code: the SOURCE side names the DMG payload.
_STAGING = re.compile(r'^\s*(cp -R|rsync -a)\s')
_SOURCEY = re.compile(r'SCRIPT_DIR|_BUNDLE|_PAYLOAD')
# `! -x`, `! -d`, `! -f`: a test for something being ABSENT.
_ABSENCE = re.compile(r'!\s*-[a-z]\s')
_GUARD_LOOKBACK = 16


def enclosing_guard(lines, n):
    """The nearest `if` above line n (1-indexed), or None.

    ⚠️ THE LOWER BOUND IS -1, NOT 0, AND THE POSITIVE CONTROL BELOW CAUGHT IT.
    With max(0, ...) the walk stops one line short and can never reach index 0,
    so a guard on the FIRST line of the region is invisible. The seeded fixture
    puts one there, which is how a detector that missed it was found before it
    was trusted with the real file.
    """
    for j in range(n - 2, max(-1, n - 2 - _GUARD_LOOKBACK), -1):
        s = lines[j].strip()
        if s.startswith("if [[") or s.startswith("if ["):
            return j + 1, s
    return None


def staging_sites(text):
    """Every vendored-code staging copy, enumerated FROM THE SOURCE.

    Enumerated rather than listed, so a fifteenth site added tomorrow is
    covered without anyone remembering to add it here.
    """
    lines = text.splitlines()
    out = []
    for i, ln in enumerate(lines, 1):
        if _STAGING.search(ln) and _SOURCEY.search(ln):
            out.append((i, ln.strip(), enclosing_guard(lines, i)))
    return out


def guarded_on_absence(sites):
    return [(n, ln, g) for n, ln, g in sites if g and _ABSENCE.search(g[1])]


class StagingCopiesAreGuardedOnTheirSource(unittest.TestCase):
    def setUp(self):
        with open(INSTALL, encoding="utf-8", errors="replace") as fh:
            self.text = fh.read()
        self.sites = staging_sites(self.text)

    def test_the_scan_found_something_to_judge(self):
        """A zero denominator is not a pass. install.sh stages many trees."""
        self.assertGreaterEqual(
            len(self.sites),
            10,
            "only %d staging copies enumerated; the pattern this scans for has "
            "changed and every verdict below is against an empty population"
            % len(self.sites),
        )

    def test_no_staging_copy_is_guarded_on_absence(self):
        """THE PROPERTY. A copy skipped because the destination already exists
        leaves the previous install's code in place for ever."""
        bad = guarded_on_absence(self.sites)
        self.assertEqual(
            bad,
            [],
            "these staging copies are skipped when their destination already "
            "exists, so a vendored fix never reaches a box that has one:\n"
            + "\n".join(
                "  install.sh:%d  %s\n      guarded at :%d by %s" % (n, ln[:70], g[0], g[1][:80])
                for n, ln, g in bad
            ),
        )

    def test_the_detector_flags_a_seeded_offender(self):
        """POSITIVE CONTROL. Without it, a green above could mean the regexes
        stopped matching anything rather than that the tree is clean."""
        seeded = (
            'if [[ ! -x "$FIXTURE_PY" ]]; then\n'
            '    rm -rf "$FIXTURE_DIR"\n'
            '    cp -R "${SCRIPT_DIR}/fixture_bundle/" "$FIXTURE_DIR/"\n'
            "fi\n"
        )
        found = guarded_on_absence(staging_sites(seeded))
        self.assertEqual(
            len(found), 1, "the detector did not flag a copy guarded on absence"
        )

    def test_the_detector_passes_a_source_guarded_copy(self):
        """MUST-MISS, so it is not simply flagging every staging copy."""
        ok = (
            'if [[ -d "${SCRIPT_DIR}/fixture_bundle" ]]; then\n'
            '    cp -R "${SCRIPT_DIR}/fixture_bundle" "$FIXTURE_DIR/"\n'
            "fi\n"
        )
        sites = staging_sites(ok)
        self.assertEqual(len(sites), 1, "the fixture's own copy was not enumerated")
        self.assertEqual(guarded_on_absence(sites), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
