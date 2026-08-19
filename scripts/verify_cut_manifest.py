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
    # "PASS" | "FAIL" | "SKIP" | "CANNOT-RUN"
    #
    # CANNOT-RUN is NOT SKIP. SKIP means "this proof does not apply here" (no
    # built .app on a CI box, no box host, not a PR context). CANNOT-RUN means
    # "this proof was DEMANDED and its apparatus is missing", which is a defect
    # in the wiring, not a property of the environment. They must never share an
    # exit code: a row that always skips is indistinguishable from a row that
    # always passes, and that is exactly how permanent-pr-branch-not-stale-vs-main
    # sat green and unreachable from the day it was written.
    status: str
    detail: str = ""
    source_pr: str = ""


def emit(res: Result, colour: bool) -> None:
    if colour:
        badge = {"PASS": f"{GREEN}PASS{RESET}", "FAIL": f"{RED}FAIL{RESET}",
                 "SKIP": f"{YELLOW}SKIP{RESET}",
                 "CANNOT-RUN": f"{RED}CANNOT-RUN{RESET}"}[res.status]
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
    """Resolve a gh token for `owner` via `gh auth token --user <owner>`.

    Returns None on failure. Caller decides whether the missing token is fatal
    (typical: FAIL) or advisory (rare).
    """
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


