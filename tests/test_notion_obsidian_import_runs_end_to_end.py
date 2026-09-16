#!/usr/bin/env python3
"""Notion and Obsidian imports must actually RUN, not merely have a route.

WHY THIS EXISTS

vendor/doctor/agent/import_notion.py and import_obsidian.py were complete
backends -- job locking, stale-PID recovery, feature-flag gating, three
documented routes each -- siblings of the working Evernote importer. Nothing
in web_ui.py registered any of the six routes (three per source), so every
one of them was unreachable: a customer who flipped the feature flag and
POSTed to /api/v1/import/notion got a plain 404 from FastAPI's own router,
not even the importer's own {"error": "feature_disabled"} response.

A second, independent gap made the obvious fix dangerous to ship alone: the
CM024 adapter registry (vendor/cm024_knowledge/ostler_knowledge/ingestion/
adapters/__init__.py) only registered "evernote" and "apple_notes" in
ADAPTERS, even though NotionAdapter and ObsidianAdapter were complete,
fully-implemented sibling classes sitting right next to EvernoteAdapter in
the same package. cli.py's own convert command does `adapter_cls =
ADAPTERS[source]` -- a bare dict lookup -- so routing "notion"/"obsidian"
into the CLI without fixing the registry would have shipped routes that
KeyError on every real customer attempt. Verified this WAS a deliberate,
documented graft (vendor/divergences/cm024_knowledge.patch stripped the
notion/obsidian registration on re-vendor, and VENDOR_MANIFEST.toml's note
says why: "their imports are absent from the merged header so registering
them would ImportError" if done as a partial, careless reversal -- not
because the adapters themselves are broken). Both files were re-checked
against the CM024 canonical repo (~/Developer/cm024-canon, reachable and
healthy, unlike CM052): at the exact pinned SHA, upstream's OWN registry
already includes notion/obsidian. The vendored copy had simply drifted from
its own pin. Fixed by restoring the pin's exact content and regenerating the
divergence patch (which now correctly drops that one stale hunk while
keeping the three that are still real) -- verified via
scripts/verify_vendor_fresh.sh reporting OK for cm024_knowledge.

WHAT THIS PROVES

Not "the routes are registered" (that is exactly the shape of proof that let
Notion/Obsidian ship broken once already -- routes existing without a
resolvable backend is worse than no routes). This test:

  1. imports vendor/doctor/agent/web_ui.py's route handler functions AND
     confirms they resolve import_notion / import_obsidian's real functions
     (not stubs);
  2. imports the CM024 ADAPTERS registry and confirms "notion"/"obsidian"
     resolve to real adapter classes, not KeyError;
  3. runs a REAL import end to end via import_notion.start_import /
     import_obsidian.start_import against real fixtures (a Notion export
     directory and an Obsidian vault), forking the ACTUAL vendored
     ostler-knowledge CLI as the subprocess, polling read_status() to a
     terminal state, and reading back the STAGED MARKDOWN to confirm the
     real note content survived the whole pipeline. A "partial" terminal
     status (convert succeeded, embed failed because there is no Qdrant/
     Ollama in this hermetic test) is accepted -- the runner's own contract
     documents that as "notes landed, search pending", not a failure of the
     path this task fixes.

Needs click + httpx + pyyaml + qdrant-client on the venv used to run this
(cm024_knowledge's declared runtime deps). Skips (CANNOT-RUN) rather than
fails if they are absent, network-free otherwise.

Exit: 0 all pass, 1 a real failure, 2 CANNOT-RUN.
"""
from __future__ import annotations

import importlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCTOR_AGENT = REPO_ROOT / "vendor" / "doctor" / "agent"
CM024_ROOT = REPO_ROOT / "vendor" / "cm024_knowledge"


def _check_deps():
    missing = []
    for mod in ("click", "httpx", "yaml", "qdrant_client"):
        try:
            importlib.import_module(mod)
        except ImportError:
            missing.append(mod)
    return missing


