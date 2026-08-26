#!/usr/bin/env python3
# scripts/verify_cut_manifest.py
# ============================================================================
# Cut manifest gate — fail-closed proof that every fix a cut declares is
# actually baked into the shipped artefact.
#
# Reads cut-manifests/permanent.yaml + cut-manifests/<version>.yaml, walks
# each entry, dispatches on proof.kind, prints a table, exits non-zero on any
# RED.
#
# Ships alongside the sibling gates in scripts/:
#   - verify_cut_freshness.sh   — vendored SHAs are fresh
#   - verify_cut_provenance.sh  — cut markers manifest
#   - provenance_gate.sh        — required_fixes.tsv content-provenance
#   - verify_cut_manifest.py    — THIS SCRIPT (11-primitive YAML gate)
#
# See cut-manifests/README.md for schema.
# ============================================================================

import argparse
import fnmatch
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Callable

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Install with: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Paths + target resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
CM051_DIR = SCRIPT_DIR.parent

# Default APP_PATH matches gui/Makefile's dist convention.
DEFAULT_APP_PATH = Path(f"/tmp/ostler-installer-dist-{os.environ.get('USER', 'nobody')}") / "OstlerInstaller.app"


def bundle_main_binary(bundle: Path) -> Path:
    """Path to a bundle's declared main executable.

    Read from CFBundleExecutable, never hardcoded. This path was pinned to
    "zeroclaw-desktop" -- a name retired in the ZeroClaw -> Ostler rename; the
    Hub binary is now "ostler-hub". A hardcoded executable name fails the cut
    against a bundle that is perfectly correct, and (worse) would happily pass
    a bundle whose real executable was missing so long as a stale-named file
    sat beside it. Ask the bundle what it actually execs.
    """
    try:
        with (bundle / "Contents" / "Info.plist").open("rb") as fh:
            exe = plistlib.load(fh).get("CFBundleExecutable")
    except Exception:
        exe = None
    # Fall back to the bundle's own name (the Apple default) so an unreadable
    # Info.plist surfaces as the caller's own missing-file error rather than
    # as an exception from here.
    return bundle / "Contents" / "MacOS" / (exe or bundle.stem)


def resolve_target(target: str, app_path: Path, cm051_dir: Path, extra_paths: dict[str, Path]) -> Path:
    """Resolve a semantic target name to a filesystem path."""
    daemon_app = app_path / "Contents" / "Resources" / "Ostler.app"
    m = {
        "installer": cm051_dir / "install.sh",           # file (grep target)
        "installer-tree": cm051_dir,                     # dir (plist/file-exists target)
        "installer-app": app_path,
        "daemon-app": daemon_app,
        "daemon-web-bundle": daemon_app / "Contents" / "Resources",
        # Tauri packs web/dist compressed inside the main binary; strings(1)
        # cannot grep those. For UI-string fixes, prefer grep_in_source_at_sha
        # on the ostler-assistant repo. `daemon-binary` still works for Rust-
        # literal strings the compiler emits verbatim (log messages, panic
        # strings, format literals).
        "daemon-binary": bundle_main_binary(daemon_app),
        "vendored-context-refresh": app_path / "Contents" / "Resources" / "context-refresh",
        "vendored-wiki-recompile": app_path / "Contents" / "Resources" / "wiki-recompile",
    }
    m.update(extra_paths)
    if target in m:
        return m[target]
    raise ValueError(f"unknown target: {target!r}. Known: {sorted(m.keys())}")


def resolve_source_repo(target: str, cm051_dir: Path) -> Path:
    """Resolve a source-at-sha target to the repo checkout path.

    Env-var overrides (match provenance_gate.sh convention):
      OSTLER_ASSISTANT_DIR  — override for ostler-assistant
      CM044_DIR             — override for CM044 personal wiki
      HR015_DIR             — override for HR015
    Fallback discovery: walk up parents from cm051_dir looking for the sibling.
    """
    if target in ("this-repo", "cm051"):
        # 🔴 RESOLVE TO THE CHECKOUT UNDER VERIFICATION, NEVER TO THE PRIMARY CLONE.
        #
        # This used to hop from a worktree to the primary checkout via
        # --git-common-dir. That reads whatever branch a developer happened to
        # leave the main clone on, NOT the ref being cut. On 2026-08-26 it graded
        # v1.0.47's three brick-fix rows against a stale local QA branch
        # (qa/walk-probes-from-v1045, HEAD 744a3197) which predates the fix, and
        # reported hits=0 for patterns that are present three times over on main.
        # Three FALSE REDs on the row that matters most.
        #
        # A linked worktree is a first-class checkout: `git -C <worktree> show
        # HEAD:path` resolves the worktree's own HEAD, which IS the version under
        # test. That is exactly what we want, so use cm051_dir as given.
        return cm051_dir

    env_key = {"ostler-assistant": "OSTLER_ASSISTANT_DIR", "cm044": "CM044_DIR", "hr015": "HR015_DIR"}.get(target)
    if env_key and os.environ.get(env_key):
        return Path(os.environ[env_key]).expanduser().resolve()

    basename = {
        "ostler-assistant": "ostler-assistant",
        "cm044": "CM044 - PWG Personal Wiki",
        "hr015": "HR015 - Gaming PC",
    }.get(target)
    if basename is None:
        raise ValueError(f"unknown source-at-sha target: {target!r}. Known: this-repo, cm051, ostler-assistant, cm044, hr015")

    # Walk up from cm051_dir looking for the sibling repo.
    probe = cm051_dir
    for _ in range(6):
        candidate = probe / basename
        if (candidate / ".git").exists():
            return candidate
        parent_candidate = probe.parent / basename
        if (parent_candidate / ".git").exists():
            return parent_candidate
        probe = probe.parent
        if probe == probe.parent:
            break
    # Return an intentionally-not-a-git path so caller reports SKIP with reason.
    return cm051_dir.parent / basename


# ---------------------------------------------------------------------------
# Result + output plumbing
# ---------------------------------------------------------------------------

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


@dataclass
class Result:
    id: str
    title: str
    kind: str
    status: str          # "PASS" | "FAIL" | "SKIP"
    detail: str = ""
    source_pr: str = ""


def emit(res: Result, colour: bool) -> None:
    if colour:
        badge = {"PASS": f"{GREEN}PASS{RESET}", "FAIL": f"{RED}FAIL{RESET}", "SKIP": f"{YELLOW}SKIP{RESET}"}[res.status]
    else:
        badge = res.status
    print(f"  {badge}  {res.id:<40} {res.title[:80]}")
    if res.detail and (res.status != "PASS"):
        print(f"        {DIM if colour else ''}{res.detail}{RESET if colour else ''}")


# ---------------------------------------------------------------------------
# Grep helpers
# ---------------------------------------------------------------------------

# Text files we grep; binaries go through `strings`.
_TEXT_EXTS = {".sh", ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".yaml", ".yml",
              ".toml", ".md", ".txt", ".html", ".css", ".xml", ".plist", ".rs",
              ".swift", ".conf", ".ini", ".env"}


def _pattern_hits_bytes(data: bytes, pattern: str) -> int:
    """Count regex matches, tolerating non-UTF8 bytes by decoding permissively."""
    try:
        text = data.decode("utf-8", errors="replace")
    except Exception:
        return 0
    return len(re.findall(pattern, text))


def _grep_file(path: Path, pattern: str) -> int:
    if not path.is_file():
        return 0
    try:
        return _pattern_hits_bytes(path.read_bytes(), pattern)
    except (PermissionError, OSError):
        return 0


def _grep_tree(root: Path, pattern: str, only_path: str | None) -> int:
    if only_path:
        return _grep_file(root / only_path, pattern)
    if root.is_file():
        return _grep_file(root, pattern)
    if not root.is_dir():
        return 0
    total = 0
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        suffix = p.suffix.lower()
        # Grep any file we recognise as text; the binary primitive handles Mach-O.
        if suffix in _TEXT_EXTS or (suffix == "" and p.stat().st_size < 500_000):
            total += _grep_file(p, pattern)
    return total