def check_pinned_artefact_freshness(entry: dict, ctx: dict) -> Result:
    """Prove that the pinned pre-built artefact (daemon tarball, RemoteCapture,
    ...) contains every merged-to-source change in the artefact's compilation
    sub-tree. Fails closed when the source repo has moved past the pin on any
    non-ignored commit that touches `source_paths`.
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
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"could not resolve gh token for owner {owner!r} "
                      f"(need `gh auth login --user {owner}`)",
                      entry.get("source_pr", ""))

    pin_sha, err = _resolve_pin_commit(source_repo, tag, token)
    if err:
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"resolving tag {tag!r} in {source_repo}: {err}",
                      entry.get("source_pr", ""))

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
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      f"pinned {artefact} v{version} (@{pin_sha[:8]}) == {default_branch} HEAD "
                      f"({head_sha[:8]})", entry.get("source_pr", ""))

    compare, err = _gh_api_json(f"repos/{source_repo}/compare/{pin_sha}...{head_sha}", token)
    if err or not isinstance(compare, dict):
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                      f"comparing {pin_sha[:8]}...{head_sha[:8]}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))
    status = compare.get("status")
    # `behind` means the pin is AHEAD of default (a customer-hosted branch cut)
    # -- treat as pass, defer to the maintainer.
    if status == "behind" or status == "identical":
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      f"pinned {artefact} v{version} (@{pin_sha[:8]}) is at or ahead of "
                      f"{default_branch} HEAD ({head_sha[:8]}) on {source_paths}",
                      entry.get("source_pr", ""))

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
        return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "PASS",
                      f"pinned {artefact} v{version} (@{pin_sha[:8]}) is at or ahead of "
                      f"{default_branch} HEAD ({head_sha[:8]}) on {source_paths} "
                      f"(all {len(commits)} intervening commits are ignored or off-tree)",
                      entry.get("source_pr", ""))

    lines = [f"pinned {artefact} v{version} (@{pin_sha[:8]}) is stale vs {default_branch} HEAD "
             f"({head_sha[:8]}); {len(diverging)} diverging commit(s) touch {source_paths}:"]
    for short, subj, pat in diverging[:10]:
        lines.append(f"    {short} {subj}  [{pat}]")
    if len(diverging) > 10:
        lines.append(f"    ... (+{len(diverging) - 10} more)")
    lines.append("Recovery: cut a new release from source HEAD; bump the pin in "
                 f"{pin_source.get('file')}; rebuild.")
    return Result(entry["id"], entry["title"], "pinned_artefact_freshness", "FAIL",
                  " ".join(lines) if len(lines) == 1 else "\n        ".join(lines),
                  entry.get("source_pr", ""))


# ---------------------------------------------------------------------------
# pin_matches_latest_release_tag -- close the class of failure where a source
# repo has cut a NEW hub-vX.Y.Z release, but CM051's pin still points at the
# previous release. Sibling to pinned_artefact_freshness (which compares the
# pinned tag against source HEAD): this primitive compares the pinned VERSION
# against the LATEST published RELEASE on the release-hosting repo. Fails
# closed when they diverge.
#
# Distinct failure mode from pinned_artefact_freshness:
#   pinned_artefact_freshness: "did source HEAD move past the pinned tag?"
#   pin_matches_latest_release_tag: "did a new release tag land that the pin
#                                    does not yet reflect?"
# A pin can be fresh vs source (nothing merged since the tag) yet still lag
# behind a subsequent release rebuild triggered off the same source SHA (e.g.
# rebuilt tarball fixes a packaging bug). Both gates protect against distinct
# real-world drift shapes.
#
# Contract:
#   1. Read pinned version from `pin_file` using `pin_var_pattern` (single
#      capture group is the version).
#   2. `gh api repos/{release_repo}/releases?per_page=100&page=N` -- paginated
#      to cover more than 100 releases if needed.
#   3. Filter releases to those matching `tag_prefix` (e.g. "hub-v").
#      Non-drafts + non-prereleases only.
#   4. Pick the newest by `published_at`.
#   5. Strip `tag_prefix` -> latest_version. Assert equal to pinned version.
#
# Fail-closed on network errors, missing tokens, empty release lists, and
# malformed responses (matches pinned_artefact_freshness discipline).
# ---------------------------------------------------------------------------

def _list_releases_paginated(source_repo: str, token: str | None,
                             max_pages: int = 5) -> tuple[list[dict] | None, str]:
    """Fetch up to max_pages*100 releases. Fail-closed on any API error."""
    out: list[dict] = []
    for page in range(1, max_pages + 1):
        data, err = _gh_api_json(
            f"repos/{source_repo}/releases?per_page=100&page={page}", token)
        if err:
            return None, err
        if not isinstance(data, list):
            return None, f"unexpected releases response shape: {type(data).__name__}"
        if not data:
            break
        out.extend(data)
        if len(data) < 100:
            break
    return out, ""


def check_pin_matches_latest_release_tag(entry: dict, ctx: dict) -> Result:
    """Assert the pinned version matches the latest release tag on the release-hosting repo.

    Cross-repo consistency gate. See module-level docstring above for rationale
    + contract. Every failure mode fails CLOSED (no silent pass on transient
    outages), matching pinned_artefact_freshness discipline.
    """
    proof = entry["proof"]
    release_repo = proof.get("release_repo")
    pin_file = proof.get("pin_file")
    pin_var_pattern = proof.get("pin_var_pattern")
    tag_prefix = proof.get("tag_prefix", "")
    allow_prerelease = bool(proof.get("allow_prerelease", False))

    if not release_repo or "/" not in release_repo:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      f"release_repo missing or malformed: {release_repo!r}",
                      entry.get("source_pr", ""))
    if not pin_file or not pin_var_pattern:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      "pin_file + pin_var_pattern required",
                      entry.get("source_pr", ""))

    version, verr = _extract_pinned_version(ctx["cm051_dir"], {
        "file": pin_file, "pattern": pin_var_pattern})
    if verr:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      f"resolving pinned version: {verr}", entry.get("source_pr", ""))

    owner = _repo_owner(release_repo)
    token = _gh_token_for(owner)
    if token is None:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      f"could not resolve gh token for owner {owner!r} "
                      f"(need `gh auth login --user {owner}`)",
                      entry.get("source_pr", ""))

    releases, rerr = _list_releases_paginated(release_repo, token)
    if rerr:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      f"listing releases on {release_repo}: {rerr}",
                      entry.get("source_pr", ""))

    # Filter to non-draft, non-prerelease (unless allow_prerelease), matching prefix.
    candidates = []
    for r in releases or []:
        if not isinstance(r, dict):
            continue
        if r.get("draft"):
            continue
        if r.get("prerelease") and not allow_prerelease:
            continue
        tag = r.get("tag_name") or ""
        if tag_prefix and not tag.startswith(tag_prefix):
            continue
        pub = r.get("published_at") or ""
        candidates.append((pub, tag))

    if not candidates:
        return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag", "FAIL",
                      f"no releases matching prefix {tag_prefix!r} on {release_repo} "
                      f"(scanned {len(releases or [])})",
                      entry.get("source_pr", ""))

    # Sort newest-first by published_at (ISO 8601 sorts lexically).
    candidates.sort(reverse=True)
    latest_tag = candidates[0][1]
    latest_version = latest_tag[len(tag_prefix):] if tag_prefix else latest_tag

    ok = latest_version == version
    status = "PASS" if ok else "FAIL"
    if ok:
        detail = (f"pin={version} matches latest {tag_prefix}* release "
                  f"({latest_tag}) on {release_repo}")
    else:
        detail = (f"DRIFT: pin={version} in {pin_file} but latest {tag_prefix}* "
                  f"release on {release_repo} is {latest_tag} (v{latest_version}). "
                  f"Recovery: bump the pin in {pin_file} to {latest_version} (or "
                  f"cut a new release matching v{version} if the pin is intentional).")
    return Result(entry["id"], entry["title"], "pin_matches_latest_release_tag",
                  status, detail, entry.get("source_pr", ""))


# ---------------------------------------------------------------------------
# pr_branch_not_stale_vs_main -- catch the class of failure where a PR is
# labelled `mergeable: MERGEABLE` by the GitHub API but its base is many
# commits behind main; merging as-is silently REVERTS a critical recent
# commit. Filed as `feedback_mergeable_api_state_isnt_semantic_safety`
# 2026-07-31, sibling to `feedback_pr_state_via_api_not_assertion`.
#
# The v1.0.13 near-miss shape (PR #484): branch predated the daemon pin bump
# PR #492; merging it AS-IS would have reverted 0.4.43 -> 0.4.41. TNM caught
# it before merging by manually rebasing; this primitive turns that into a
# mechanical gate.
#
# Contract:
#   1. Read the PR number from env `PR_NUMBER` (populated by GHA
#      `github.event.pull_request.number`); skip cleanly if absent (local
#      dev / non-PR CI).
#
#      THE ROW SPENT ITS WHOLE LIFE ON THAT SKIP. `grep -rn PR_NUMBER
#      .github/workflows/` returned NOTHING when this was measured on
#      2026-08-19, while the same grep for `pull_request` matched 12 files, so
#      the absence was real and not a broken predicate. No caller ever set the
#      variable, so the primitive returned SKIP every single time, and SKIP and
#      PASS both leave main()'s exit code at 0. A row that always skips reports
#      identically to a row that always passes.
#
#      The wiring now lives in .github/workflows/pr-branch-staleness.yml, which
#      sets PR_NUMBER and passes `--require-kind pr_branch_not_stale_vs_main`.
#      With that flag an all-SKIP outcome exits 3 (CANNOT-RUN), so the row can
#      never again be green by being unreachable.
#   2. `gh api repos/{this_repo}/pulls/{n}` -> base.sha, head.sha, base.ref,
#      merge_commit_sha.
#   3. `gh api repos/{this_repo}/compare/{base.sha}...{base.ref}` where
#      base.ref is HEAD of the target branch. Count commits main has that
#      the PR branch does not.
#   4. If count > max_commits_behind (default 10) -> FAIL, list the
#      diverging commits + rebase-recovery instructions.
#
# Fail-closed on any API error. Skips when PR_NUMBER unset OR when
# GITHUB_REPOSITORY unset -- both required for the primitive to apply.
# ---------------------------------------------------------------------------

def check_pr_branch_not_stale_vs_main(entry: dict, ctx: dict) -> Result:
    """Assert the current PR branch's base is not stale vs the target branch."""
    proof = entry["proof"]
    max_behind = int(proof.get("max_commits_behind", 10))
    ignore_patterns = proof.get("ignore_commits_matching") or []

    pr_number = os.environ.get("PR_NUMBER", "").strip()
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if not pr_number or not repo:
        missing = [name for name, val in (("PR_NUMBER", pr_number),
                                          ("GITHUB_REPOSITORY", repo)) if not val]
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "SKIP",
                      f"not a PR context: unset {' + '.join(missing)} "
                      f"(set: {', '.join(n for n in ('PR_NUMBER', 'GITHUB_REPOSITORY') if n not in missing) or 'none'}). "
                      "The PR-context runner is the `pr-staleness` job in "
                      ".github/workflows/pr-branch-staleness.yml, which passes "
                      "--require-kind pr_branch_not_stale_vs_main so this SKIP "
                      "becomes CANNOT-RUN (exit 3) rather than a silent pass.",
                      entry.get("source_pr", ""))

    owner = _repo_owner(repo)
    token = _gh_token_for(owner) or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"could not resolve gh token for owner {owner!r}",
                      entry.get("source_pr", ""))

    pr, err = _gh_api_json(f"repos/{repo}/pulls/{pr_number}", token)
    if err or not isinstance(pr, dict):
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"fetching PR #{pr_number} on {repo}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))

    base = pr.get("base") or {}
    base_sha = base.get("sha", "")
    base_ref = base.get("ref", "")
    if not base_sha or not base_ref:
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"PR #{pr_number} missing base.sha or base.ref",
                      entry.get("source_pr", ""))

    # Fetch current HEAD of the target branch.
    branch, err = _gh_api_json(f"repos/{repo}/branches/{base_ref}", token)
    if err or not isinstance(branch, dict):
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"fetching {base_ref} HEAD for {repo}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))
    head_sha = (branch.get("commit") or {}).get("sha", "")
    if not head_sha:
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"branch response missing commit.sha: {branch}",
                      entry.get("source_pr", ""))

    if base_sha == head_sha:
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "PASS",
                      f"PR #{pr_number} branch is up to date with {base_ref} ({head_sha[:8]})",
                      entry.get("source_pr", ""))

    compare, err = _gh_api_json(f"repos/{repo}/compare/{base_sha}...{head_sha}", token)
    if err or not isinstance(compare, dict):
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                      f"comparing {base_sha[:8]}...{head_sha[:8]}: {err or 'unexpected shape'}",
                      entry.get("source_pr", ""))

    ahead_by = int(compare.get("ahead_by") or 0)
    commits = compare.get("commits") or []

    # THE COMMITS ARRAY IS CAPPED. GitHub's compare endpoint returns at most 250
    # entries in `.commits` while `.ahead_by` reports the true total, with no
    # error and no flag. Measured 2026-08-19 against PR #509: ahead_by=393,
    # len(commits)=250. Filtering ignore_commits_matching over the capped page
    # and reporting the survivor count as "commits behind" understates the gap,
    # and in the worst case FALSELY PASSES: if every one of the 250 fetched
    # commits matched an ignore pattern, `surviving` would be 0 while 143
    # un-inspected commits sat unexamined. An unexamined commit is not an
    # ignorable one -- count the remainder as non-ignored and say so.
    uninspected = max(0, ahead_by - len(commits))

    surviving = []
    ignored = 0
    for c in commits:
        msg = ((c.get("commit") or {}).get("message") or "").strip()
        first_line = msg.splitlines()[0] if msg else ""
        if any(re.search(pat, first_line) for pat in ignore_patterns):
            ignored += 1
            continue
        surviving.append((c.get("sha", "")[:8], first_line[:120]))

    non_ignored_total = len(surviving) + uninspected
    denom = (f"compare {base_sha[:8]}...{head_sha[:8]}: ahead_by={ahead_by}, "
             f"{len(commits)} commit message(s) inspected, {ignored} matched "
             f"ignore_commits_matching={ignore_patterns or '[]'}, "
             f"{uninspected} NOT inspected (GitHub caps .commits at 250) and counted "
             f"as non-ignored")

    if non_ignored_total <= max_behind:
        return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "PASS",
                      f"PR #{pr_number} branch base is {ahead_by} commit(s) behind {base_ref} "
                      f"HEAD ({head_sha[:8]}); {non_ignored_total} non-ignored, within "
                      f"max_commits_behind={max_behind}. {denom}",
                      entry.get("source_pr", ""))

    lines = [f"PR #{pr_number} branch base ({base_sha[:8]}) is {non_ignored_total} non-ignored "
             f"commit(s) behind {base_ref} HEAD ({head_sha[:8]}); "
             f"max_commits_behind={max_behind} exceeded.",
             f"measured: {denom}",
             f"expected: at most {max_behind} non-ignored commit(s) between the PR base and "
             f"{base_ref} HEAD on {repo}",
             "the commits this branch would merge WITHOUT:"]
    for short, subj in surviving[:10]:
        lines.append(f"    {short} {subj}")
    if len(surviving) > 10:
        lines.append(f"    ... (+{len(surviving) - 10} more listed)")
    if uninspected:
        lines.append(f"    ... (+{uninspected} beyond the 250-commit compare cap, not listed)")
    lines.append(f"Recovery: merge {base_ref} into the branch + push. See "
                 "feedback_mergeable_api_state_isnt_semantic_safety.")
    return Result(entry["id"], entry["title"], "pr_branch_not_stale_vs_main", "FAIL",
                  "\n        ".join(lines), entry.get("source_pr", ""))


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
    "pin_matches_latest_release_tag": check_pin_matches_latest_release_tag,
    "pr_branch_not_stale_vs_main": check_pr_branch_not_stale_vs_main,
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
    ap.add_argument("--only-kind", action="append", default=[], metavar="KIND",
                    help="Run ONLY entries whose proof.kind matches. Repeatable. "
                         "Lets a CI job exercise one primitive without a built .app.")
    ap.add_argument("--require-kind", action="append", default=[], metavar="KIND",
                    help="Demand that this proof.kind actually RAN. If every entry of "
                         "that kind ended SKIP -- or the manifests contain none at all -- "
                         "exit 3 (CANNOT-RUN). Repeatable. This is the anti-silent-skip "
                         "lever: a row that always skips reports identically to a row "
                         "that always passes unless something demands it ran.")
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

    only_kinds = set(args.only_kind)
    require_kinds = list(dict.fromkeys(args.require_kind))
    entries_seen = 0
    entries_filtered_out = 0

    for label, doc in manifests:
        if not args.json:
            print(f"--- {label} ({len(doc.get('entries', []))} entries) ---")
        for entry in doc.get("entries", []):
            entries_seen += 1
            if only_kinds and entry.get("proof", {}).get("kind") not in only_kinds:
                entries_filtered_out += 1
                continue
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

    # -----------------------------------------------------------------------
    # --require-kind: the anti-silent-skip lever.
    #
    # permanent-pr-branch-not-stale-vs-main shipped as a permanent SKIP. It
    # reads PR_NUMBER, no workflow ever set PR_NUMBER, so it returned SKIP on
    # every invocation from the day it was written -- and SKIP and PASS both
    # leave the exit code at 0. The row looked like coverage and asserted
    # nothing. Naming a kind here says "this MUST have executed"; if it did not,
    # the run ends CANNOT-RUN (3), never 0.
    # -----------------------------------------------------------------------
    cannot_run: list[str] = []
    for kind in require_kinds:
        of_kind = [r for r in results if r.kind == kind]
        ran = [r for r in of_kind if r.status not in ("SKIP", "CANNOT-RUN")]
        if not of_kind:
            cannot_run.append(
                f"--require-kind {kind}: 0 entries of that kind exist across "
                f"{[Path(str(m.get('version', '?'))).name for _, m in manifests]} "
                f"({entries_seen} entries read). Nothing was measured, so nothing was proven.")
        elif not ran:
            reasons = "; ".join(f"{r.id}: {r.detail}" for r in of_kind) or "no detail recorded"
            cannot_run.append(
                f"--require-kind {kind}: {len(of_kind)} entr(y/ies) of that kind, "
                f"{len(ran)} RAN, {len(of_kind) - len(ran)} SKIPPED. {reasons}")
        else:
            # Upgrade the surviving skips so the count below is honest, but the
            # kind DID run, so this is not a CANNOT-RUN.
            pass

    passes = sum(1 for r in results if r.status == "PASS")
    fails = sum(1 for r in results if r.status == "FAIL")
    skips = sum(1 for r in results if r.status == "SKIP")
    cannots = sum(1 for r in results if r.status == "CANNOT-RUN")

    if args.json:
        print(json.dumps({
            "app_path": str(app_path),
            "results": [asdict(r) for r in results],
            "summary": {"pass": passes, "fail": fails, "skip": skips,
                        "cannot_run": cannots, "total": len(results),
                        "entries_read": entries_seen,
                        "entries_filtered_out_by_only_kind": entries_filtered_out,
                        "require_kind_failures": cannot_run},
        }, indent=2))
    else:
        print()
        print(f"=== Summary: {passes} PASS  {fails} FAIL  {skips} SKIP  "
              f"{cannots} CANNOT-RUN  ({len(results)} evaluated of {entries_seen} entries read"
              + (f", {entries_filtered_out} filtered out by --only-kind" if only_kinds else "")
              + ") ===")
        for kind in require_kinds:
            of_kind = [r for r in results if r.kind == kind]
            ran = [r for r in of_kind if r.status not in ("SKIP", "CANNOT-RUN")]
            print(f"    required kind {kind}: {len(of_kind)} entr(y/ies), {len(ran)} RAN, "
                  f"{len(of_kind) - len(ran)} did not")
        if cannot_run:
            print()
            for line in cannot_run:
                print(f"  CANNOT-RUN  {line}", file=sys.stderr)

    if cannot_run:
        return 3
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
