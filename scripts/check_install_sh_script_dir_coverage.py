#!/usr/bin/env python3
"""check_install_sh_script_dir_coverage.py

Scan install.sh for every ${SCRIPT_DIR}/X reference and assert that each
target asset is either:

  (a) bundled by a postBuildScript in gui/project.yml (recognised either
      by literal path string OR by name fragment match in a postBuildScript
      shell body), OR
  (b) in a documented EXCEPTIONS allow-list (with a justification comment
      pointing at the relevant audit / TODO / inline fallback).

The CI gate's job is to fail the build the moment a new install.sh probe
appears against an asset that no postBuildScript ships. Per the
2026-05-22 deep-dive audit findings, this is the durable fix for the
buried-failure pattern -- the surgical postBuildScripts catch today's
gaps, this gate prevents the next one.

Modes:
  ci         scan install.sh, print to stderr, exit non-zero on coverage gap
  list       print the resolved asset list + coverage status, exit 0 always

Exit codes:
  0  every ${SCRIPT_DIR}/X reference has coverage OR is allow-listed
  1  one or more coverage gaps found
  2  invocation error
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Probes against ${SCRIPT_DIR}/X (or "${SCRIPT_DIR}/X") that resolve into
# install-time-only paths the curl|bash tarball flow handles by passing
# OSTLER_BOOTSTRAP_SCRIPT_DIR (so the path is the extracted tarball dir,
# not a .app bundle resource). These do NOT need a postBuildScript:
# the curl|bash flow always has the file present; the .app flow uses
# the inline fallback documented below.
EXCEPTIONS: dict[str, str] = {
    # The .app build ships install.sh + lib/ + strings catalogue via
    # the "Bundle install.sh + lib/..." postBuildScript. Anything probing
    # ${SCRIPT_DIR}/install.sh.* or ${SCRIPT_DIR}/lib/* is therefore
    # covered by that one entry.
    "install.sh.strings": (
        "Covered by 'Bundle install.sh + lib/progress_emitter.sh + "
        "strings catalogue' postBuildScript"
    ),
    "lib/progress_emitter.sh": (
        "Covered by 'Bundle install.sh + lib/progress_emitter.sh' postBuildScript"
    ),
    "lib/write_pipeline_signals.py": (
        "Covered by 'Bundle install.sh + lib/progress_emitter.sh' postBuildScript "
        "(extended 2026-05-22 to include write_pipeline_signals.py per "
        "deep-dive audit follow-up)."
    ),
    "..": (
        "${SCRIPT_DIR}/../Ostler.app is a re-entry fallback for dev runs "
        "where install.sh runs from a sibling of the staged Ostler.app. "
        "Production path is the same OSTLER_APP_PATH-driven bundle."
    ),
    "extensions/OstlerSafariExtension.app.zip": (
        "F6 deferred per CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md. "
        "See 'extensions' EXCEPTION."
    ),
    "ostler-import.sh": (
        "F10 deferred per CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md. "
        "install.sh has a working inline fallback that materialises ostler-import "
        "via a heredoc when the bundled script is absent."
    ),
    "extensions": (
        "F6 deferred per CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md. "
        "OstlerSafariExtension.app.zip ships from CM020's build-safari-extension.sh; "
        "until CM020's build pipeline is wired into release the .app.zip is absent and "
        "install.sh's existing info-log graceful-skip handles it."
    ),
    "requirements.txt": (
        "Covered by release.sh's HR015_AGGREGATE_REQUIREMENTS_SRC and the "
        "vendor/cm041/contact_syncer/requirements.txt that lands as part of the "
        "CM041 PWG People Graph postBuildScript."
    ),
    "AppIcon.icns": (
        "Bundled into Resources/ by Xcode's standard asset-catalog / "
        "Resources build phase (gui/OstlerInstaller/Resources/AppIcon.icns), "
        "not via a postBuildScript. install.sh probes it for the iMessage "
        "Automation FDA dialog icon (CX-81 B8b)."
    ),
    "DialogIcon.icns": (
        "Bundled into Resources/ by Xcode's standard asset-catalog / "
        "Resources build phase (gui/OstlerInstaller/Resources/DialogIcon.icns), "
        "not via a postBuildScript. install.sh probes it for the iMessage "
        "Automation FDA dialog icon (CX-81 B8b)."
    ),
    "python": (
        "Bundled into Resources/python/ by the 'Bundle python-build-standalone "
        "Python 3.11 into Resources' postBuildScript (gui/project.yml). "
        "install.sh probes ${SCRIPT_DIR}/python/bin/python3.11 to prefer "
        "the bundled portable Python over any system python3 (CX-19)."
    ),
}

# Map ${SCRIPT_DIR}/X probe -> identifying string we expect to find in
# gui/project.yml. The match is case-sensitive and substring-based so the
# gate is robust to comment / whitespace drift in the postBuildScript body.
# The keys here are the canonical "leaf" names install.sh probes for.
COVERAGE_NEEDLES: dict[str, list[str]] = {
    "ostler_security": ["vendor/ostler_security"],
    "legal": ["vendor/legal"],
    "ostler_fda": ["vendor/ostler_fda"],
    "doctor": ["vendor/doctor"],
    "hub-power": ["vendor/hub_power"],
    "cm024_knowledge": ["vendor/cm024_knowledge"],
    "cm048_pipeline": ["vendor/cm048_pipeline"],
    "cm019_preferences": ["vendor/cm019_preferences"],
    "contact_syncer": ["vendor/cm041"],
    "assistant_api": ["vendor/cm041"],
    "email-ingest": ["vendor/email_ingest"],
    "assistant-agent": ["../assistant-agent"],
    "wiki-recompile": ["../wiki-recompile"],
    "context-refresh": ["../context-refresh"],
    "cm021": ["vendor/cm021"],
    "imessage-bridge": ["vendor/imessage_bridge"],
    "identity_resolver": ["vendor/cm041"],
    "meeting_syncer": ["vendor/cm041"],
    "scripts": ["scripts/deferred-register-device.sh"],
    "scripts/deferred-register-device.sh": ["scripts/deferred-register-device.sh"],
    "THIRD_PARTY_NOTICES.md": ["vendor/THIRD_PARTY_NOTICES.md"],
    "LICENSES": ["vendor/LICENSES"],
    "Ostler.app": ["OSTLER_APP_PATH"],
}

SCRIPT_DIR_REGEX = re.compile(r'"\$\{SCRIPT_DIR\}/([^"$]+?)"')


def extract_script_dir_targets(install_sh: Path) -> list[tuple[int, str]]:
    """Return list of (line_number, raw_path) for every ${SCRIPT_DIR}/X probe."""
    results: list[tuple[int, str]] = []
    with install_sh.open() as fh:
        for lineno, line in enumerate(fh, 1):
            for match in SCRIPT_DIR_REGEX.finditer(line):
                results.append((lineno, match.group(1)))
    return results


def canonical_leaf(raw_path: str) -> str:
    """Strip trailing-file qualifiers + path fragments to produce the
    canonical leaf install.sh is testing for.

    Examples:
      assistant-agent/INSTALL_SNIPPET.sh -> assistant-agent
      legal/pyproject.toml               -> legal
      lib/progress_emitter.sh            -> lib/progress_emitter.sh
      LICENSES                            -> LICENSES
      scripts/deferred-register-device.sh -> scripts/deferred-register-device.sh
    """
    parts = raw_path.split("/", 1)
    head = parts[0]
    rest = parts[1] if len(parts) > 1 else ""

    # Whole-path matches we keep intact (deeper assets the gate maps
    # explicitly via COVERAGE_NEEDLES / EXCEPTIONS).
    if raw_path in COVERAGE_NEEDLES:
        return raw_path
    if raw_path in EXCEPTIONS:
        return raw_path

    # lib/* / scripts/* / extensions/* keep their first two segments so
    # they map cleanly to the bundled subdir.
    if head in {"lib", "scripts", "extensions"} and rest:
        return raw_path

    # install.sh.strings.en-GB.sh has multiple dots; strip the lang
    # variant by matching the prefix.
    if head.startswith("install.sh.strings"):
        return "install.sh.strings"

    return head


def check_coverage(
    install_sh: Path,
    project_yml: Path,
) -> tuple[list[tuple[str, list[int]]], list[tuple[str, list[int], str]]]:
    """Return (uncovered, covered) lists of (canonical_leaf, [linenos], reason).

    uncovered = canonical leaves that have no postBuildScript needle AND
                no EXCEPTIONS entry.
    covered   = canonical leaves with at least one postBuildScript needle
                OR an EXCEPTIONS allow-list entry.
    """
    probes = extract_script_dir_targets(install_sh)
    project_yml_body = project_yml.read_text()

    leaf_lines: dict[str, list[int]] = {}
    for lineno, raw_path in probes:
        leaf = canonical_leaf(raw_path)
        leaf_lines.setdefault(leaf, []).append(lineno)

    uncovered: list[tuple[str, list[int]]] = []
    covered: list[tuple[str, list[int], str]] = []

    for leaf, linenos in sorted(leaf_lines.items()):
        if leaf in EXCEPTIONS:
            covered.append((leaf, linenos, f"EXCEPTION: {EXCEPTIONS[leaf]}"))
            continue
        needles = COVERAGE_NEEDLES.get(leaf, [])
        if not needles:
            uncovered.append((leaf, linenos))
            continue
        matched_needle = None
        for needle in needles:
            if needle in project_yml_body:
                matched_needle = needle
                break
        if matched_needle is None:
            uncovered.append((leaf, linenos))
        else:
            covered.append((leaf, linenos, f"gui/project.yml needle: {matched_needle}"))

    return uncovered, covered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode", choices=("ci", "list"), default="ci",
        help="ci = exit non-zero on gap; list = print + exit 0",
    )
    parser.add_argument(
        "--repo-root", type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="CM051 repo root (default: parent of this script)",
    )
    args = parser.parse_args()

    install_sh = args.repo_root / "install.sh"
    project_yml = args.repo_root / "gui" / "project.yml"

    if not install_sh.is_file():
        print(f"error: install.sh not found at {install_sh}", file=sys.stderr)
        return 2
    if not project_yml.is_file():
        print(f"error: gui/project.yml not found at {project_yml}", file=sys.stderr)
        return 2

    uncovered, covered = check_coverage(install_sh, project_yml)

    if args.mode == "list":
        print(f"# ${{SCRIPT_DIR}}/X coverage report against {project_yml}")
        for leaf, linenos, reason in covered:
            print(f"OK   {leaf}  ({len(linenos)} probe(s))  -- {reason}")
        for leaf, linenos in uncovered:
            print(f"GAP  {leaf}  install.sh lines: {linenos}")
        return 0

    if uncovered:
        print(
            "FAIL: install.sh ${SCRIPT_DIR}/X coverage gap. "
            "Every probe must have a matching gui/project.yml postBuildScript "
            "OR an entry in EXCEPTIONS (with justification) in "
            "scripts/check_install_sh_script_dir_coverage.py.",
            file=sys.stderr,
        )
        for leaf, linenos in uncovered:
            sample_lines = ", ".join(str(n) for n in linenos[:5])
            extra = "" if len(linenos) <= 5 else f" + {len(linenos) - 5} more"
            print(
                f"  GAP  ${{SCRIPT_DIR}}/{leaf}  install.sh lines: {sample_lines}{extra}",
                file=sys.stderr,
            )
        return 1

    print(f"OK: {len(covered)} ${{SCRIPT_DIR}}/X probes all covered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
