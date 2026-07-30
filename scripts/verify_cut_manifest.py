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
#   - verify_cut_manifest.py    — THIS SCRIPT (10-primitive YAML gate)
#
# See cut-manifests/README.md for schema.
# ============================================================================

import argparse
import datetime as dt
import fnmatch
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
        "daemon-binary": daemon_app / "Contents" / "MacOS" / "zeroclaw-desktop",
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
        # If running in a worktree, resolve to the primary checkout.
        try:
            result = subprocess.run(
                ["git", "-C", str(cm051_dir), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                capture_output=True, check=False, timeout=5,
            )
            if result.returncode == 0:
                common_dir = Path(result.stdout.decode().strip())
                if common_dir.name == ".git":
                    return common_dir.parent
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
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


def check_grep_in_source_at_sha(entry: dict, ctx: dict) -> Result:
    proof = entry["proof"]
    target_name = proof.get("target", "this-repo")
    pattern = proof["pattern"]
    must_match = proof.get("must_match", True)
    path_hint = proof.get("path")
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
                try:
                    hits += int(line.rsplit(":", 1)[-1])
                except ValueError:
                    pass
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return Result(entry["id"], entry["title"], "grep_in_source_at_sha", "FAIL",
                      f"git invocation failed: {e}", entry.get("source_pr", ""))
    ok = (hits > 0) if must_match else (hits == 0)
    status = "PASS" if ok else "FAIL"
    detail = f"target={target_name} sha={sha[:12]} pattern={pattern!r} must_match={must_match} hits={hits}"
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
# The registry maps `probe: <name>` to `scripts/box_walk_probes/<name>.sh`.
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


def _box_walk_probe_registry_dir(cm051_dir: Path) -> Path:
    """Location of the box-walk probe registry.

    All probe scripts live under `scripts/box_walk_probes/<probe_name>.sh`.
    Keeping them together (rather than scattering) makes the registry easy to
    audit and lets `chmod +x` propagate via a single directory.
    """
    return cm051_dir / "scripts" / "box_walk_probes"


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
        return Result(entry["id"], entry["title"], "box_walk_probe", "SKIP",
                      "OSTLER_BOX_HOST not set (runtime probe requires a reachable box)",
                      entry.get("source_pr", ""))

    registry_dir = _box_walk_probe_registry_dir(cm051_dir)
    script = registry_dir / f"{probe}.sh"
    if not script.is_file():
        return Result(entry["id"], entry["title"], "box_walk_probe", "FAIL",
                      f"probe {probe!r} not registered at {script}",
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
    daemon_bin = payload_root / "assistant-agent" / "bin" / "ostler-assistant"

    if not version_file.is_file():
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"payload VERSION file missing at {version_file}",
                      entry.get("source_pr", ""))
    if not daemon_bin.is_file():
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
# pinned_artefact_freshness — verifies a version-pinned downloadable artefact
# (daemon tarball, wiki container image, RemoteCapture binary, extension .app.zip)
# actually carries every PR the cut manifest claims it does.
#
# The class of bug this closes: a PR is merged to `main` in the source repo,
# the cut manifest is edited to claim "this cut ships #242", but the pinned
# artefact was tagged BEFORE that merge, so the DMG bundles the stale binary
# and the fix silently misses the cut. On 2026-07-30 the subscription
# grace-period hardening (oa #242) surfaced exactly this failure mode: merged
# to ostler-assistant/main hours before ORM cut v1.0.13, but the pinned
# daemon tarball predated the merge so the DMG shipped without it. See
# feedback_pinned_artefact_must_have_freshness_gate for the source directive
# and feedback_completed_means_code_on_branch_not_shipped_in_artifact for the
# sibling rule this enforces.
#
# The primitive is network-shaped: it talks to the GitHub API via `gh api`
# (inheriting whatever `gh auth` state exists). SKIPs cleanly when no auth is
# available so CI + local dev pass without touching the network; the real
# gate runs on the cut host where `gh auth` is set up. Tests use a fixture
# dispatch (PINNED_FRESHNESS_API_FIXTURE_DIR) so they never touch the wire.
# ---------------------------------------------------------------------------

# Env var: when set, the primitive reads canned JSON responses from this dir
# instead of shelling out to `gh api`. Filename convention: the endpoint path
# with `/` replaced by `_` plus `.json`. Test-only escape hatch; not documented
# in the manifest schema.
_API_FIXTURE_ENV = "PINNED_FRESHNESS_API_FIXTURE_DIR"

# How long we wait for a GitHub API round-trip before treating it as failed.
# The primitive fires per-PR + per-compare so a slow network can accumulate;
# 20s per call keeps the whole gate under a minute for a 4-PR must-contain.
_GH_API_TIMEOUT_SECONDS = 20


class _PinNotFound(Exception):
    """Raised when a pin (tag/branch/sha) cannot be resolved on the remote."""


def _gh_auth_available() -> bool:
    """True when we can call the GitHub API.

    Returns True in three cases:
      1. `PINNED_FRESHNESS_API_FIXTURE_DIR` is set (test path).
      2. `GH_TOKEN` or `GITHUB_TOKEN` env var is set (CI / scripted path).
      3. `gh auth status` reports at least one authenticated account.

    Returns False otherwise so the primitive can SKIP cleanly in local dev
    without a gh login and in CI without a token, mirroring the pattern used
    by `box_walk_probe` and `grep_in_source_at_sha`.
    """
    if os.environ.get(_API_FIXTURE_ENV):
        return True
    if os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"):
        return True
    try:
        result = subprocess.run(
            ["gh", "auth", "status"],
            capture_output=True, check=False, timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def _endpoint_to_fixture_name(endpoint: str) -> str:
    """Deterministic filename for a fixture response.

    `/` → `_`, `?` and `&` → `_`. Kept simple + human-readable so a test
    author writing fixture files can predict the name.
    """
    safe = endpoint.replace("/", "_").replace("?", "_").replace("&", "_").replace("=", "_")
    return f"{safe}.json"


def _gh_api_get(endpoint: str) -> Any:
    """Fetch a GitHub API endpoint. Tests may divert via fixture dir.

    Raises RuntimeError on any non-200 response so the caller can decide
    between "pin not found" (specific 404s on refs/tags/...) and "other
    failure" (network, auth, rate-limit). A 404 on a ref-lookup endpoint is
    the expected shape for a nonexistent tag / branch and is caught by
    `_resolve_pin`; anything else propagates.
    """
    fixture_dir = os.environ.get(_API_FIXTURE_ENV)
    if fixture_dir:
        path = Path(fixture_dir) / _endpoint_to_fixture_name(endpoint)
        if not path.is_file():
            raise RuntimeError(f"api fixture missing: {path} (endpoint={endpoint})")
        return json.loads(path.read_text(encoding="utf-8"))
    try:
        result = subprocess.run(
            ["gh", "api", endpoint],
            capture_output=True, check=False, timeout=_GH_API_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as e:
        raise RuntimeError(f"gh CLI not on PATH: {e}") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"gh api {endpoint} timed out after {_GH_API_TIMEOUT_SECONDS}s") from e
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace").strip()
        # Preserve the exit code + short stderr; the caller uses this to detect
        # 404 on ref-lookup endpoints.
        raise RuntimeError(f"gh api {endpoint} exit={result.returncode}: {stderr[:300]}")
    return json.loads(result.stdout)


def _looks_like_sha(s: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-f]{7,40}", s.lower()))


def _resolve_pin(repo: str, pin: str) -> tuple[str, str]:
    """Resolve a pin (tag / branch / SHA) to (commit_sha, committer_date_iso).

    Try order: tag → branch → SHA. A tag ref may point to either a lightweight
    tag (object.type = "commit") or an annotated tag (object.type = "tag"), so
    we dereference the annotated-tag case one hop further to reach the commit.

    Raises _PinNotFound if the pin resolves nowhere. Any other exception
    (network, auth) propagates so the caller can report the specific failure.
    """
    # Try as tag first. GitHub returns 404 for missing refs; distinguish that
    # from other failures by inspecting the RuntimeError message.
    sha: str | None = None
    tag_err: Exception | None = None
    try:
        ref = _gh_api_get(f"repos/{repo}/git/refs/tags/{pin}")
        obj = ref["object"]
        if obj["type"] == "tag":
            # Annotated tag — dereference to reach the commit sha.
            tag_obj = _gh_api_get(f"repos/{repo}/git/tags/{obj['sha']}")
            sha = tag_obj["object"]["sha"]
        else:
            sha = obj["sha"]
    except Exception as e:
        tag_err = e

    if sha is None:
        # Try as branch head.
        try:
            ref = _gh_api_get(f"repos/{repo}/git/refs/heads/{pin}")
            sha = ref["object"]["sha"]
        except Exception:
            # Try as raw SHA.
            if _looks_like_sha(pin):
                sha = pin
            else:
                # Neither tag, branch, nor sha shape resolved. Include the tag
                # error's summary in the diagnostic so a real network / auth
                # failure is still visible (not silently reported as "pin not
                # found").
                raise _PinNotFound(
                    f"{pin!r} is not a tag, branch, or SHA on {repo}. "
                    f"tag-lookup error: {tag_err}"
                )

    # Fetch commit-date. This also proves the SHA (whichever route we took) is
    # a real commit on the remote — a made-up SHA would 404 here.
    try:
        commit = _gh_api_get(f"repos/{repo}/commits/{sha}")
    except Exception as e:
        raise _PinNotFound(
            f"pin {pin!r} resolved to sha {sha[:12]} but commit lookup failed: {e}"
        )
    commit_date = commit["commit"]["committer"]["date"]
    return sha, commit_date


def _parse_iso8601(s: str) -> dt.datetime:
    """Parse a GitHub ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SSZ`) to a UTC datetime."""
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return dt.datetime.fromisoformat(s)


def _validate_pinned_freshness_spec(proof: dict) -> str | None:
    """Return an error string if the spec is malformed, or None if valid.

    Extracted so callers can fail fast on obviously-broken YAML rather than
    firing network calls first.
    """
    if not isinstance(proof.get("repo"), str) or "/" not in proof.get("repo", ""):
        return f"'repo' must be 'owner/name', got {proof.get('repo')!r}"
    if not isinstance(proof.get("pin"), str) or not proof.get("pin").strip():
        return f"'pin' must be a non-empty string, got {proof.get('pin')!r}"
    prs = proof.get("must_contain_prs", [])
    if not isinstance(prs, list) or not all(isinstance(n, int) for n in prs):
        return f"'must_contain_prs' must be a list of integers, got {prs!r}"
    if not prs:
        return "'must_contain_prs' must contain at least one PR number"
    mbt = proof.get("min_build_time_after_pr")
    if mbt is not None:
        if not isinstance(mbt, int):
            return f"'min_build_time_after_pr' must be an integer PR number, got {mbt!r}"
        if mbt not in prs:
            return f"'min_build_time_after_pr' ({mbt}) must appear in must_contain_prs"
    freshness = proof.get("freshness_max_hours")
    if freshness is not None and (not isinstance(freshness, (int, float)) or freshness <= 0):
        return f"'freshness_max_hours' must be a positive number, got {freshness!r}"
    return None


def check_pinned_artefact_freshness(entry: dict, ctx: dict) -> Result:
    """Prove a version-pinned artefact contains every claimed must-contain PR.

    Spec:
        proof:
          kind: pinned_artefact_freshness
          repo: ostler-ai/ostler-assistant       # required, owner/name
          pin: hub-v0.4.41                       # required, tag / branch / sha
          must_contain_prs: [242, 257]           # required, list[int]
          min_build_time_after_pr: 257           # optional, PR number in must_contain_prs
          freshness_max_hours: 168               # optional, positive number

    Fails on any of:
      * malformed spec (bad repo shape, empty PR list, unknown fields)
      * pin does not resolve on the remote (tag missing, orphan SHA)
      * any must_contain_pr is not merged (state=open, merged=false)
      * any must_contain_pr's merge commit is not in the pin's ancestry
      * min_build_time_after_pr set: pin committed BEFORE that PR merged
      * freshness_max_hours set: pin committed more than N hours ago

    SKIPs when no `gh` auth is available (CI without token, local dev without
    gh login). Test-only escape hatch: PINNED_FRESHNESS_API_FIXTURE_DIR.
    """
    proof = entry["proof"]
    spec_err = _validate_pinned_freshness_spec(proof)
    if spec_err:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"spec error: {spec_err}", entry.get("source_pr", ""))

    if not _gh_auth_available():
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "SKIP",
                      "no gh auth available (set GH_TOKEN, run `gh auth login`, "
                      "or set PINNED_FRESHNESS_API_FIXTURE_DIR for tests)",
                      entry.get("source_pr", ""))

    repo: str = proof["repo"]
    pin: str = proof["pin"]
    must_contain_prs: list[int] = list(proof["must_contain_prs"])
    min_build_time_after_pr: int | None = proof.get("min_build_time_after_pr")
    freshness_max_hours: float | None = proof.get("freshness_max_hours")

    # 1. Resolve pin.
    try:
        pin_sha, pin_commit_date = _resolve_pin(repo, pin)
    except _PinNotFound as e:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"pin resolution failed: {e}", entry.get("source_pr", ""))
    except Exception as e:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"pin lookup errored: {e}", entry.get("source_pr", ""))

    # 2. Per-PR: merged? in pin ancestry?
    unmerged: list[int] = []
    missing: list[tuple[int, str]] = []
    pr_data_cache: dict[int, dict] = {}
    for pr_n in must_contain_prs:
        try:
            pr_data = _gh_api_get(f"repos/{repo}/pulls/{pr_n}")
        except Exception as e:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"could not fetch PR #{pr_n} from {repo}: {e}",
                          entry.get("source_pr", ""))
        pr_data_cache[pr_n] = pr_data
        if not pr_data.get("merged"):
            unmerged.append(pr_n)
            continue
        merge_sha = pr_data.get("merge_commit_sha")
        if not merge_sha:
            # Merged but no merge-commit sha reported — treat as unmerged for
            # cut-safety: we cannot prove ancestry without a sha to compare
            # against.
            unmerged.append(pr_n)
            continue
        try:
            compare = _gh_api_get(f"repos/{repo}/compare/{merge_sha}...{pin_sha}")
        except Exception as e:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"compare {merge_sha[:12]}...{pin_sha[:12]} failed: {e}",
                          entry.get("source_pr", ""))
        status = compare.get("status")
        # GitHub `compare` semantics for base...head:
        #   identical → same commit
        #   ahead     → head is a descendant of base (pin includes merge sha)
        #   behind    → head is an ancestor of base (pin PREDATES merge sha)
        #   diverged  → different branches share ancestor but neither contains
        #               the other (pin was cut off a fork or force-push happened)
        if status not in ("identical", "ahead"):
            missing.append((pr_n, str(status)))

    if unmerged:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"PR(s) claimed as must_contain_prs are NOT merged in {repo}: "
                      f"{unmerged}. Merge (or drop from manifest) before cutting.",
                      entry.get("source_pr", ""))

    if missing:
        detail_bits = [f"#{n}({status})" for n, status in missing]
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"pin {pin} ({pin_sha[:12]}) is missing merged PR(s): "
                      f"{', '.join(detail_bits)}. Re-cut / re-tag the artefact from "
                      f"a commit that includes these merges before shipping.",
                      entry.get("source_pr", ""))

    # 3. min_build_time_after_pr — defensive check: catch a pin that satisfies
    # ancestry via a merge-commit-in-history but was BUILT before the newest
    # must-contain merge, indicating the binary was tagged from a stale
    # checkout that happens to include an ancestor of the merge sha.
    if min_build_time_after_pr is not None:
        pr_data = pr_data_cache.get(min_build_time_after_pr)
        if pr_data is None:
            try:
                pr_data = _gh_api_get(f"repos/{repo}/pulls/{min_build_time_after_pr}")
            except Exception as e:
                return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                              f"could not fetch min_build_time_after_pr #{min_build_time_after_pr}: {e}",
                              entry.get("source_pr", ""))
        merged_at = pr_data.get("merged_at")
        if not merged_at:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"min_build_time_after_pr #{min_build_time_after_pr} has no merged_at "
                          f"(is it merged?)",
                          entry.get("source_pr", ""))
        try:
            merged_dt = _parse_iso8601(merged_at)
            pin_dt = _parse_iso8601(pin_commit_date)
        except ValueError as e:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"timestamp parse failed: {e}", entry.get("source_pr", ""))
        if pin_dt < merged_dt:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"pin {pin} committed {pin_commit_date} is BEFORE "
                          f"PR #{min_build_time_after_pr} merged at {merged_at}. "
                          f"The pinned binary was tagged from a stale checkout; "
                          f"re-cut the artefact from a fresh main.",
                          entry.get("source_pr", ""))

    # 4. freshness_max_hours — absolute-wall-clock staleness check.
    if freshness_max_hours is not None:
        try:
            pin_dt = _parse_iso8601(pin_commit_date)
        except ValueError as e:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"pin commit-date parse failed: {e}",
                          entry.get("source_pr", ""))
        now = dt.datetime.now(dt.timezone.utc)
        age_hours = (now - pin_dt).total_seconds() / 3600
        if age_hours > freshness_max_hours:
            return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                          f"pin {pin} committed {pin_commit_date} is {age_hours:.1f}h old, "
                          f"exceeds freshness_max_hours={freshness_max_hours}. "
                          f"Re-cut the artefact from current main.",
                          entry.get("source_pr", ""))

    pr_list = ", ".join(f"#{n}" for n in must_contain_prs)
    detail = (f"repo={repo} pin={pin}[{pin_sha[:12]}] "
              f"confirmed_contains={len(must_contain_prs)} PR(s) ({pr_list}) "
              f"pin_committed={pin_commit_date}")
    return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS", detail,
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
        print(f"=== Summary: {passes} PASS  {fails} FAIL  {skips} SKIP  ({len(results)} total) ===")

    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