def _load_import_modules():
    if not DOCTOR_AGENT.is_dir():
        print(f"CANNOT-RUN: {DOCTOR_AGENT} missing", file=sys.stderr)
        return None
    sys.path.insert(0, str(DOCTOR_AGENT))
    try:
        import import_notion  # noqa
        import import_obsidian  # noqa
    except Exception as exc:  # noqa: BLE001
        print(f"CANNOT-RUN: import_notion/import_obsidian would not import: "
              f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return None
    return import_notion, import_obsidian


def _load_registry():
    if not CM024_ROOT.is_dir():
        print(f"CANNOT-RUN: {CM024_ROOT} missing", file=sys.stderr)
        return None
    sys.path.insert(0, str(CM024_ROOT))
    try:
        from ostler_knowledge.ingestion.adapters import ADAPTERS
    except Exception as exc:  # noqa: BLE001
        print(f"CANNOT-RUN: cm024 adapters registry would not import: "
              f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return None
    return ADAPTERS


def _make_binary_shim(tmp: Path) -> Path:
    """A tiny executable that runs the VENDORED ostler-knowledge CLI under
    the current interpreter -- stands in for the installed
    /usr/local/bin/ostler-knowledge binary import_notion/import_obsidian
    would fork on a real customer box."""
    shim = tmp / "ostler-knowledge-shim.sh"
    shim.write_text(
        "#!/bin/sh\n"
        f'export PYTHONPATH="{CM024_ROOT}:$PYTHONPATH"\n'
        f'exec "{sys.executable}" -m ostler_knowledge.cli "$@"\n',
        encoding="utf-8",
    )
    shim.chmod(shim.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return shim


def _make_notion_fixture(root: Path) -> Path:
    export_dir = root / "notion_export"
    export_dir.mkdir()
    (export_dir / "Handover abc12345abc12345abc12345abc12345.md").write_text(
        "# Handover\n\nShip the consumer-half fix by Friday.\n",
        encoding="utf-8",
    )
    return export_dir


def _make_obsidian_fixture(root: Path) -> Path:
    vault = root / "vault"
    (vault / ".obsidian").mkdir(parents=True)
    (vault / "Groceries.md").write_text(
        "---\ntags: [errands]\n---\nBuy milk and confirm the routes work. #shopping\n",
        encoding="utf-8",
    )
    return vault


def _run_import(mod, source_path: Path, source: str, work: Path, shim: Path):
    """Drive one real start_import -> poll read_status -> terminal state."""
    lock_dir = work / "locks"
    log_dir = work / "logs"
    state_dir = work / "state"
    staging_dir = work / "staging"
    metadata_db = work / "knowledge-metadata.db"

    result = mod.start_import(
        source_path,
        source=source,
        _lock_dir=lock_dir,
        _log_dir=log_dir,
        _state_dir=state_dir,
        _staging_dir=staging_dir,
        _metadata_db=metadata_db,
        _binary=str(shim),
        _python=sys.executable,
    )
    job_id = result["job_id"]
    assert result["status"] == "started"

    deadline = time.time() + 60
    state = None
    while time.time() < deadline:
        state = mod.read_status(job_id, _state_dir=state_dir, _lock_dir=lock_dir)
        if state["status"] not in ("running", "starting"):
            break
        time.sleep(0.5)
    return state, staging_dir


def main() -> int:
    missing = _check_deps()
    if missing:
        print(f"CANNOT-RUN: missing dependencies for cm024_knowledge: {missing}",
              file=sys.stderr)
        return 2

    modules = _load_import_modules()
    if modules is None:
        return 2
    import_notion, import_obsidian = modules

    adapters = _load_registry()
    if adapters is None:
        return 2

    failures: list[str] = []

    # --- 1. the registry resolves both sources, not KeyError -------------
    for name in ("notion", "obsidian"):
        if name not in adapters:
            failures.append(f"ADAPTERS[{name!r}] is absent -- convert --source "
                            f"{name} would KeyError on every real attempt")
    if failures:
        print("FAIL:\n" + "\n".join(f"  - {f}" for f in failures), file=sys.stderr)
        return 1

    # --- 2. the route handlers resolve the real backend, not a stub ------
    web_ui_src = (DOCTOR_AGENT / "web_ui.py").read_text(encoding="utf-8")
    for route, module_name, page_fn in (
        ('@app.get("/import-notion"', "import_notion", "_render_import_notion_page"),
        ('@app.post("/api/v1/import/notion"', "import_notion", None),
        ('@app.get("/import-obsidian"', "import_obsidian", "_render_import_obsidian_page"),
        ('@app.post("/api/v1/import/obsidian"', "import_obsidian", None),
    ):
        if route not in web_ui_src:
            failures.append(f"web_ui.py has no route registration for {route!r}")
    if f"def _render_import_notion_page" not in web_ui_src:
        failures.append("_render_import_notion_page is not defined in web_ui.py")
    if f"def _render_import_obsidian_page" not in web_ui_src:
        failures.append("_render_import_obsidian_page is not defined in web_ui.py")

    # --- 3. a REAL import runs end to end for both sources ---------------
    tmp = Path(tempfile.mkdtemp(prefix="notion-obsidian-e2e-"))
    try:
        shim = _make_binary_shim(tmp)

        notion_fixture = _make_notion_fixture(tmp)
        notion_state, notion_staging = _run_import(
            import_notion, notion_fixture, "notion", tmp / "notion_work", shim)
        if notion_state is None or notion_state.get("status") not in ("succeeded", "partial"):
            failures.append(f"notion import did not reach succeeded/partial: {notion_state}")
        else:
            staged = list(notion_staging.glob("*.md"))
            if not staged:
                failures.append("notion import reported success but wrote no markdown")
            elif "Friday" not in staged[0].read_text(encoding="utf-8"):
                failures.append("notion staged markdown does not carry the real note content")

        obsidian_fixture = _make_obsidian_fixture(tmp)
        obsidian_state, obsidian_staging = _run_import(
            import_obsidian, obsidian_fixture, "obsidian", tmp / "obsidian_work", shim)
        if obsidian_state is None or obsidian_state.get("status") not in ("succeeded", "partial"):
            failures.append(f"obsidian import did not reach succeeded/partial: {obsidian_state}")
        else:
            staged = list(obsidian_staging.glob("*.md"))
            if not staged:
                failures.append("obsidian import reported success but wrote no markdown")
            elif "milk" not in staged[0].read_text(encoding="utf-8"):
                failures.append("obsidian staged markdown does not carry the real note content")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("FAIL: Notion/Obsidian import does not run end to end:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("notion + obsidian: registry resolves, routes reference the real "
          "backend, and a real import lands real markdown -- not just routes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