def _grep_binary_strings(binary: Path, pattern: str) -> int:
    if not binary.is_file():
        return 0
    try:
        result = subprocess.run(
            ["/usr/bin/strings", "-a", str(binary)],
            capture_output=True, check=False, timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 0
    return _pattern_hits_bytes(result.stdout, pattern)


def _is_gate_definition_file(p: Path) -> bool:
    """True for the gate's OWN files (manifests + verifiers).

    The operator-PII manifest entries literally contain the patterns they ban
    (e.g. `gamingrig`). A whole-tree scan must never flag the manifest that
    defines the pattern, so these are excluded. Belt-and-braces: the built
    OstlerInstaller.app doesn't bundle cut-manifests/ or the verifier anyway,
    but this keeps the scan safe if pointed at a repo checkout or a DMG root
    that carries repo files.
    """
    if "cut-manifests" in p.parts:
        return True
    if p.name.startswith("verify_cut_manifest"):
        return True
    return False


def _iter_dmg_tree_scan_files(root: Path):
    """Yield (path, use_strings) for every file under `root` worth scanning for
    operator-PII, faithful to "anywhere in the shipped DMG".

    - Text-extension files and small (<500KB) extensionless files are read as
      text (`use_strings=False`).
    - Large (>=500KB) extensionless files are Mach-O-shaped binaries; they are
      scanned via strings(1) (`use_strings=True`) so verbatim Rust/Swift-literal
      PII compiled into a binary is still caught.
    - The gate's own pattern-definition files are skipped.

    NOTE (documented limitation): Tauri packs the daemon's web/dist COMPRESSED
    inside its main binary, so neither a text read nor strings(1) can reach
    operator-PII living in the compiled+compressed web bundle. That residual
    class is covered by grep_in_source_at_sha on ostler-assistant, not here.
    """
    if root.is_file():
        yield (root, False)
        return
    if not root.is_dir():
        return
    for p in root.rglob("*"):
        if p.is_symlink() or not p.is_file():
            continue
        if _is_gate_definition_file(p):
            continue
        suffix = p.suffix.lower()
        if suffix in _TEXT_EXTS:
            yield (p, False)
            continue
        if suffix == "":
            try:
                size = p.stat().st_size
            except OSError:
                continue
            yield (p, size >= 500_000)


# ---------------------------------------------------------------------------
# Primitive implementations
# ---------------------------------------------------------------------------

def check_grep_in_installer(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    pattern = proof["pattern"]
    must_match = proof.get("must_match", True)
    target = ctx["cm051_dir"] / "install.sh"
    if not target.is_file():
        return Result(entry["id"], entry["title"], "grep_in_installer", "SKIP",
                      f"install.sh not found at {target}", entry.get("source_pr", ""))
    hits = _grep_file(target, pattern)
    ok = (hits > 0) if must_match else (hits == 0)
    status = "PASS" if ok else "FAIL"
    detail = f"pattern={pattern!r} must_match={must_match} hits={hits}"
    return Result(entry["id"], entry["title"], "grep_in_installer", status, detail, entry.get("source_pr", ""))


def check_grep_in_artefact(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    target_name = proof.get("target", "installer-app")
    pattern = proof["pattern"]
    must_match = proof.get("must_match", True)
    path_hint = proof.get("path")
    try:
        target = resolve_target(target_name, ctx["app_path"], ctx["cm051_dir"], ctx.get("extra_paths", {}))
    except ValueError as e:
        return Result(entry["id"], entry["title"], "grep_in_artefact", "FAIL",
                      f"target-resolution: {e}", entry.get("source_pr", ""))
    if not target.exists():
        return Result(entry["id"], entry["title"], "grep_in_artefact", "SKIP",
                      f"target {target_name!r} not present at {target} (has DMG been built?)",
                      entry.get("source_pr", ""))
    # Special case: daemon-binary uses strings(1).
    if target_name == "daemon-binary":
        hits = _grep_binary_strings(target, pattern)
    else:
        hits = _grep_tree(target, pattern, path_hint)
    ok = (hits > 0) if must_match else (hits == 0)
    status = "PASS" if ok else "FAIL"
    detail = f"target={target_name} pattern={pattern!r} must_match={must_match} hits={hits}"
    return Result(entry["id"], entry["title"], "grep_in_artefact", status, detail, entry.get("source_pr", ""))


def _matches_any_glob(path: Path, patterns: list[str]) -> bool:
    """True if path matches any glob in patterns.

    Mirrors the `[allow_paths].skip` semantics from `bin/operator-pii-scan.sh`:
    the pattern is matched against both the resolved absolute path and the
    plain string form, so callers can write either full-path globs or the
    conventional `**/basename` shorthand.
    """
    s_abs = str(path)
    s_res = str(path.resolve()) if path.exists() else s_abs
    for pat in patterns:
        if fnmatch.fnmatch(s_abs, pat) or fnmatch.fnmatch(s_res, pat):
            return True
        # `**` in fnmatch does not span directory separators the way a shell
        # glob does; add a name-only fallback so `**/basename` shorthand also
        # matches on the file's basename.
        if pat.startswith("**/") and fnmatch.fnmatch(path.name, pat[3:]):
            return True
    return False


def check_grep_in_dmg_tree(entry: dict, ctx: dict) -> Result:
    """Prove a pattern's presence/absence across the ENTIRE shipped DMG payload.

    The DMG's sole payload is OstlerInstaller.app, so scanning the built
    installer-app tree == scanning what the DMG ships. Every extractable file is
    covered: the bundled install.sh, every vendored .py/.md/.sh, the daemon
    Ostler.app (and any nested helper apps) and their text resources, plus a
    strings(1) pass over the Mach-O binaries. The source install.sh is also
    scanned so absence is still proven in a local no-build run.

    Built for the operator-PII backstop: `must_match: false` proves Andy's
    personal instance details never appear ANYWHERE in the cut, closing the hole
    where grep_in_installer only saw install.sh while PII rode in on a vendored
    tree. On a violation the detail names the offending files.

    Optional `exempt_paths: list[str]` filters legitimate references out of the
    hit set BEFORE the presence/absence decision. Mirrors the `[allow_paths].skip`
    pattern in `bin/operator-pii-scan.sh` so a `must_match: false` entry can
    ignore known-good references (for example the F6.1 "Marvin" name-suggestion
    pool that lives in `ViewCopy.json` + `install.sh.strings.en-GB.sh`, or the
    gate's own definition files inside `permanent.yaml`).
    """
    proof = entry["proof"]
    pattern = proof["pattern"]
    must_match = proof.get("must_match", True)
    exempt_paths = proof.get("exempt_paths") or []
    app_path = ctx["app_path"]
    cm051_dir = ctx["cm051_dir"]

    roots: list[Path] = []
    if app_path.exists():
        roots.append(app_path)                    # whole built OstlerInstaller.app == DMG payload
    src_install = cm051_dir / "install.sh"
    if src_install.is_file():
        roots.append(src_install)                 # source install.sh — proven even without a build

    if not roots:
        return Result(entry["id"], entry["title"], "grep_in_dmg_tree", "SKIP",
                      f"neither built app ({app_path}) nor source install.sh present",
                      entry.get("source_pr", ""))

    total = 0
    exempted = 0
    hit_paths: list[str] = []
    seen: set[Path] = set()
    for root in roots:
        for path, use_strings in _iter_dmg_tree_scan_files(root):
            rp = path.resolve()
            if rp in seen:
                continue
            seen.add(rp)
            n = _grep_binary_strings(path, pattern) if use_strings else _grep_file(path, pattern)
            if not n:
                continue
            if exempt_paths and _matches_any_glob(path, exempt_paths):
                exempted += n
                continue
            total += n
            hit_paths.append(str(path))

    ok = (total > 0) if must_match else (total == 0)
    status = "PASS" if ok else "FAIL"
    scanned = "app-tree+strings" if app_path.exists() else "source-install.sh-only (no build)"
    detail = f"scanned={scanned} pattern={pattern!r} must_match={must_match} hits={total}"
    if exempted:
        detail += f" ({exempted} exempted)"
    if hit_paths:
        shown = hit_paths[:8]
        detail += " in: " + ", ".join(shown)
        if len(hit_paths) > len(shown):
            detail += f" (+{len(hit_paths) - len(shown)} more)"
    return Result(entry["id"], entry["title"], "grep_in_dmg_tree", status, detail, entry.get("source_pr", ""))


# Surfaces that DESCRIBE the gates rather than implement them. A whole-tree
# grep must never be satisfied by one of these: the row's own `pattern:` is
# sitting in its own manifest, so `must_match: true` would be true the moment
# the row is written, with the fix entirely absent.
#
# 🔴 THIS IS HOW v1.0.46 SHIPPED BRICKED WITH A GREEN GATE.
# Row v1046-c-the-bricking-fix-is-in-the-pinned-source grepped for
# 'PYTHONPYCACHEPREFIX' with must_match: true. Its path_hint was silently
# dropped (see _PROOF_KEYS below), so it whole-tree grepped at the pinned sha
# d297cc59 and matched cut-manifests/v1.0.46.yaml FIVE TIMES, plus
# cut-deferrals.yaml, cuts/DEFECTS_ROLLFORWARD.md and cuts/v1.0.46/cut.env.
# The row asserting "the bricking fix is in the pinned source" was satisfied by
# the prose describing the row. It would have gone green with zero fix present.
_SELF_DESCRIBING_PREFIXES = ("cut-manifests/", "cuts/", "walks/")
_SELF_DESCRIBING_FILES = ("cut-deferrals.yaml",)


def _is_self_describing(path: str) -> bool:
    return path.startswith(_SELF_DESCRIBING_PREFIXES) or path in _SELF_DESCRIBING_FILES


# Every key this proof kind understands. Anything else is a typo, and a typo
# must be LOUD: `path_hint:` was accepted by the YAML and ignored by the reader
# for four rows, silently converting a targeted file check into a whole-tree
# one. A key we do not consume is a check we are not performing.
# `repo:` is a third spelling live rows already use for the same registry as
# `target:` (this-repo / cm051 / ostler-assistant / cm044 / hr015). All four
# rows carrying it say `repo: cm051`, which resolves the same as the
# `this-repo` default — so it was correct BY COINCIDENCE, not by construction.
# A row saying `repo: ostler-assistant` would have silently grepped CM051.
_PROOF_KEYS = {"kind", "target", "repo", "pattern", "must_match", "path", "path_hint"}


def check_grep_in_source_at_sha(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    unknown = sorted(set(proof) - _PROOF_KEYS)
    if unknown:
        return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                      f"unknown proof key(s) {unknown} — refusing to run a check whose "
                      f"instructions were not fully understood", entry.get("source_pr", ""))
    target_name = proof.get("target") or proof.get("repo") or "this-repo"
    pattern = proof["pattern"]
    must_match = proof.get("must_match", True)
    # `path_hint` is the spelling four live rows already use. Honour both rather
    # than silently ignoring one of them.
    path_hint = proof.get("path") or proof.get("path_hint")
    source_sha = entry.get("source_sha")
    try:
        repo = resolve_source_repo(target_name, ctx["cm051_dir"])
    except ValueError as e:
        return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                      f"source-resolution: {e}", entry.get("source_pr", ""))
    if not (repo / ".git").exists() and not (repo / ".git").is_file():
        return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "SKIP",
                      f"repo not a git checkout: {repo}", entry.get("source_pr", ""))
    sha = source_sha or "HEAD"
    self_described = 0
    try:
        if path_hint:
            result = subprocess.run(
                ["git", "-C", str(repo), "show", f"{sha}:{path_hint}"],
                capture_output=True, check=False, timeout=30,
            )
            if result.returncode != 0:
                return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                              f"git show failed: {result.stderr.decode('utf-8', 'replace').strip()[:200]}",
                              entry.get("source_pr", ""))
            hits = _pattern_hits_bytes(result.stdout, pattern)
        else:
            # Grep the whole tree at that sha via git grep.
            result = subprocess.run(
                ["git", "-C", str(repo), "grep", "-c", "--extended-regexp", "-e", pattern, sha, "--"],
                capture_output=True, check=False, timeout=60,
            )
            # git grep exits 1 for "no match"; 0 for "found"; 2 for error.
            if result.returncode == 2:
                return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                              f"git grep error: {result.stderr.decode('utf-8', 'replace').strip()[:200]}",
                              entry.get("source_pr", ""))
            hits = 0
            for line in result.stdout.decode("utf-8", "replace").splitlines():
                # format: "<sha>:<path>:<count>"
                head, _, count = line.rpartition(":")
                # Drop the leading "<sha>:" to recover the repo-relative path.
                _, _, rel = head.partition(":")
                if _is_self_describing(rel):
                    # The manifest/ledger surfaces describe the check; they are
                    # not evidence that the code carries it.
                    self_described += 1
                    continue
                try:
                    hits += int(count)
                except ValueError:
                    pass
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                      f"git invocation failed: {e}", entry.get("source_pr", ""))
    ok = (hits > 0) if must_match else (hits == 0)
    status = "PASS" if ok else "FAIL"
    scope = f"path={path_hint}" if path_hint else "whole-tree"
    detail = (f"target={target_name} repo={repo} sha={sha[:12]} {scope} "
              f"pattern={pattern!r} must_match={must_match} hits={hits}")
    if self_described:
        detail += (f" ({self_described} match(es) DISCARDED in manifest/ledger surfaces — "
                   f"a row is not evidence of itself)")
    return Result(entry["id"], entry["title"], "grep_in_source_at_sha", status, detail, entry.get("source_pr", ""))


