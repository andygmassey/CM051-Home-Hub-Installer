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
#   - verify_cut_manifest.py    — THIS SCRIPT (9-primitive YAML gate)
#
# See cut-manifests/README.md for schema.
# ============================================================================

import argparse
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
    """Assert `ostler-payload/VERSION` matches the bundled daemon `--version`.

    Both values are normalised to the semver core via `_normalise_version`
    before comparison. SKIPs when the built app is not present (local dev,
    pre-build CI). FAILs on any read error, invocation error, or unparseable
    version.
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
    try:
        result = subprocess.run(
            [str(daemon_bin), "--version"],
            capture_output=True, check=False, timeout=30,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"daemon --version invocation failed: {e}",
                      entry.get("source_pr", ""))
    if result.returncode != 0:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL",
                      f"daemon --version exited {result.returncode}: "
                      f"{result.stderr.decode('utf-8', 'replace').strip()[:200]}",
                      entry.get("source_pr", ""))
    daemon_raw = result.stdout.decode("utf-8", "replace").strip().splitlines()[0] if result.stdout else ""

    try:
        payload_norm = _normalise_version(payload_raw)
    except ValueError as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"payload VERSION unparseable: {e}",
                      entry.get("source_pr", ""))
    try:
        daemon_norm = _normalise_version(daemon_raw)
    except ValueError as e:
        return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                      "FAIL", f"daemon --version unparseable: {e}",
                      entry.get("source_pr", ""))

    ok = payload_norm == daemon_norm
    status = "PASS" if ok else "FAIL"
    detail = (f"payload_raw={payload_raw!r} daemon_raw={daemon_raw!r} "
              f"payload_norm={payload_norm} daemon_norm={daemon_norm}")
    return Result(entry["id"], entry["title"], "payload_version_matches_daemon_version",
                  status, detail, entry.get("source_pr", ""))


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
