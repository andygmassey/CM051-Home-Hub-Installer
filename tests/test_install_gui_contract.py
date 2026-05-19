#!/usr/bin/env python3
"""Cross-component contract test: install.sh <-> Swift GUI.

Why this exists:
  Across v0.1.0 -> v0.4.0, six PRs (#79, #81, #82, #83, #84, #87) all
  closed protocol drift between install.sh's `#OSTLER` markers and the
  Swift GUI's ProgressDecoder.  Each was a missed handler that shipped
  to a customer DMG.  This test treats the protocol as a contract and
  fails CI on any new drift before it reaches a release.

What it asserts (per the architectural recon documented in the PR):
  1. PROMPT well-formedness: every `gui_read` callsite emits a
     `kind=` value that is a member of Swift's PromptKind enum
     (`text|secret|yesno|choice`).  The Swift coordinator is a
     generic prompt renderer -- there are no per-id handlers -- so
     this enum is the real cross-boundary contract for PROMPT.
  2. STEP_BEGIN id parity: every id emitted by `progress` /
     `gui_step_begin` in install.sh is either in
     `StepCatalog.canonicalOrder` OR is a documented dynamic-id site.
     Likewise, every id in `canonicalOrder` should be reachable from
     install.sh; orphan canonical-order entries surface as
     `DEAD HANDLER` warnings (not fails -- canonicalOrder is a
     forward-compat list).
  3. PHASE id parity: every `step` callsite id is in canonicalOrder
     OR is a documented out-of-band phase id.  Out-of-band PHASE
     emissions are tolerated by the GUI (see
     InstallerCoordinator.advanceSidebarFromPhase), so unknown PHASE
     ids surface as `NOTE`, not a fail.
  4. Top-level event-kind coverage: every emission kind is in
     ProgressDecoder's switch arms, OR is in the documented
     `soft_unknown_ok` list (currently `MAIL_ACCOUNTS_FOUND`, which
     the Swift side intentionally falls through to `.unknown`).

  Soft failures surface as printed lines but do not fail the test.
  Hard failures fail the test with `unittest`'s standard machinery.
"""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# IDs that are known to be constructed dynamically at runtime (e.g.
# `src_$1` where `$1` is a per-source slug).  Recording them here keeps
# the diff honest -- a future static `src_*` id would still surface,
# and removal here would re-fail the test.
KNOWN_DYNAMIC_PROMPT_IDS: frozenset[str] = frozenset({
    "src_$1",
})

# IDs that StepCatalog.canonicalOrder owns but install.sh does not
# emit via `progress` / `gui_step_begin`.  These are GUI-side rows the
# sidebar pre-renders; they may also be ticked by the PHASE-driven
# advance logic in InstallerCoordinator.  Recording them keeps the
# DEAD-HANDLER warning targeted at real drift.
KNOWN_GUI_ONLY_CANONICAL_IDS: frozenset[str] = frozenset({
    "license_entry",   # GUI-only step before install.sh launches
    "prereq_check",    # PHASE-driven sidebar tick (step "..." callsite)
    "setup_questions", # PHASE-driven sidebar tick
    "health_check",    # PHASE-driven sidebar tick
})

# Existing drift on main at the point this contract test landed.
# Each entry is a STEP_BEGIN id emitted by install.sh that does NOT
# have a corresponding entry in StepCatalog.canonicalOrder.  These
# show as out-of-band sidebar rows today.  Follow-on bugs filed per
# entry; this allowlist lets the contract test ship green so future
# drift surfaces immediately.  REMOVE entries from this set as their
# follow-on bugs land.
#
# DO NOT add new entries here without filing the matching follow-on
# bug -- the whole point of this test is that new drift must be
# fixed, not accumulated.
#
# As of 2026-05-19 both original entries are closed (fix/contract-
# test-backfill-drift-2026-05-19): the Vane progress callsite was
# given the explicit id `vane_install` and both `vane_install` +
# `knowledge_setup` were registered in StepCatalog.canonicalOrder
# (with HintCopy.json metadata).  The constant is kept as an empty
# frozenset so the lookup site below stays static-typed and so a
# future drift episode has an obvious place to land.
KNOWN_BACKFILL_DRIFT_STEP_IDS: frozenset[str] = frozenset()