def check_file_exists_in_artefact(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    target_name = proof.get("target", "installer-app")
    path_hint = proof["path"]
    try:
        target = resolve_target(target_name, ctx["app_path"], ctx["cm051_dir"], ctx.get("extra_paths", {}))
    except ValueError as e:
        return Result(entry["id"], entry["title"], "file_exists_in_artefact", "FAIL",
                      f"target-resolution: {e}", entry.get("source_pr", ""))
    if not target.exists():
        return Result(entry["id"], entry["title"], "file_exists_in_artefact", "SKIP",
                      f"target {target_name!r} not present (has DMG been built?)",
                      entry.get("source_pr", ""))
    # Match by exact path first, else fall back to recursive basename lookup.
    exact = target / path_hint if target.is_dir() else None
    if exact and exact.exists():
        return Result(entry["id"], entry["title"], "file_exists_in_artefact", "PASS",
                      f"found: {exact}", entry.get("source_pr", ""))
    if target.is_dir():
        matches = list(target.rglob(path_hint))
        if matches:
            return Result(entry["id"], entry["title"], "file_exists_in_artefact", "PASS",
                          f"found via rglob: {matches[0]}", entry.get("source_pr", ""))
    return Result(entry["id"], entry["title"], "file_exists_in_artefact", "FAIL",
                  f"missing {path_hint!r} in {target_name}", entry.get("source_pr", ""))


def check_plist_key_equals(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    target_name = proof.get("target", "installer")
    path_hint = proof["path"]
    key = proof["key"]
    expected = proof["value"]
    try:
        target = resolve_target(target_name, ctx["app_path"], ctx["cm051_dir"], ctx.get("extra_paths", {}))
    except ValueError as e:
        return Result(entry["id"], entry["title"], "plist_key_equals", "FAIL",
                      f"target-resolution: {e}", entry.get("source_pr", ""))
    plist_path = target / path_hint if target.is_dir() else target
    if not plist_path.is_file():
        return Result(entry["id"], entry["title"], "plist_key_equals", "SKIP",
                      f"plist not found at {plist_path}", entry.get("source_pr", ""))
    actual_norm: str | None = None
    parse_note = ""
    try:
        with plist_path.open("rb") as f:
            data = plistlib.load(f)
        actual = data.get(key)
        if isinstance(actual, bool):
            actual_norm = "true" if actual else "false"
        elif actual is not None:
            actual_norm = str(actual).lower()
    except Exception as e:
        # Template-placeholder plists (unresolved {{ USER }} etc.) fail plistlib.
        # Fall back to a regex probe that tolerates any surrounding template
        # noise. Less exact but robust.
        parse_note = f" (plistlib fallback: {type(e).__name__})"
        try:
            raw = plist_path.read_text(encoding="utf-8", errors="replace")
            # Match <key>KEY</key> followed by the next scalar/bool tag.
            m = re.search(
                rf"<key>{re.escape(key)}</key>\s*(<(true|false)\s*/>|<(?:string|integer|real)>([^<]*)</(?:string|integer|real)>)",
                raw,
            )
            if m:
                if m.group(2):
                    actual_norm = m.group(2).lower()
                elif m.group(3) is not None:
                    actual_norm = m.group(3).lower()
        except Exception as e2:
            return Result(entry["id"], entry["title"], "plist_key_equals", "FAIL",
                          f"plist parse + regex fallback both failed: {e2}",
                          entry.get("source_pr", ""))
    if actual_norm is None:
        return Result(entry["id"], entry["title"], "plist_key_equals", "FAIL",
                      f"key {key!r} not found in {plist_path}{parse_note}",
                      entry.get("source_pr", ""))
    expected_norm = str(expected).lower()
    ok = actual_norm == expected_norm
    status = "PASS" if ok else "FAIL"
    detail = f"key={key} expected={expected_norm} actual={actual_norm}{parse_note}"
    return Result(entry["id"], entry["title"], "plist_key_equals", status, detail, entry.get("source_pr", ""))


def check_plist_env_key_present(entry: dict, ctx: dict) -> Result:
    """Assert a named env-var KEY is declared inside a plist's EnvironmentVariables
    dict, WITHOUT reading or validating the value.

    Used to prove that a fresh v1.0.12+ install ships an assistant plist that
    declares PWG_SERVICE_TOKEN as a launchd env key (per CM051 #464), without
    ever shipping the per-install secret value in the cut manifest. Existing
    v1.0.11 customers are covered by the file-fallback path in the daemon; this
    gate is the belt-and-braces backstop for the fresh-install path.

    `must_be_present: false` inverts to an absence proof.

    Follows the same template-fallback pattern as `check_plist_key_equals`: when
    plistlib cannot parse the file (unresolved template placeholders leave the
    XML ill-formed), a regex probe locates the EnvironmentVariables dict block
    and searches for `<key>KEY</key>` inside it.
    """
    proof = entry["proof"]
    target_name = proof.get("target", "installer-tree")
    path_hint = proof["path"]
    key = proof["key"]
    must_be_present = proof.get("must_be_present", True)
    try:
        target = resolve_target(target_name, ctx["app_path"], ctx["cm051_dir"], ctx.get("extra_paths", {}))
    except ValueError as e:
        return Result(entry["id"], entry["title"], "plist_env_key_present", "FAIL",
                      f"target-resolution: {e}", entry.get("source_pr", ""))
    plist_path = target / path_hint if target.is_dir() else target
    if not plist_path.is_file():
        return Result(entry["id"], entry["title"], "plist_env_key_present", "SKIP",
                      f"plist not found at {plist_path}", entry.get("source_pr", ""))
    parse_note = ""
    key_present: bool | None = None
    try:
        with plist_path.open("rb") as f:
            data = plistlib.load(f)
        env_vars = data.get("EnvironmentVariables")
        if env_vars is None:
            return Result(entry["id"], entry["title"], "plist_env_key_present", "FAIL",
                          f"plist has no EnvironmentVariables dict at {plist_path}",
                          entry.get("source_pr", ""))
        if not isinstance(env_vars, dict):
            return Result(entry["id"], entry["title"], "plist_env_key_present", "FAIL",
                          f"EnvironmentVariables is not a dict in {plist_path}",
                          entry.get("source_pr", ""))
        key_present = key in env_vars
    except Exception as e:
        parse_note = f" (plistlib fallback: {type(e).__name__})"
        try:
            raw = plist_path.read_text(encoding="utf-8", errors="replace")
            block = re.search(
                r"<key>EnvironmentVariables</key>\s*<dict>(.*?)</dict>",
                raw, re.DOTALL,
            )
            if block is None:
                return Result(entry["id"], entry["title"], "plist_env_key_present", "FAIL",
                              f"no EnvironmentVariables dict block found in {plist_path}{parse_note}",
                              entry.get("source_pr", ""))
            key_present = bool(re.search(rf"<key>{re.escape(key)}</key>", block.group(1)))
        except Exception as e2:
            return Result(entry["id"], entry["title"], "plist_env_key_present", "FAIL",
                          f"plist parse + regex fallback both failed: {e2}",
                          entry.get("source_pr", ""))
    ok = key_present == must_be_present
    status = "PASS" if ok else "FAIL"
    detail = f"key={key} must_be_present={must_be_present} present={key_present}{parse_note}"
    return Result(entry["id"], entry["title"], "plist_env_key_present", status, detail, entry.get("source_pr", ""))


# ---------------------------------------------------------------------------
# box_walk_probe — runtime gate. Invokes a named shell probe against a real
# box; captures the class of bug that static gates cannot see (the whole point
# of the token-gap tackling: seed-and-query round-trip proof).
#
# The registry maps `probe: <name>` to a file named `<name>.sh`, resolved by
# _box_walk_probe_search_dirs below -- `scripts/box_walk_probes/probes/` first,
# then the flat `scripts/box_walk_probes/`. This comment used to name only the
# flat directory, which is where the resolver used to look and where no probe
# lives any more.
# Each probe is a self-contained shell script; the primitive invokes it,
# captures exit code + stdout, and PASSes on exit 0. FAILs on any non-zero.
# SKIPs when OSTLER_BOX_HOST env var is not set (the box isn't reachable in
# the current environment — CI + local dev — and a runtime probe cannot run
# without a target).
#
# The actual probe bodies live with the Studio matrix runbook work; this
# primitive is what wires them into the cut gate.
# ---------------------------------------------------------------------------

BOX_WALK_PROBE_TIMEOUT_SECONDS = 180


def _box_walk_probe_search_dirs(cm051_dir: Path) -> list:
    """Every directory a probe may be registered in, in resolution order.

    #778. This used to return ONE directory, `scripts/box_walk_probes`, and
    resolve `<name>.sh` directly inside it. At the time the repo had TWO
    populations:

        scripts/box_walk_probes/probes/*.sh    probes with a --self-test
                                               negative control
        scripts/box_walk_probes/*.sh           1 probe, people_seed_and_retrieval,
                                               735 lines, NO negative control

    That split looked deliberate and was documented as such: the runner
    (`run_box_walk.sh`) globs `probes/` ONLY, because phase 1 demands a
    `--self-test` from everything it finds and the flat probe could not supply
    one.

    What was NOT deliberate is that this gate looked only in the flat directory
    while the runner looked only in the subdirectory. The two instruments had
    ZERO probes in common. The gate could resolve exactly one probe -- the one
    the runner never executes -- and the ones the runner does execute were
    unresolvable here, so no manifest could name them.

    Every probe now lives in `probes/`, people_seed_and_retrieval included: it
    gained a `--self-test` and moved, so the runner collects it. Both
    directories are still searched. A flat probe is no longer expected, but a
    resolver that stops finding a file the moment somebody puts it back where
    it used to be is a trap, and the coverage tests below assert over whatever
    is actually on disk rather than over an assumed layout.

    Searching both, subdirectory first, means a probe is visible to the gate
    wherever it is registered, and the coverage test in
    scripts/tests/test_verify_cut_manifest.py asserts every probe on disk is
    declared by at least one manifest row so a new one cannot go dark again.
    """
    root = cm051_dir / "scripts" / "box_walk_probes"
    return [root / "probes", root]


def _resolve_box_walk_probe(cm051_dir: Path, probe: str):
    """Return the path of `probe`, or None. Never guesses outside the registry."""
    for d in _box_walk_probe_search_dirs(cm051_dir):
        candidate = d / f"{probe}.sh"
        if candidate.is_file():
            return candidate
    return None


def check_box_walk_probe(entry: dict, ctx: dict) -> Result:
    """Invoke a named box-walk probe shell script and return its result.

    Runtime probes require the box to be reachable; when OSTLER_BOX_HOST is
    not set the primitive returns SKIP so CI + local dev pass cleanly. When
    the env var IS set the probe MUST exit 0 to PASS.
    """
    proof = entry["proof"]
    probe = proof["probe"]
    cm051_dir = ctx["cm051_dir"]

    if not os.environ.get("OSTLER_BOX_HOST"):
        # 🔴 #713. This SKIP is correct in CI and on a dev box -- there is no
        # machine to probe -- but it is NOT correct during a cut, and until
        # 2026-08-17 nothing distinguished the two.
        #
        # Measured before the fix: OSTLER_BOX_HOST is set NOWHERE. Zero hits
        # across OS003, which is the canonical cut mechanism, and in CM051 only
        # inside scripts/tests/. Two manifests declare box_walk_probe rows
        # (cut-manifests/permanent.yaml and v1.0.12.yaml), so those rows have
        # returned SKIP on every cut that has ever run, main() exits 0 while
        # fails == 0, and the summary printed a skip COUNT with no names.
        #
        # This primitive exists precisely to catch what static gates cannot --
        # the seed-and-query round trip on a real box. It is the machinery
        # behind "acceptance is the box walk, not the cut log". It had never
        # executed, and nothing said so.
        #
        # --require-runtime-proofs makes the distinction explicit rather than
        # implicit: a declared runtime proof that COULD NOT RUN is a failure,
        # because "not known to have failed" is not evidence.
        if ctx.get("require_runtime_proofs"):
            return Result(entry["id"], entry["title"], "box_walk_probe", "FAIL",
                          "OSTLER_BOX_HOST not set and --require-runtime-proofs is on: "
                          "this row declares a RUNTIME proof and no runtime proof happened",
                          entry.get("source_pr", ""))
        return Result(entry["id"], entry["title"], "box_walk_probe", "SKIP",
                      "OSTLER_BOX_HOST not set (runtime probe requires a reachable box)",
                      entry.get("source_pr", ""))

    script = _resolve_box_walk_probe(cm051_dir, probe)
    if script is None:
        searched = ", ".join(
            str(d / f"{probe}.sh") for d in _box_walk_probe_search_dirs(cm051_dir)
        )
        return Result(entry["id"], entry["title"], "box_walk_probe", "FAIL",
                      f"probe {probe!r} not registered. Searched: {searched}",
                      entry.get("source_pr", ""))
    try:
        result = subprocess.run(
            ["/bin/bash", str(script)],
            capture_output=True, check=False,
            timeout=BOX_WALK_PROBE_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return Result(entry["id"], entry["title"], "box_walk_probe", "FAIL",
                      f"probe invocation failed: {e}", entry.get("source_pr", ""))
    exit_code = result.returncode
    stdout_snippet = result.stdout.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
    stderr_snippet = result.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
    ok = (exit_code == 0)
    status = "PASS" if ok else "FAIL"
    detail = f"probe={probe} exit={exit_code} stdout={stdout_snippet[0][:200]!r}"
    if not ok and stderr_snippet[0]:
        detail += f" stderr={stderr_snippet[0][:200]!r}"
    return Result(entry["id"], entry["title"], "box_walk_probe", status, detail, entry.get("source_pr", ""))


# ---------------------------------------------------------------------------
# payload_version_matches_daemon_version — cut-time integrity check that the
# (B-lite) embedded payload version matches the actual bundled daemon binary's
# --version output. Catches "VERSION file right, wrong binary bundled" and the
# reverse. Normalises three formats to a common semver core:
#   `hub-vX.Y.Z`    -> `X.Y.Z`
#   `zeroclaw X.Y.Z` -> `X.Y.Z`
#   `X.Y.Z`         -> `X.Y.Z`
# Anything else is a parse error and FAILs the gate.
# ---------------------------------------------------------------------------

_SEMVER_CORE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def _normalise_version(raw: str) -> str:
    """Normalise a version string to its semver core, or raise ValueError.

    Accepts `hub-vX.Y.Z`, `zeroclaw X.Y.Z`, and bare `X.Y.Z`. Anything else is
    a parse error. Matches the parser TNM uses in `upgrade_reconcile::SemVer::parse`
    (oa #238) so cut-time and runtime speak the same version dialect.
    """
    s = raw.strip()
    # Strip known prefixes.
    if s.startswith("hub-v"):
        s = s[len("hub-v"):]
    elif s.startswith("zeroclaw "):
        s = s[len("zeroclaw "):]
    # If there is trailing content past the semver core (e.g. `X.Y.Z@sha`),
    # trim to the leading semver segment only.
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", s)
    if m is None:
        raise ValueError(f"unparseable version: {raw!r}")
    core = f"{m.group(1)}.{m.group(2)}.{m.group(3)}"
    if not _SEMVER_CORE.match(core):
        raise ValueError(f"unparseable version core: {raw!r}")
    return core


def check_payload_version_matches_daemon_version(entry: dict, ctx: dict) -> Result:
    """Assert `ostler-payload/VERSION` matches the cut's DAEMON_VERSION release pin.

    The bundled daemon binary reports the FROZEN Cargo workspace version
    (0.4.1) by design (releases go by git tag +1; see
    reference_ostler_assistant_version_field_frozen), so `--version` structurally
    cannot equal the release version. Instead this compares the payload VERSION
    against the authoritative release pin: env `DAEMON_VERSION` (exported by
    `make ship`), falling back to the gui/Makefile `DAEMON_VERSION ?=` default.
    Both values are normalised to the semver core via `_normalise_version` before
    comparison. The daemon binary is still checked for *presence*. SKIPs when the
    built app is not present (local dev, pre-build CI). FAILs on any read error,
    a missing/unresolvable pin, or an unparseable version. A binary-IDENTITY
    check (bundled SHA vs DAEMON_SHA256) is a separate follow-up.
    """
    app_path = ctx["app_path"]
    if not app_path.exists():
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "SKIP", f"built app not present at {app_path} (has DMG been built?)",
                      entry.get("source_pr", ""))
    payload_root = app_path / "Contents" / "Resources" / "ostler-payload"
    if not payload_root.is_dir():
        # The (B-lite) payload is embedded inside the Hub Ostler.app, which the
        # OstlerInstaller.app bundles under Contents/Resources/. When app_path is
        # the outer OstlerInstaller (the DMG-cut case), the payload lives one
        # bundle deeper -- descend into the nested Hub. (Sibling checks
        # file_exists_in_artefact resolve this via resolve_target; mirror it here.)
        _nested = sorted(app_path.glob("Contents/Resources/*.app/Contents/Resources/ostler-payload"))
        if _nested:
            payload_root = _nested[0]
    version_file = payload_root / "VERSION"

    # The payload daemon is an .app BUNDLE, not a bare binary.
    #
    # gui/Makefile:1142 dittos ../assistant-agent/OstlerAssistant.app into the
    # payload, :1143 chmods its inner binary, :1148 hard-fails if that inner
    # binary is absent, and :1163 codesign-verifies the bundle against the
    # V95N2B8X7A team pin. Since #890 (7bff33d, 2026-08-20) :1154 ALSO hard-fails
    # if the legacy bare-binary path exists at all -- install.sh upgrade-mode
    # resolves _UPG_PAYLOAD_APP first and refuses a bare binary with exit 20, so
    # shipping both shapes invites the wrong one.
    #
    # This predicate was left pointing at the legacy path when #890 moved the
    # shape. v1.0.37 was cut BEFORE #890 (03:46Z; #890 merged 09:14Z) and passed
    # honestly. v1.0.38 is the first cut after it -- and the row demanded exactly
    # the state `make ship` now refuses to build, so it could not have passed at
    # any point after #890 merged.
    #
    # Keep this path identical to the one gui/Makefile:1148 enforces. If the
    # payload shape moves again, BOTH must move together.
    daemon_app = payload_root / "assistant-agent" / "OstlerAssistant.app"
    daemon_bin = daemon_app / "Contents" / "MacOS" / "ostler-assistant"
    legacy_bin = payload_root / "assistant-agent" / "bin" / "ostler-assistant"

    if not version_file.is_file():
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"payload VERSION file missing at {version_file}",
                      entry.get("source_pr", ""))
    if not daemon_bin.is_file():
        # Name the shape drift explicitly rather than reporting a bare "missing".
        # On 2026-08-21 the undifferentiated message cost hours: it could not
        # distinguish "the daemon is absent" from "the daemon is present under a
        # path this predicate stopped tracking", and the two need opposite fixes.
        if legacy_bin.is_file():
            return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                          "FAIL",
                          f"payload carries the LEGACY bare-binary daemon at {legacy_bin} "
                          f"instead of the .app bundle at {daemon_bin} -- install.sh "
                          f"upgrade-mode refuses the bare shape with exit 20, and "
                          f"gui/Makefile:1154 refuses to build it",
                          entry.get("source_pr", ""))
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"payload daemon binary missing at {daemon_bin}",
                      entry.get("source_pr", ""))

    try:
        payload_raw = version_file.read_text(encoding="utf-8", errors="replace").strip()
    except (PermissionError, OSError) as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"reading VERSION failed: {e}", entry.get("source_pr", ""))
    # The daemon binary's `--version` reports the FROZEN Cargo workspace version
    # (0.4.1; releases go by git tag +1, Cargo is intentionally NOT bumped -- see
    # reference_ostler_assistant_version_field_frozen), so it structurally cannot
    # equal the release version and this gate could never pass for any release
    # != 0.4.1. Compare the payload VERSION against the cut's DAEMON_VERSION pin
    # (the authoritative release version) instead: env DAEMON_VERSION (exported
    # through `make ship`), falling back to the gui/Makefile `DAEMON_VERSION ?=`
    # default. A proper binary-IDENTITY gate (bundled-binary SHA vs DAEMON_SHA256)
    # is the real "did we ship the right daemon" check and is a separate follow-up
    # that --version structurally cannot provide.
    expected_raw = os.environ.get("DAEMON_VERSION", "").strip()
    if not expected_raw:
        mk = ctx["cm051_dir"] / "gui" / "Makefile"
        try:
            for line in mk.read_text(encoding="utf-8", errors="replace").splitlines():
                s = line.strip()
                if s.startswith("DAEMON_VERSION") and "?=" in s:
                    expected_raw = s.split("?=", 1)[1].strip()
                    break
        except OSError:
            pass
    if not expected_raw:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", "could not resolve DAEMON_VERSION (env or gui/Makefile pin)",
                      entry.get("source_pr", ""))

    try:
        payload_norm = _normalise_version(payload_raw)
    except ValueError as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"payload VERSION unparseable: {e}",
                      entry.get("source_pr", ""))
    try:
        expected_norm = _normalise_version(expected_raw)
    except ValueError as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"DAEMON_VERSION pin unparseable: {e}",
                      entry.get("source_pr", ""))

    ok = payload_norm == expected_norm
    status = "PASS" if ok else "FAIL"
    detail = (f"payload_raw={payload_raw!r} pinned_DAEMON_VERSION={expected_raw!r} "
              f"payload_norm={payload_norm} pin_norm={expected_norm} "
              f"(binary --version is the frozen Cargo version by design; compared vs release pin)")
    return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                  status, detail, entry.get("source_pr", ""))


