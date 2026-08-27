"""No box-walk probe may print a Person URI into walk output.

WHY (2026-08-26)
================
A walk record travels. It lands in logs, support bundles and CI output, and
CM051 is a PUBLIC repo. The customer's graph does not travel, and the two must
not be confused.

`no_person_holds_two_contact_cards` printed the raw URIs of offending nodes. Its
author had already stopped display names from leaking -- the comment says so --
and stopped one step short, because for most nodes the URI LOOKS opaque.

It is not. Measured on the live box: of 7111 Person URIs, 1405 are a full uuid5,
the output of `ostler_fda/pwg_ingest.py:_person_id_from_identifier`:

    uuid5(NAMESPACE_URL, "https://schema.ostler.ai/person/" + identifier)

over a lowercased email or E.164 phone. Unsalted, and the namespace, template
and algorithm are all in this public repo. So identifier -> URI is computable by
anyone, and a published URI is a CONFIRMATION ORACLE: guess an address, compute,
compare. E.164 for a single country is small enough to enumerate exhaustively.

Demonstrated with synthetic values rather than by reversing a real person:

    someone@example.com -> person_a4d2c110-9224-541e-8152-533deb73e0e8
    +447700900123       -> person_959abae0-19e7-5984-beec-2ef4e8480246

This guard exists because fixing the one probe fixes one probe. The next one
will be written by someone who, reasonably, reads a hex string as opaque.
"""

from __future__ import annotations

import pathlib
import re

import pytest

PROBES = pathlib.Path(__file__).resolve().parents[1] / "box_walk_probes" / "probes"

# A probe emits to walk output through these.
#
# THE FIRST VERSION OF THIS GUARD CAPTURED THE QUOTED ARGUMENT --
#     probe_(?:note|fail)\s+"([^"]*)"
# -- and it was DECORATIVE. It passed on the very defect it was written for,
# because the offending line is
#
#     probe_note "first offending nodes: $(printf '%s' "$rows" | ...)"
#
# and [^"]* stops at the quote INSIDE the command substitution. The capture was
# `first offending nodes: $(printf '%s' ` -- no variable, no URI, clean pass.
# Nested quotes defeat any predicate that tries to find where an argument ends.
#
# So do not parse the argument. Detect the EMIT CALL on the line, then judge the
# WHOLE LINE.
EMIT_CALL = re.compile(r"\bprobe_(?:note|fail|pass|cannot_run)\b")

# The literal URI prefix, and the shell variables that in practice hold one.
# Deliberately NARROW: a broad "any variable" rule would flag every count and
# teach people to route around the guard.
URI_LITERAL = re.compile(r"(?:https://schema\.ostler\.ai/ontology#)?person_[0-9a-f]{6,}")
RAW_URI_VAR = re.compile(r"\$\{?\"?(?:rows|uris|nodes_list|offenders|person_uris)\b")

# Hashing a URI before printing is the SANCTIONED way to reference a record, so
# a line that does it is not an offender. This is the one escape hatch and it is
# deliberately specific: `shasum` on the same line as the emit.
HASHED = re.compile(r"\bshasum\b")


def _probe_files():
    return sorted(PROBES.glob("*.sh"))


def test_there_are_probes_to_examine():
    """The denominator. A sweep over zero files passes vacuously."""
    files = _probe_files()
    assert len(files) >= 10, (
        "only %d probe(s) found under %s -- this guard would pass by measuring "
        "nothing" % (len(files), PROBES))


@pytest.mark.parametrize("path", _probe_files(), ids=lambda p: p.name)
def test_probe_emits_no_derivable_person_uri(path):
    offenders = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue                      # a comment is documentation, not output
        if not EMIT_CALL.search(line):
            continue
        if HASHED.search(line):
            continue                      # sanctioned: printing an opaque digest
        if URI_LITERAL.search(line) or RAW_URI_VAR.search(line):
            offenders.append("%s:%d" % (path.name, lineno))
    assert not offenders, (
        "these lines publish a Person URI into walk output: %s. A Person URI is "
        "derivable from an email or phone via unsalted uuid5 with a public "
        "namespace, so publishing one is a confirmation oracle. Print a "
        "SHA-256 prefix instead -- stable across runs, correlates with the "
        "CM041 reconcile tooling, and not invertible by guessing an address."
        % ", ".join(offenders))


def test_the_predicate_can_actually_find_one():
    """POSITIVE CONTROL.

    Without this, a typo in either regex makes every probe pass and the suite
    reports a clean sweep over a predicate that matches nothing.
    """
    assert URI_LITERAL.search("person_a4d2c110-9224-541e-8152-533deb73e0e8")
    assert URI_LITERAL.search("https://schema.ostler.ai/ontology#person_951f574209d5")
    assert RAW_URI_VAR.search('first offending nodes: ${rows}')
    # THE EXACT SHIPPED DEFECT, verbatim from origin/main. If the guard cannot
    # flag this line it is decorative, which is what the first version was.
    shipped = ("""        probe_note "first offending nodes: $(printf '%s' "$rows" """
               """| head -3 | awk '{print $2}' | tr '\\n' ' ')\"""")
    assert EMIT_CALL.search(shipped) and RAW_URI_VAR.search(shipped) \
        and not HASHED.search(shipped), (
        "the guard cannot flag the exact line it was written for")
    # and must NOT fire on the legitimate replacement, or the fix is unshippable
    assert not URI_LITERAL.search("first offending nodes (opaque, sha256 prefix): 40e6a0549d")
    assert not RAW_URI_VAR.search("residual A untyped terminal merge survivors : ${a}")


def test_emit_predicate_finds_real_emit_lines():
    """CONTROL for the OTHER half: EMIT must match how probes actually emit.

    If EMIT matched nothing, the loop above would examine zero strings per file
    and every probe would pass. That is the failure this whole suite is about.
    """
    seen = 0
    for path in _probe_files():
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.lstrip().startswith("#") and EMIT_CALL.search(line):
                seen += 1
    assert seen >= 20, (
        "EMIT_CALL matched only %d emit-site(s) across every probe. The guard "
        "above is examining almost nothing." % seen)