def _run_extractor(rel_path: str) -> dict:
    """Run an extractor script and return its parsed JSON manifest."""
    script = REPO_ROOT / rel_path
    result = subprocess.run(
        [sys.executable, str(script)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class InstallGuiContractTest(unittest.TestCase):
    """Diff emissions against handlers and surface drift."""

    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.emissions_manifest = _run_extractor("scripts/extract_install_protocol.py")
        cls.handlers_manifest = _run_extractor("gui/scripts/extract_gui_renderers.py")
        cls.emissions: list[dict] = cls.emissions_manifest["emissions"]
        cls.handlers: list[dict] = cls.handlers_manifest["handlers"]
        cls.prompt_kinds: list[str] = cls.handlers_manifest["prompt_kinds"]
        cls.soft_unknown_ok: set[str] = set(cls.handlers_manifest["soft_unknown_ok"])

    def _print(self, *args: object) -> None:
        """Print to stderr so notes/warnings surface in unittest output."""
        print(*args, file=sys.stderr)

    def test_prompt_kinds_match_swift_enum(self) -> None:
        """Every PROMPT emission's `kind=` value is a PromptKind case."""
        allowed = set(self.prompt_kinds)
        self.assertGreater(
            len(allowed),
            0,
            "Could not extract PromptKind enum cases from ProgressProtocol.swift",
        )
        offences: list[str] = []
        for e in self.emissions:
            if e["kind"] != "PROMPT":
                continue
            args = e.get("args") or []
            if len(args) < 2:
                offences.append(
                    f"PROTOCOL DRIFT: PROMPT emission lacks a kind arg\n"
                    f"  emitted at: {e['file']}:{e['line']} id={e.get('id_or_name')!r}"
                )
                continue
            bash_kind = args[1]
            if bash_kind not in allowed:
                offences.append(
                    f"PROTOCOL DRIFT: PROMPT emission uses unknown kind\n"
                    f"  event: PROMPT id={e.get('id_or_name')!r} kind={bash_kind!r}\n"
                    f"  emitted at: {e['file']}:{e['line']}\n"
                    f"  expected one of: {sorted(allowed)}\n"
                    f"  fix: add a case to PromptKind in "
                    f"gui/OstlerInstaller/ProgressProtocol.swift OR change the "
                    f"bash callsite to use an existing kind."
                )
        if offences:
            self.fail("\n\n".join(offences))

    def test_event_kinds_are_known_to_decoder(self) -> None:
        """Every emitted event kind has a Swift decoder arm OR is soft."""
        decoder_kinds = {
            h["kind"] for h in self.handlers
            if h["handler_symbol"] and h["handler_symbol"].startswith("ProgressDecoder")
        }
        self.assertGreater(
            len(decoder_kinds),
            0,
            "Could not extract decoder case arms from ProgressProtocol.swift",
        )
        emitted_kinds: dict[str, dict] = {}
        for e in self.emissions:
            emitted_kinds.setdefault(e["kind"], e)
        offences: list[str] = []
        for kind, sample in emitted_kinds.items():
            if kind in decoder_kinds:
                continue
            if kind in self.soft_unknown_ok:
                self._print(
                    f"NOTE: emission kind {kind!r} has no Swift handler "
                    f"(documented as soft-unknown).\n"
                    f"  first seen at: {sample['file']}:{sample['line']}"
                )
                continue
            offences.append(
                f"PROTOCOL DRIFT: emission kind has no Swift handler\n"
                f"  event: {kind}\n"
                f"  first seen at: {sample['file']}:{sample['line']}\n"
                f"  fix: add `case \"{kind}\":` to ProgressDecoder.decode in "
                f"gui/OstlerInstaller/ProgressProtocol.swift, OR add {kind!r} "
                f"to soft_unknown_ok in gui/scripts/extract_gui_renderers.py "
                f"if the GUI intentionally falls through to .unknown."
            )
        if offences:
            self.fail("\n\n".join(offences))

    def test_step_begin_ids_have_canonical_order_entry(self) -> None:
        """Every STEP_BEGIN id is either in canonicalOrder OR dynamic.

        Hard fail: a STEP_BEGIN with a static id NOT in canonicalOrder
        will surface in the sidebar as an out-of-band row.  Pre-launch
        we want the sidebar curated, so we fail on these unless the
        id is documented as dynamic (KNOWN_DYNAMIC_PROMPT_IDS) or the
        id is in canonicalOrder.
        """
        canonical_steps = {
            h["id_or_name"] for h in self.handlers
            if h["kind"] == "STEP_BEGIN"
            and h["handler_symbol"] == "StepCatalog.canonicalOrder"
        }
        self.assertGreater(
            len(canonical_steps),
            0,
            "Could not extract canonicalOrder from StepCatalog.swift",
        )
        emitted_step_ids: dict[str, dict] = {}
        for e in self.emissions:
            if e["kind"] != "STEP_BEGIN":
                continue
            sid = e.get("id_or_name")
            if not sid or sid == "$id":
                # gui_step_begin's own wrapper signature -- skip.
                continue
            emitted_step_ids.setdefault(sid, e)

        offences: list[str] = []
        for sid, sample in emitted_step_ids.items():
            if sid in canonical_steps:
                continue
            if sid in KNOWN_DYNAMIC_PROMPT_IDS:
                continue
            if sid in KNOWN_BACKFILL_DRIFT_STEP_IDS:
                self._print(
                    f"BACKFILL DRIFT (warn -- follow-on bug filed): "
                    f"STEP_BEGIN id {sid!r} has no canonicalOrder entry.\n"
                    f"  emitted at: {sample['file']}:{sample['line']}"
                )
                continue
            offences.append(
                f"PROTOCOL DRIFT: STEP_BEGIN id has no canonicalOrder entry\n"
                f"  event: STEP_BEGIN id={sid!r}\n"
                f"  emitted at: {sample['file']}:{sample['line']}\n"
                f"  fix: add {sid!r} to StepCatalog.canonicalOrder in "
                f"gui/OstlerInstaller/Steps/StepCatalog.swift so the "
                f"sidebar pre-renders the row."
            )

        # Soft warn for dead canonicalOrder entries (entries in
        # canonicalOrder that install.sh never emits as a STEP_BEGIN).
        # These may be PHASE-driven sidebar ticks; we warn but do not
        # fail unless the id is also not phase-emitted.
        emitted_phase_ids = {
            e.get("id_or_name") for e in self.emissions if e["kind"] == "PHASE"
        }
        for canon in sorted(canonical_steps):
            if canon in emitted_step_ids:
                continue
            if canon in emitted_phase_ids:
                # Phase-driven sidebar tick -- the sidebar advances via
                # advanceSidebarFromPhase.  Not a fail.
                continue
            if canon in KNOWN_GUI_ONLY_CANONICAL_IDS:
                continue
            self._print(
                f"DEAD HANDLER (warn only): canonicalOrder lists {canon!r} "
                f"but install.sh never emits STEP_BEGIN/PHASE for it.\n"
                f"  fix: remove {canon!r} from StepCatalog.canonicalOrder OR "
                f"add a `progress \"...\" \"{canon}\"` / `step \"...\" \"{canon}\"` "
                f"callsite in install.sh."
            )

        if offences:
            self.fail("\n\n".join(offences))

    def test_phase_ids_known_or_dynamic(self) -> None:
        """PHASE emissions either match canonicalOrder OR surface as NOTE.

        The Swift coordinator tolerates unknown PHASE ids (it just
        records the phase title and skips the sidebar advance), so
        unknown PHASE ids are not a fail -- but we surface them as
        NOTE so an operator can decide whether to register them.
        """
        canonical_phase_ids = {
            h["id_or_name"] for h in self.handlers
            if h["kind"] == "PHASE"
            and h["handler_symbol"] == "StepCatalog.canonicalOrder"
        }
        for e in self.emissions:
            if e["kind"] != "PHASE":
                continue
            pid = e.get("id_or_name")
            if not pid or pid in canonical_phase_ids:
                continue
            self._print(
                f"NOTE: PHASE id {pid!r} is not in canonicalOrder "
                f"(out-of-band phase; sidebar will not advance for it).\n"
                f"  emitted at: {e['file']}:{e['line']}"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