# ---------------------------------------------------------------------------
# pinned_artefact_freshness -- close the class of failure where CM051 downloads
# a pre-built tarball at cut time and merged-to-main fixes in the source repo
# silently miss the DMG because the tarball was tagged BEFORE the fix merged.
#
# The v1.0.13 near-miss (2026-07-30): DAEMON_VERSION pin was hub-v0.4.39, tagged
# from oa/main at 16687ed6. By cut time oa/main had advanced 5 commits including
# task #148 (has_ever_paid sticky bit) + #149 (hub-vX.Y.Z tag-push wiring), both
# in crates/*. The pinned tarball structurally could not contain them. TNM
# caught it by inspection. This primitive catches it by mechanism.
#
# Contract:
#   1. Read pinned version from `pinned_version_source.file` using its regex
#      (capture group 1 is the version).
#   2. Format to a source-repo tag via `tag_format` (e.g. `hub-v{version}`).
#   3. `gh api repos/{source_repo}/git/refs/tags/{tag}` -> tag SHA. For
#      annotated tags (`object.type == "tag"`), follow one hop through
#      `git/tags/{sha}` to reach the commit. For lightweight tags
#      (`object.type == "commit"`), the SHA is already the commit.
#   4. `gh api repos/{source_repo}` -> `default_branch`.
#      `gh api repos/{source_repo}/branches/{default_branch}` -> HEAD SHA.
#   5. `gh api repos/{source_repo}/compare/{pin_sha}...{head_sha}` -> commits +
#      files touched between the pin and HEAD.
#   6. Ignore commits whose first-line message matches any `ignore_commits_matching`
#      regex (docs/chore-only cleanups don't affect the shipped artefact).
#   7. For every non-ignored commit, check the commit's files against
#      `source_paths` fnmatch globs. Any hit -> FAIL, with the diverging
#      commits enumerated in the detail.
#
# Fail-closed philosophy: network errors, missing tokens, missing tags, and
# malformed responses all FAIL. A transient outage that hides real divergence
# is a worse outcome than a build that has to be re-run.
# ---------------------------------------------------------------------------

GH_API_TIMEOUT_SECONDS = 30


def _repo_owner(source_repo: str) -> str:
    """Return the owner slug from `owner/repo`."""
    return source_repo.split("/", 1)[0]


def _gh_token_for(owner: str) -> str | None:
    """Resolve a gh token for `owner`, from the environment or `gh auth`.

    ENVIRONMENT FIRST, AND THAT ORDER IS THE FIX. `gh auth token --user X`
    resolves only where a human has logged three accounts in, which is the
    operator's Mac and never a hosted runner. Measured on the v1.0.26 cut: both
    freshness rows reported

        FAIL  pinned daemon tarball must contain all merged crates/* changes
              could not resolve gh token for owner 'ostler-ai'

    which is not a finding about the daemon at all -- it is the checker saying
    it could not authenticate, rendered as though it had looked and found the
    artefact stale. The gate has never once run in CI, and its verdict there
    was worse than useless because it was confidently wrong.

    OSTLER_RELEASES_TOKEN is the cross-org credential the cut already carries
    for exactly this owner, so the check can genuinely run. The generic
    OSTLER_GH_TOKEN_<OWNER> form is there so a second owner does not need a
    code change.

    Returns None only when nothing resolves. Callers must treat that as
    CANNOT-RUN, never as a defect in the artefact.
    """
    env_names = [
        "OSTLER_GH_TOKEN_" + owner.upper().replace("-", "_"),
    ]
    if owner == "ostler-ai":
        env_names.append("OSTLER_RELEASES_TOKEN")
    for name in env_names:
        tok = os.environ.get(name, "").strip()
        if tok:
            return tok
    try:
        r = subprocess.run(
            ["gh", "auth", "token", "--user", owner],
            capture_output=True, check=False, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    tok = r.stdout.decode("utf-8", "replace").strip()
    return tok or None


def _gh_api_json(path: str, token: str | None) -> tuple[dict | list | None, str]:
    """Invoke `gh api {path}` and return (parsed_json, error_string).

    On any failure returns (None, "why"). Fail-closed by design.
    """
    env = dict(os.environ)
    if token:
        env["GH_TOKEN"] = token
    try:
        r = subprocess.run(
            ["gh", "api", path],
            capture_output=True, check=False,
            timeout=GH_API_TIMEOUT_SECONDS, env=env,
        )
    except FileNotFoundError:
        return None, "gh CLI not installed"
    except subprocess.TimeoutExpired:
        return None, f"gh api {path} timed out after {GH_API_TIMEOUT_SECONDS}s"
    if r.returncode != 0:
        stderr = r.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
        return None, f"gh api {path} exit={r.returncode}: {stderr[0][:200]}"
    try:
        return json.loads(r.stdout.decode("utf-8", "replace")), ""
    except json.JSONDecodeError as e:
        return None, f"gh api {path} returned invalid JSON: {e}"


def _matches_source_path(filename: str, patterns: list[str]) -> str | None:
    """Return the first glob in `patterns` that matches `filename`, else None.

    Uses fnmatch semantics extended so `**` spans directory separators (which
    plain fnmatch does not do). Callers write `crates/**` and expect
    `crates/subscription/src/lib.rs` to match, matching the intuitive shell
    glob.
    """
    for pat in patterns:
        if "**" in pat:
            regex = "^" + re.escape(pat).replace(r"\*\*", ".*").replace(r"\*", "[^/]*") + "$"
            if re.match(regex, filename):
                return pat
        elif fnmatch.fnmatch(filename, pat):
            return pat
    return None


def _extract_pinned_version(cm051_dir: Path, source: dict) -> tuple[str | None, str]:
    """Extract the pinned version from `pinned_version_source`.

    Returns (version_or_None, error). Supports one shape today:
      { file: str, pattern: str-with-one-capture-group }
    """
    file_rel = source.get("file")
    pattern = source.get("pattern")
    if not file_rel or not pattern:
        return None, "pinned_version_source needs file + pattern"
    p = cm051_dir / file_rel
    if not p.is_file():
        return None, f"pin source file not found: {p}"
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except (PermissionError, OSError) as e:
        return None, f"reading {p}: {e}"
    m = re.search(pattern, text)
    if m is None:
        return None, f"pattern {pattern!r} did not match in {p}"
    if not m.groups():
        return None, f"pattern {pattern!r} has no capture group"
    return m.group(1), ""


def _repo_is_readable(source_repo: str, token: str | None) -> tuple[bool, str]:
    """Can this token READ `source_repo` at all?

    The GitHub API answers 404 for a private repository the caller cannot
    see, and 404 for a repository or tag that does not exist. Byte-identical
    responses, opposite meanings. Without separating them, the freshness row
    reported

        FAIL  permanent-remotecapture-freshness
              resolving tag 'remote-capture-v0.1.3' ... HTTP 404

    -- a headline asserting the pinned RemoteCapture is STALE, from evidence
    that says only "I cannot read that repo". Measured 2026-08-13: under the
    cut token that tag 404s; with the ostler-ai account the repo resolves
    (PRIVATE) and the tag resolves to 5f9ddf32. Same URL, two answers,
    differing only in scope.

    This is the same shape as the missing-token SKIP above it, one level in:
    there the credential was absent, here it is present but insufficient.

    Deliberately NOT "map 404 to SKIP". That would swallow a genuinely
    missing tag -- a real staleness defect quietly reclassified as
    not-checked, which is the warn-bucket-is-not-a-safe-bucket move. Probing
    the repo first keeps BOTH verdicts reachable:

        repo unreadable        -> CANNOT-RUN, SKIP
        repo readable, tag 404 -> genuine FAIL, the tag really is absent

    Returns (readable, why_not).
    """
    data, err = _gh_api_json(f"repos/{source_repo}", token)
    if err:
        # NARROW ON PURPOSE. Only the permissions/absence shape (404/403) is
        # treated as unreadable. A connection reset, a timeout or malformed
        # JSON is a DIFFERENT cannot-run, and this repo already fails those
        # closed -- see test_freshness_fail_when_source_repo_unreachable_is_
        # not_silent_pass. Widening this to "any error" would quietly move
        # transient failures into the not-checked bucket, which is the same
        # warn-bucket-is-not-a-safe-bucket move this fix exists to avoid.
        # Two cannot-run causes, deliberately not merged.
        if "HTTP 404" in err or "HTTP 403" in err:
            return False, err
        return True, ""   # a different failure; let the caller fail closed
    if not isinstance(data, dict):
        return True, ""   # shape problem, not a permissions problem
    return True, ""


def _resolve_pin_commit(source_repo: str, tag: str, token: str | None) -> tuple[str | None, str]:
    """Resolve a tag to a commit SHA in `source_repo`.

    Handles both annotated tags (object.type == "tag" -> one hop through
    git/tags/{sha} to reach the commit) and lightweight tags
    (object.type == "commit" -> already there).
    """
    ref, err = _gh_api_json(f"repos/{source_repo}/git/refs/tags/{tag}", token)
    if err:
        return None, err
    if not isinstance(ref, dict):
        return None, f"unexpected ref response shape: {type(ref).__name__}"
    obj = ref.get("object") or {}
    obj_sha = obj.get("sha")
    obj_type = obj.get("type")
    if not obj_sha:
        return None, f"ref response missing object.sha: {ref}"
    if obj_type == "commit":
        return obj_sha, ""
    if obj_type == "tag":
        tag_obj, err = _gh_api_json(f"repos/{source_repo}/git/tags/{obj_sha}", token)
        if err:
            return None, err
        if not isinstance(tag_obj, dict):
            return None, f"unexpected tag-object response shape: {type(tag_obj).__name__}"
        target = (tag_obj.get("object") or {}).get("sha")
        if not target:
            return None, f"tag object missing target sha: {tag_obj}"
        return target, ""
    return None, f"unexpected tag object type: {obj_type!r}"


# ---------------------------------------------------------------------------
# Build-info sidecar plumbing (v1.0.14, pairs with oa #259 Stream 1)
#
# Per BUILD_INFO_SIDECAR_SPEC_v1.0.14.md, every daemon release from hub-v0.4.44
# forward ships a `.build-info.json` sidecar sibling to the .tar.gz. The sidecar
# carries a schema-versioned record of the build: commit_sha + commit_date +
# tag_name + dirty_worktree + signed_by.tarball_sha256 (see spec §2).
#
# Two consumers here (see spec §5):
#   A. `verify_build_info_sidecar_present`  — defensive backstop primitive
#      that FAILs closed if a pinned artefact has no sidecar at all.
#   B. `pinned_artefact_freshness`          — the freshness gate can opt in
#      via `consume_build_info_sidecar: true` to cross-check the sidecar's
#      commit_sha / dirty_worktree / signed_by.tarball_sha256 against the pin.
#
# Both consumers fetch the sidecar through a common helper `_fetch_build_info_
# sidecar` which tries local disk first (for the four hub-v0.4.40-43 backfill
# sidecars authored by hand, per Stream 3), then falls back to the GitHub
# release asset. Reconstructed sidecars (`reconstructed: true` in the JSON) are
# accepted only when the entry opts in via `allow_reconstructed: true`, and
# they pass as "verified-with-caveat" rather than "verified".
# ---------------------------------------------------------------------------

# Downloading a full tarball for SHA verification can take longer than a plain
# JSON API call; keep the API timeout for the sidecar itself, use a wider one
# for the tarball.
GH_ASSET_DOWNLOAD_TIMEOUT_SECONDS = 300
UNKNOWN_MARKER_PREFIX = "<UNKNOWN"


def _fetch_asset_content(source_repo: str, asset_id: int, token: str | None,
                         timeout: int = GH_API_TIMEOUT_SECONDS) -> tuple[bytes, str]:
    """Fetch a release asset's raw bytes via `gh api` with the octet-stream Accept
    header. Returns (bytes, error_string). On any failure returns (b"", "why")."""
    env = dict(os.environ)
    if token:
        env["GH_TOKEN"] = token
    try:
        r = subprocess.run(
            ["gh", "api",
             f"repos/{source_repo}/releases/assets/{asset_id}",
             "-H", "Accept: application/octet-stream"],
            capture_output=True, check=False, timeout=timeout, env=env,
        )
    except FileNotFoundError:
        return b"", "gh CLI not installed"
    except subprocess.TimeoutExpired:
        return b"", f"asset {asset_id} download timed out after {timeout}s"
    if r.returncode != 0:
        stderr = r.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
        return b"", f"gh api asset {asset_id} exit={r.returncode}: {stderr[0][:200]}"
    return r.stdout, ""


def _resolve_local_sidecar_dir(cm051_dir: Path, raw: str) -> Path:
    """Expand env vars then resolve a raw path spec to an absolute Path.

    Accepts absolute paths, CM051-relative paths, and paths with `${VAR}` env
    substitution. The env-substitution form lets a cut manifest name an
    out-of-tree sidecar directory (e.g. `${HR015_DIR}/launch/backfill-sidecars`)
    without hardcoding a per-operator absolute path.
    """
    expanded = os.path.expandvars(raw)
    p = Path(expanded).expanduser()
    if p.is_absolute():
        return p
    return cm051_dir / expanded


def _fetch_build_info_sidecar(source_repo: str, tag: str, ctx: dict,
                              local_sidecar_dir: str | None,
                              token: str | None,
                              ) -> tuple[dict | None, str, str]:
    """Locate + parse a build-info sidecar for `tag`.

    Search order:
      1. Local disk under `local_sidecar_dir/<tag>.build-info.json` (when
         `local_sidecar_dir` is configured; for the four hub-v0.4.40-43
         backfill sidecars in HR015 launch/backfill-sidecars/).
      2. GitHub release asset ending in `.build-info.json` on the tag's
         release.

    Returns (parsed_json | None, source_description, error_string). Fail-closed:
    a missing sidecar returns an error, never a silent pass.
    """
    # 1. Local fallback (backfill sidecars).
    if local_sidecar_dir:
        try:
            local_dir = _resolve_local_sidecar_dir(ctx["cm051_dir"], local_sidecar_dir)
        except Exception as e:
            return None, "", f"resolving local_sidecar_dir {local_sidecar_dir!r}: {e}"
        local_file = local_dir / f"{tag}.build-info.json"
        if local_file.is_file():
            try:
                data = json.loads(local_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as e:
                return None, "", f"local sidecar {local_file} malformed: {e}"
            if not isinstance(data, dict):
                return None, "", f"local sidecar {local_file} is not a JSON object"
            return data, f"local:{local_file}", ""

    # 2. GitHub release asset.
    release, err = _gh_api_json(f"repos/{source_repo}/releases/tags/{tag}", token)
    if err:
        return None, "", f"fetching release {tag}: {err}"
    if not isinstance(release, dict):
        return None, "", f"unexpected release response shape: {type(release).__name__}"
    assets = release.get("assets") or []
    sidecar_asset = None
    for a in assets:
        name = a.get("name", "") if isinstance(a, dict) else ""
        if name.endswith(".build-info.json"):
            sidecar_asset = a
            break
    if not sidecar_asset:
        available = [a.get("name", "?") for a in assets if isinstance(a, dict)]
        return None, "", (f"no .build-info.json asset in release {tag}; "
                          f"assets present: {available}")
    asset_id = sidecar_asset.get("id")
    if asset_id is None:
        return None, "", f"sidecar asset in release {tag} has no id: {sidecar_asset}"
    content, err = _fetch_asset_content(source_repo, asset_id, token)
    if err:
        return None, "", f"downloading sidecar asset {asset_id}: {err}"
    try:
        data = json.loads(content.decode("utf-8", "replace"))
    except json.JSONDecodeError as e:
        return None, "", f"sidecar asset {asset_id} malformed JSON: {e}"
    if not isinstance(data, dict):
        return None, "", f"sidecar asset {asset_id} is not a JSON object"
    return data, f"release:{sidecar_asset.get('name')}", ""


def _find_tarball_asset(source_repo: str, tag: str, token: str | None,
                        ) -> tuple[dict | None, str]:
    """Locate the `.tar.gz` release asset for `tag` (excluding sidecars)."""
    release, err = _gh_api_json(f"repos/{source_repo}/releases/tags/{tag}", token)
    if err:
        return None, err
    if not isinstance(release, dict):
        return None, f"unexpected release response shape: {type(release).__name__}"
    for a in (release.get("assets") or []):
        if not isinstance(a, dict):
            continue
        name = a.get("name", "")
        if name.endswith(".tar.gz") and not name.endswith(".build-info.json"):
            return a, ""
    return None, f"no .tar.gz asset in release {tag}"


def _compute_release_tarball_sha256(source_repo: str, tag: str,
                                    token: str | None) -> tuple[str | None, str]:
    """Download the tarball asset for `tag` and return its SHA-256 hex digest."""
    tarball, err = _find_tarball_asset(source_repo, tag, token)
    if err:
        return None, err
    asset_id = tarball.get("id")
    if asset_id is None:
        return None, f"tarball asset in release {tag} has no id"
    content, err = _fetch_asset_content(source_repo, asset_id, token,
                                        timeout=GH_ASSET_DOWNLOAD_TIMEOUT_SECONDS)
    if err:
        return None, err
    return hashlib.sha256(content).hexdigest(), ""


@dataclass
class _SidecarCheck:
    """Outcome of a sidecar cross-check applied inside pinned_artefact_freshness."""
    ok: bool
    note: str          # human-readable note appended to freshness result on PASS
    err: str = ""      # populated on FAIL; caller returns FAIL with this


def _verify_sidecar_matches_pin(source_repo: str, tag: str, pin_sha: str,
                                proof: dict, ctx: dict, token: str | None,
                                ) -> _SidecarCheck:
    """Perform the sidecar cross-check inside a `pinned_artefact_freshness` entry.

    Runs when the entry sets `consume_build_info_sidecar: true`. Cross-checks:
      - sidecar.commit_sha == pin_sha (tag resolution + sidecar independently agree)
      - sidecar.dirty_worktree is not True (backfills may have "<UNKNOWN...>" which
        is tolerated when reconstructed:true)
      - sidecar.signed_by.tarball_sha256 == actual tarball SHA-256 (only when
        `verify_tarball_sha: true` is set on the entry; downloads the tarball asset)

    `reconstructed: true` sidecars are tolerated only if `allow_reconstructed: true`;
    the note reads "verified-with-caveat" in that case, "verified" otherwise.
    """
    allow_reconstructed = bool(proof.get("allow_reconstructed", False))
    local_sidecar_dir = proof.get("local_sidecar_dir")
    verify_tarball_sha = bool(proof.get("verify_tarball_sha", False))

    sidecar, src, err = _fetch_build_info_sidecar(
        source_repo, tag, ctx, local_sidecar_dir, token,
    )
    if err:
        return _SidecarCheck(ok=False, note="",
                             err=f"sidecar cross-check for {tag}: {err}")

    reconstructed = bool(sidecar.get("reconstructed", False))
    if reconstructed and not allow_reconstructed:
        return _SidecarCheck(ok=False, note="", err=(
            f"sidecar for {tag} is reconstructed:true but "
            f"allow_reconstructed:true is not set on this entry "
            f"(source={src})"))

    # commit_sha cross-check: cheap, catches wrong-tag-pointing-at-wrong-commit.
    sidecar_sha = str(sidecar.get("commit_sha") or "")
    if sidecar_sha != pin_sha:
        return _SidecarCheck(ok=False, note="", err=(
            f"sidecar.commit_sha {sidecar_sha[:12] or '<empty>'} != tag {tag} "
            f"commit {pin_sha[:12]} (source={src})"))

    # dirty_worktree cross-check. Real emits: false; reconstructed backfills may
    # carry a literal "<UNKNOWN - ...>" string when the fact was not captured at
    # build time. Only a hard True fails; anything else (False or unknown-marker)
    # is tolerated. This is deliberately conservative: a released binary is never
    # dirty, so a strict-False rule catches a tampered sidecar without penalising
    # honest reconstructions.
    dirty = sidecar.get("dirty_worktree")
    if dirty is True:
        return _SidecarCheck(ok=False, note="", err=(
            f"sidecar for {tag} declares dirty_worktree:true; released binaries "
            f"must be built from a clean tree (source={src})"))

    # Optional tarball SHA-256 cross-check (tamper detection). Skipped when the
    # sidecar's expected value is a backfill unknown-marker string.
    if verify_tarball_sha:
        signed_by = sidecar.get("signed_by") or {}
        expected = str(signed_by.get("tarball_sha256") or "")
        if not expected:
            return _SidecarCheck(ok=False, note="", err=(
                f"sidecar for {tag} has no signed_by.tarball_sha256 "
                f"(source={src})"))
        if expected.startswith(UNKNOWN_MARKER_PREFIX):
            if not reconstructed:
                return _SidecarCheck(ok=False, note="", err=(
                    f"sidecar for {tag} has unknown-marker tarball_sha256 "
                    f"but is not marked reconstructed:true (source={src})"))
            # Reconstructed backfill with no known tarball SHA -- skip verify.
        else:
            actual, terr = _compute_release_tarball_sha256(source_repo, tag, token)
            if terr:
                return _SidecarCheck(ok=False, note="", err=(
                    f"downloading tarball for SHA verify of {tag}: {terr}"))
            if actual != expected:
                return _SidecarCheck(ok=False, note="", err=(
                    f"TAMPER DETECTED: tarball SHA-256 for {tag} is {actual[:12]} "
                    f"but sidecar declares {expected[:12]} (source={src})"))

    caveat = "verified-with-caveat: reconstructed backfill" if reconstructed else "verified"
    return _SidecarCheck(ok=True,
                         note=f"sidecar {caveat} (source={src})")


def check_verify_build_info_sidecar_present(entry: dict, ctx: dict) -> Result:
    """Defensive backstop primitive: FAIL if a pinned binary artefact has no
    matching `.build-info.json` sidecar. Catches the case where a pre-v1.0.14
    binary (no sidecar) is pinned by mistake, or where a rogue release was
    published without the sidecar being emitted.

    Sidecar is located via `_fetch_build_info_sidecar` (local fallback then
    GitHub release asset). Sidecars marked `reconstructed: true` (the four
    hub-v0.4.40-43 backfills) pass only when the entry sets
    `allow_reconstructed: true`; those hits report "verified-with-caveat"
    while still returning a PASS.

    Contract mirrors `pinned_artefact_freshness`: same `pinned_version_source` +
    `tag_format` + `source_repo` shape, plus:
      - `allow_reconstructed: bool` (default false)
      - `local_sidecar_dir: str` (optional; env-var expansion supported)
    """
    proof = entry["proof"]
    pin_source = proof.get("pinned_version_source") or {}
    tag_format = proof.get("tag_format")
    source_repo = proof.get("source_repo")
    allow_reconstructed = bool(proof.get("allow_reconstructed", False))
    local_sidecar_dir = proof.get("local_sidecar_dir")

    if not source_repo or "/" not in source_repo:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "FAIL", f"source_repo missing or malformed: {source_repo!r}",
                      entry.get("source_pr", ""))
    if not tag_format or "{version}" not in tag_format:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "FAIL", f"tag_format must contain '{{version}}': {tag_format!r}",
                      entry.get("source_pr", ""))

    version, verr = _extract_pinned_version(ctx["cm051_dir"], pin_source)
    if verr:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "FAIL", f"resolving pinned version: {verr}",
                      entry.get("source_pr", ""))
    tag = tag_format.replace("{version}", version)
    owner = _repo_owner(source_repo)
    token = _gh_token_for(owner)
    if token is None:
        # CANNOT-RUN, NOT A DEFECT. Saying FAIL here claims the artefact is
        # stale when all that happened is that no credential resolved.
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present", "SKIP",
                      f"NOT CHECKED: no gh token for owner {owner!r}. "
                      f"Set OSTLER_RELEASES_TOKEN (CI) or "
                      f"`gh auth login --user {owner}` (operator). "
                      f"This row was not evaluated either way.",
                      entry.get("source_pr", ""))

    sidecar, src, err = _fetch_build_info_sidecar(
        source_repo, tag, ctx, local_sidecar_dir, token,
    )
    if err:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "FAIL", f"sidecar absent for {tag}: {err}",
                      entry.get("source_pr", ""))

    reconstructed = bool(sidecar.get("reconstructed", False))
    if reconstructed and not allow_reconstructed:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "FAIL",
                      f"sidecar for {tag} is reconstructed:true; set "
                      f"allow_reconstructed:true on this entry if the backfill "
                      f"is intentional (source={src})",
                      entry.get("source_pr", ""))

    # Belt-and-braces: sidecar's own tag_name (when populated + not marker) must
    # match the tag we resolved to. Missing tag_name is tolerated (older
    # backfills may set it, real emits do).
    sidecar_tag = sidecar.get("tag_name")
    if isinstance(sidecar_tag, str) and sidecar_tag and not sidecar_tag.startswith(UNKNOWN_MARKER_PREFIX):
        if sidecar_tag != tag:
            return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                          "FAIL",
                          f"sidecar declares tag_name {sidecar_tag!r} but pin resolves "
                          f"to {tag!r} (source={src})",
                          entry.get("source_pr", ""))

    if reconstructed:
        return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                      "PASS",
                      f"sidecar present for {tag} (verified-with-caveat: "
                      f"reconstructed backfill; source={src})",
                      entry.get("source_pr", ""))
    return Result(entry["id"], entry["title"], "verify_build_info_sidecar_present",
                  "PASS",
                  f"sidecar present + fully-verified for {tag} (source={src})",
                  entry.get("source_pr", ""))


def check_pinned_artefact_freshness(entry: dict, ctx: dict) -> Result:
    """Prove that the pinned pre-built artefact (daemon tarball, RemoteCapture,
    ...) contains every merged-to-source change in the artefact's compilation
    sub-tree. Fails closed when the source repo has moved past the pin on any
    non-ignored commit that touches `source_paths`.

    Optional v1.0.14 extension (`consume_build_info_sidecar: true`): after
    resolving the pin commit, cross-check the release's `.build-info.json`
    sidecar (see BUILD_INFO_SIDECAR_SPEC_v1.0.14.md + oa #259 Stream 1). Adds
    `sidecar.commit_sha == pin_sha`, `dirty_worktree != true`, and optional
    tarball SHA-256 tamper detection. Backward-compat preserved when omitted.

    Optional hotfix exemption (`hold_ack`, #238): a cut may intentionally pin an
    artefact behind source HEAD (a hotfix graft-forward, or a deliberate hold).
    `hold_ack: {shas: [...], reason: "..."}` lets the pin sit behind HEAD ONLY
    when every diverging commit's SHA is listed AND a written reason is given;
    any un-acknowledged diverging commit is still fail-closed. Mirrors
    verify_cut_freshness.sh's hold_ack so the manifest gate and the freshness
    shell gate speak the same exemption dialect. Omit for the default
    fail-on-any-drift behaviour.
    """
    proof = entry["proof"]
    artefact = proof.get("artefact", "?")
    pin_source = proof.get("pinned_version_source") or {}
    tag_format = proof.get("tag_format")
    source_repo = proof.get("source_repo")
    source_paths = proof.get("source_paths") or []
    ignore_patterns = proof.get("ignore_commits_matching") or []

    if not source_repo or "/" not in source_repo:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"source_repo missing or malformed: {source_repo!r}",
                      entry.get("source_pr", ""))
    if not tag_format or "{version}" not in tag_format:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"tag_format must contain '{{version}}': {tag_format!r}",
                      entry.get("source_pr", ""))
    if not source_paths:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      "source_paths must not be empty (which files compile into this artefact?)",
                      entry.get("source_pr", ""))

    version, verr = _extract_pinned_version(ctx["cm051_dir"], pin_source)
    if verr:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"resolving pinned version: {verr}", entry.get("source_pr", ""))
    tag = tag_format.replace("{version}", version)
    owner = _repo_owner(source_repo)
    token = _gh_token_for(owner)
    if token is None:
        # CANNOT-RUN, NOT A DEFECT. Saying FAIL here claims the artefact is
        # stale when all that happened is that no credential resolved.
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "SKIP",
                      f"NOT CHECKED: no gh token for owner {owner!r}. "
                      f"Set OSTLER_RELEASES_TOKEN (CI) or "
                      f"`gh auth login --user {owner}` (operator). "
                      f"This row was not evaluated either way.",
                      entry.get("source_pr", ""))

    # Probe the REPO before the TAG. A 404 on a private repo is
    # indistinguishable from a 404 on a missing tag, so establishing
    # readability first is what gives the NEXT 404 its meaning.
    readable, why = _repo_is_readable(source_repo, token)
    if not readable:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "SKIP",
                      f"NOT CHECKED: cannot read {source_repo} with the {owner!r} "
                      f"token ({why}). The repo is private or the token lacks "
                      f"scope for it. This row was not evaluated either way -- it "
                      f"says nothing about whether the pin is fresh.",
                      entry.get("source_pr", ""))

    pin_sha, err = _resolve_pin_commit(source_repo, tag, token)
    if err:
        # Reachable only once the repo above READ successfully, so a 404 here
        # is a genuinely absent tag rather than a permissions artefact.
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"resolving tag {tag!r} in {source_repo}: {err} "
                      f"(repo IS readable, so the tag is genuinely absent)",
                      entry.get("source_pr", ""))

    # v1.0.14 opt-in: sidecar cross-check runs immediately after pin_sha is
    # resolved so a mismatch is reported before the (potentially heavy)
    # compare-commit walk. When omitted, freshness behaves exactly as before.
    sidecar_note = ""
    if proof.get("consume_build_info_sidecar"):
        check = _verify_sidecar_matches_pin(source_repo, tag, pin_sha, proof, ctx, token)
        if not check.ok:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness",
                          "FAIL", check.err, entry.get("source_pr", ""))
        sidecar_note = check.note

    repo, err = _gh_api_json(f"repos/{source_repo}", token)
    if err or not isinstance(repo, dict):
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"fetching repo metadata for {source_repo}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))
    default_branch = repo.get("default_branch") or "main"
    branch, err = _gh_api_json(f"repos/{source_repo}/branches/{default_branch}", token)
    if err or not isinstance(branch, dict):
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"fetching {default_branch} HEAD for {source_repo}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))
    head_sha = (branch.get("commit") or {}).get("sha")
    if not head_sha:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"branch response missing commit.sha: {branch}",
                      entry.get("source_pr", ""))

    if pin_sha == head_sha:
        detail = (f"pinned {artefact} v{version} (@{pin_sha[:8]}) == {default_branch} HEAD "
                  f"({head_sha[:8]})")
        if sidecar_note:
            detail += f"; {sidecar_note}"
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      detail, entry.get("source_pr", ""))

    compare, err = _gh_api_json(f"repos/{source_repo}/compare/{pin_sha}...{head_sha}", token)
    if err or not isinstance(compare, dict):
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"comparing {pin_sha[:8]}...{head_sha[:8]}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))
    status = compare.get("status")
    # `behind` means the pin is AHEAD of default (a customer-hosted branch cut)
    # -- treat as pass, defer to the maintainer.
    if status == "behind" or status == "identical":
        detail = (f"pinned {artefact} v{version} (@{pin_sha[:8]}) is at or ahead of "
                  f"{default_branch} HEAD ({head_sha[:8]}) on {source_paths}")
        if sidecar_note:
            detail += f"; {sidecar_note}"
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      detail, entry.get("source_pr", ""))

    commits = compare.get("commits") or []
    # Per-commit divergence check: files come out of the compare response's
    # top-level `files` list (aggregated across the whole range), but to
    # attribute a hit to a specific commit + apply ignore_commits_matching, we
    # need per-commit file lists. Fetch per-commit files for any commit not
    # explicitly ignored.
    diverging: list[tuple[str, str, str]] = []  # (short_sha, first_line, matched_pattern)
    for c in commits:
        sha = c.get("sha", "")
        msg = ((c.get("commit") or {}).get("message") or "").strip()
        first_line = msg.splitlines()[0] if msg else ""
        if any(re.search(pat, first_line) for pat in ignore_patterns):
            continue
        commit_detail, cerr = _gh_api_json(f"repos/{source_repo}/commits/{sha}", token)
        if cerr or not isinstance(commit_detail, dict):
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"fetching per-commit files for {sha[:8]}: {cerr or 'unexpected shape'}",
                          entry.get("source_pr", ""))
        for f in (commit_detail.get("files") or []):
            fname = f.get("filename") or ""
            matched = _matches_source_path(fname, source_paths)
            if matched:
                diverging.append((sha[:8], first_line[:120], matched))
                break

    if not diverging:
        detail = (f"pinned {artefact} v{version} (@{pin_sha[:8]}) is at or ahead of "
                  f"{default_branch} HEAD ({head_sha[:8]}) on {source_paths} "
                  f"(all {len(commits)} intervening commits are ignored or off-tree)")
        if sidecar_note:
            detail += f"; {sidecar_note}"
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      detail, entry.get("source_pr", ""))

    # Hotfix / intentional-hold exemption (#238). A cut may DELIBERATELY pin an
    # artefact behind source HEAD -- e.g. a hotfix whose daemon is a graft-forward
    # that does not track main, or a hold while a risky main commit is triaged.
    # Without an escape hatch the manifest gate would block a legitimate hotfix
    # (exactly what forced ORM to bypass the gate on the v1.0.13.1 cut). Mirrors
    # verify_cut_freshness.sh's hold_ack contract: the pin may sit behind HEAD
    # ONLY if EVERY diverging commit is explicitly acknowledged by SHA and a
    # written reason is given. Any un-acknowledged diverging commit stays
    # fail-closed -- a hold_ack that does not cover the full delta does NOT pass,
    # it just narrows the failure to the commits nobody vouched for.
    hold = proof.get("hold_ack") or {}
    ack_shas_raw = hold.get("shas") or []
    ack_reason = (hold.get("reason") or "").strip()
    if ack_shas_raw:
        if not ack_reason:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          "hold_ack.shas present but hold_ack.reason is empty -- an intentional "
                          "hold MUST carry a written reason (why is the pin allowed behind HEAD?)",
                          entry.get("source_pr", ""))
        # Accept full or abbreviated SHAs on either side: a diverging short sha
        # matches an ack entry when one is a prefix of the other (case-folded).
        ack_norm = [s.strip().lower() for s in ack_shas_raw if s and s.strip()]
        def _is_acked(short_sha: str) -> bool:
            s = short_sha.lower()
            return any(a.startswith(s) or s.startswith(a) for a in ack_norm)
        unacked = [(short, subj, pat) for (short, subj, pat) in diverging if not _is_acked(short)]
        if not unacked:
            held = ", ".join(short for short, _, _ in diverging)
            detail = (f"pinned {artefact} v{version} (@{pin_sha[:8]}) is behind {default_branch} "
                      f"HEAD ({head_sha[:8]}) but all {len(diverging)} diverging commit(s) "
                      f"[{held}] are hold_ack'd -- reason: {ack_reason}")
            if sidecar_note:
                detail += f"; {sidecar_note}"
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                          detail, entry.get("source_pr", ""))
        # Partial ack: report only the commits nobody acknowledged.
        diverging = unacked

    lines = [f"pinned {artefact} v{version} (@{pin_sha[:8]}) is stale vs {default_branch} HEAD "
             f"({head_sha[:8]}); {len(diverging)} diverging commit(s) touch {source_paths}:"]
    for short, subj, pat in diverging[:10]:
        lines.append(f"    {short} {subj}  [{pat}]")
    if len(diverging) > 10:
        lines.append(f"    ... (+{len(diverging) - 10} more)")
    lines.append("Recovery: cut a new release from source HEAD; bump the pin in "
                 f"{pin_source.get('file')}; rebuild. OR, for an intentional hold "
                 "(hotfix graft-forward), add a hold_ack {shas:[...], reason:'...'} "
                 "block to this entry covering exactly the commit(s) above.")
    return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                  " ".join(lines) if len(lines) == 1 else "\n        ".join(lines),
                  entry.get("source_pr", ""))


DISPATCH: dict[str, Callable[[dict, dict], Result]] = {
    "grep_in_installer": check_grep_in_installer,
    "grep_in_artefact": check_grep_in_artefact,
    "grep_in_dmg_tree": check_grep_in_dmg_tree,
    "grep_in_source_at_sha": check_grep_in_source_at_sha,
    "file_exists_in_artefact": check_file_exists_in_artefact,
    "plist_key_equals": check_plist_key_equals,
    "plist_env_key_present": check_plist_env_key_present,
    "box_walk_probe": check_box_walk_probe,
    "payload_version_matches_daemon_version": check_payload_version_matches_daemon_version,
    "pinned_artefact_freshness": check_pinned_artefact_freshness,
    "verify_build_info_sidecar_present": check_verify_build_info_sidecar_present,
}


# ---------------------------------------------------------------------------
# Manifest loading + orchestration
# ---------------------------------------------------------------------------

def load_manifest(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"manifest not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    if not isinstance(doc, dict) or "entries" not in doc:
        raise ValueError(f"manifest {path} missing 'entries' key")
    return doc


def check_entry(entry: dict, ctx: dict) -> Result:
    proof = entry.get("proof", {})
    kind = proof.get("kind")
    if kind not in DISPATCH:
        return Result(entry.get("id", "?"), entry.get("title", "?"), str(kind), "FAIL",
                      f"unknown proof.kind: {kind!r}. Known: {sorted(DISPATCH.keys())}",
                      entry.get("source_pr", ""))
    try:
        return DISPATCH[kind](entry, ctx)
    except KeyError as e:
        return Result(entry.get("id", "?"), entry.get("title", "?"), kind, "FAIL",
                      f"malformed entry, missing field: {e}", entry.get("source_pr", ""))
    except Exception as e:
        return Result(entry.get("id", "?"), entry.get("title", "?"), kind, "FAIL",
                      f"internal error: {e}", entry.get("source_pr", ""))


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Verify a cut manifest against the built artefact.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--version", default=None,
                    help="Cut version to verify (e.g. v1.0.11). Auto-discovered if omitted.")
    ap.add_argument("--app-path", default=str(DEFAULT_APP_PATH),
                    help=f"Path to built OstlerInstaller.app (default: {DEFAULT_APP_PATH})")
    ap.add_argument("--cm051-dir", default=str(CM051_DIR),
                    help="Path to CM051 repo root (default: parent of scripts/)")
    ap.add_argument("--manifest-dir", default=None,
                    help="Path to cut-manifests/ dir (default: <cm051-dir>/cut-manifests)")
    ap.add_argument("--skip-source-at-sha", action="store_true",
                    help="Skip grep_in_source_at_sha checks (useful when sibling repos aren't checked out)")
    ap.add_argument("--json", action="store_true", help="Emit machine-readable JSON on stdout")
    ap.add_argument("--verbose", action="store_true", help="Print every check's detail line")
    ap.add_argument("--require-runtime-proofs", action="store_true",
                    help="A declared RUNTIME proof that could not run is a FAILURE, not a skip. "
                         "Use for a real cut: a box_walk_probe with no OSTLER_BOX_HOST proves "
                         "nothing, and without this flag it exits 0.")
    args = ap.parse_args()

    app_path = Path(args.app_path).expanduser().resolve()
    cm051_dir = Path(args.cm051_dir).expanduser().resolve()
    manifest_dir = Path(args.manifest_dir).expanduser().resolve() if args.manifest_dir else (cm051_dir / "cut-manifests")

    if not manifest_dir.is_dir():
        print(f"ERROR: manifest dir not found: {manifest_dir}", file=sys.stderr)
        return 2

    permanent = manifest_dir / "permanent.yaml"
    if args.version:
        per_cut = manifest_dir / f"{args.version}.yaml"
    else:
        candidates = sorted(manifest_dir.glob("v*.yaml"))
        if not candidates:
            print(f"ERROR: no v*.yaml in {manifest_dir}. Pass --version or add a file.", file=sys.stderr)
            return 2
        per_cut = candidates[-1]  # newest lexicographically (v1.0.11 > v1.0.10)

    colour = sys.stdout.isatty() and not args.json

    manifests = []
    if permanent.is_file():
        manifests.append(("permanent", load_manifest(permanent)))
    else:
        print(f"WARN: {permanent} not present — skipping never-regress backstop", file=sys.stderr)
    manifests.append((per_cut.stem, load_manifest(per_cut)))

    ctx = {
        "app_path": app_path,
        "cm051_dir": cm051_dir,
        "extra_paths": {},
        "require_runtime_proofs": bool(args.require_runtime_proofs),
    }

    results: list[Result] = []
    if not args.json:
        print("=== Cut manifest gate ===")
        print(f"  app_path       = {app_path}")
        print(f"  cm051_dir      = {cm051_dir}")
        print(f"  manifests      = {[p.name for _, m in manifests for p in [Path(str(m.get('version','?'))+'.yaml')]]}")
        print()

    for label, doc in manifests:
        if not args.json:
            print(f"--- {label} ({len(doc.get('entries', []))} entries) ---")
        for entry in doc.get("entries", []):
            if args.skip_source_at_sha and entry.get("proof", {}).get("kind") == "grep_in_source_at_sha":
                results.append(Result(entry["id"], entry["title"], "grep_in_source_at_sha", "SKIP",
                                      "skipped by --skip-source-at-sha", entry.get("source_pr", "")))
                emit(results[-1], colour) if not args.json else None
                continue
            r = check_entry(entry, ctx)
            results.append(r)
            if not args.json:
                emit(r, colour)
                if args.verbose and r.status == "PASS" and r.detail:
                    print(f"        {DIM if colour else ''}{r.detail}{RESET if colour else ''}")

    passes = sum(1 for r in results if r.status == "PASS")
    fails = sum(1 for r in results if r.status == "FAIL")
    skips = sum(1 for r in results if r.status == "SKIP")

    if args.json:
        print(json.dumps({
            "app_path": str(app_path),
            "results": [asdict(r) for r in results],
            "summary": {"pass": passes, "fail": fails, "skip": skips, "total": len(results)},
        }, indent=2))
    else:
        print()
        # 🔴 #713: NAME the skipped rows. A bare skip COUNT is a silent cap --
        # it reads as "nothing to report" when it means "these specific proofs
        # did not happen". The box_walk_probe rows skipped on every cut for
        # months behind a number in this line.
        if skips:
            print("  Rows that did NOT prove anything (SKIP):")
            for r in results:
                if r.status == "SKIP":
                    print(f"    - {r.id}  [{r.kind}]  {r.detail}")
            print()
        print(f"=== Summary: {passes} PASS  {fails} FAIL  {skips} SKIP  ({len(results)} total) ===")
        if skips and not args.require_runtime_proofs:
            print("  (re-run with --require-runtime-proofs to make a declared RUNTIME "
                  "proof that could not run a FAILURE rather than a skip)")

    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
