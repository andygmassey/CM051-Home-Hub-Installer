#!/usr/bin/env python3
# scripts/check_vendor_drift.py
# ============================================================================
# Vendor drift detector -- reads .vendor-manifests/*.yaml + vendor/VENDOR_MANIFEST.toml,
# probes GitHub for each tree's current source HEAD, and reports which vendored
# trees have drifted behind upstream since their pinned SHA.
#
# Ships alongside `scripts/verify_vendor_fresh.sh` (content gate) and
# `scripts/verify_cut_freshness.sh` (live-HEAD gate on the cut host). This script
# is the CI-executable variant that runs from GitHub Actions without a local
# checkout of every source repo.
#
# Contract:
#   1. Read .vendor-manifests/*.yaml -> per-tree GitHub owner/repo/branch/path.
#   2. Read vendor/VENDOR_MANIFEST.toml -> per-tree pinned_sha (lookup by name).
#   3. For each tree with a KNOWN GitHub source:
#        gh api repos/{o}/{r}/commits?sha={branch}&path={path}&per_page=1 -> HEAD
#        gh api repos/{o}/{r}/compare/{pinned_sha}...{HEAD} -> commits + ahead_by
#        Filter commits whose message matches ignore_commits_matching (optional).
#        Any surviving commit == DRIFT.
#   4. Trees with `<UNKNOWN -- retrofit needed>` in owner/repo are SKIPPED with
#      a WARN (kept in the report, never silently ignored).
#   5. Trees whose VENDOR_MANIFEST.toml [[tree]] carries `verify_exempt = true`
#      are SKIPPED with the exempt_reason surfaced.
#
# Exit codes:
#   0 -- no drift on any known-source tree (UNKNOWN + exempt trees are SKIPs)
#   1 -- drift detected on at least one tree
#   2 -- CLI error (missing files, malformed YAML, gh CLI missing, etc.)
#
# --json emits a machine-readable report the workflow feeds into the PR body.
# ============================================================================

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Install with: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
VENDOR_MANIFESTS_DIR = REPO_ROOT / ".vendor-manifests"
VENDOR_TOML = REPO_ROOT / "vendor" / "VENDOR_MANIFEST.toml"

UNKNOWN_MARKER = "<UNKNOWN -- retrofit needed>"
GH_API_TIMEOUT_SECONDS = 30


@dataclass
class TreeReport:
    name: str
    status: str                    # "fresh" | "drift" | "skip-unknown" | "skip-exempt" | "error"
    pinned_sha: str = ""
    head_sha: str = ""
    ahead_by: int = 0
    diverging_commits: list[dict] = field(default_factory=list)
    github: dict = field(default_factory=dict)
    detail: str = ""
    exempt_reason: str = ""


# ---------------------------------------------------------------------------
# Minimal TOML reader for VENDOR_MANIFEST.toml (only the fields we need).
#
# Python 3.11+ has tomllib built-in; use it when available. Fall back to a
# tiny hand-parser scoped to VENDOR_MANIFEST.toml's flat `[[tree]]` shape
# so this script works on any Python 3.9+ CI runner too.
# ---------------------------------------------------------------------------

def _load_vendor_toml(path: Path) -> list[dict]:
    """Return a list of tree dicts from VENDOR_MANIFEST.toml."""
    if not path.is_file():
        raise FileNotFoundError(f"VENDOR_MANIFEST.toml not found at {path}")
    text = path.read_text(encoding="utf-8")
    try:
        import tomllib
        data = tomllib.loads(text)
        return data.get("tree") or []
    except ImportError:
        pass
    # Fallback: hand-parse. VENDOR_MANIFEST.toml uses only flat scalar KV
    # inside repeated [[tree]] tables, no nested tables, no arrays of tables
    # beyond tree, no inline arrays we need to read. Keep the parser narrow.
    trees: list[dict] = []
    current: dict | None = None
    key_val_re = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$')
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip() if not raw_line.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        if line.strip() == "[[tree]]":
            if current is not None:
                trees.append(current)
            current = {}
            continue
        if current is None:
            continue
        m = key_val_re.match(line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        # Strip surrounding quotes (single or double).
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        # Booleans.
        if v == "true":
            current[k] = True
            continue
        if v == "false":
            current[k] = False
            continue
        current[k] = v
    if current is not None:
        trees.append(current)
    return trees


def _load_vendor_manifests_dir(path: Path) -> list[dict]:
    """Return a list of parsed .vendor-manifests/*.yaml docs."""
    if not path.is_dir():
        raise FileNotFoundError(f".vendor-manifests/ not found at {path}")
    out = []
    for f in sorted(path.glob("*.yaml")):
        doc = yaml.safe_load(f.read_text(encoding="utf-8"))
        if not isinstance(doc, dict) or "name" not in doc:
            print(f"WARN: {f} malformed (missing 'name') -- skipping", file=sys.stderr)
            continue
        doc["_source_file"] = str(f)
        out.append(doc)
    return out


# ---------------------------------------------------------------------------
# GitHub API helpers -- mirror verify_cut_manifest.py conventions.
# ---------------------------------------------------------------------------

def _gh_token_for(owner: str) -> str | None:
    try:
        r = subprocess.run(
            ["gh", "auth", "token", "--user", owner],
            capture_output=True, check=False, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    tok = r.stdout.decode("utf-8", "replace").strip()
    return tok or None


def _gh_api_json(path: str, token: str | None) -> tuple[Any, str]:
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


# ---------------------------------------------------------------------------
# Drift logic.
# ---------------------------------------------------------------------------

def _lookup_toml_tree(trees_toml: list[dict], name: str) -> dict | None:
    for t in trees_toml:
        if t.get("name") == name:
            return t
    return None


def _check_tree(manifest: dict, toml_tree: dict | None,
                ignore_patterns: list[str]) -> TreeReport:
    name = manifest.get("name", "?")
    gh_cfg = manifest.get("github") or {}
    report = TreeReport(name=name, status="error", github=gh_cfg)

    if toml_tree is None:
        report.detail = ("no matching [[tree]] in vendor/VENDOR_MANIFEST.toml -- "
                         "cannot resolve pinned_sha")
        return report

    if toml_tree.get("verify_exempt") is True:
        report.status = "skip-exempt"
        report.exempt_reason = toml_tree.get("exempt_reason", "") or "(no reason recorded)"
        report.detail = f"verify_exempt=true: {report.exempt_reason}"
        return report

    owner = gh_cfg.get("owner", "")
    repo = gh_cfg.get("repo", "")
    branch = gh_cfg.get("branch", "main")
    path = gh_cfg.get("path", ".")
    if owner == UNKNOWN_MARKER or repo == UNKNOWN_MARKER or not owner or not repo:
        report.status = "skip-unknown"
        report.detail = ("GitHub source lineage UNKNOWN -- retrofit "
                         ".vendor-manifests/{}.yaml with owner/repo".format(
                             manifest.get("name", "?").replace("/", "_")))
        return report

    pinned_sha = toml_tree.get("pinned_sha", "")
    if not pinned_sha:
        report.detail = "no pinned_sha in VENDOR_MANIFEST.toml"
        return report
    report.pinned_sha = pinned_sha

    source_repo = f"{owner}/{repo}"
    token = _gh_token_for(owner)
    if not token:
        report.detail = f"could not resolve gh token for owner {owner!r}"
        return report

    # Path-scoped HEAD probe. path="." means whole repo -> use branch HEAD.
    if path == "." or not path:
        branch_data, err = _gh_api_json(
            f"repos/{source_repo}/branches/{branch}", token)
        if err or not isinstance(branch_data, dict):
            report.detail = f"fetching {branch} for {source_repo}: {err or 'unexpected shape'}"
            return report
        head_sha = (branch_data.get("commit") or {}).get("sha", "")
    else:
        commits_data, err = _gh_api_json(
            f"repos/{source_repo}/commits?sha={branch}&path={path}&per_page=1", token)
        if err or not isinstance(commits_data, list):
            report.detail = f"fetching path HEAD for {source_repo}:{path}: {err or 'unexpected shape'}"
            return report
        if not commits_data:
            report.detail = f"no commits found on {source_repo}:{path}@{branch}"
            return report
        head_sha = commits_data[0].get("sha", "")

    if not head_sha:
        report.detail = f"no head SHA resolved for {source_repo}:{path}@{branch}"
        return report
    report.head_sha = head_sha

    if head_sha.startswith(pinned_sha) or pinned_sha.startswith(head_sha):
        report.status = "fresh"
        report.detail = f"pinned_sha == HEAD ({head_sha[:12]})"
        return report

    # Compare -- get list of intervening commits + optionally filter.
    compare, err = _gh_api_json(
        f"repos/{source_repo}/compare/{pinned_sha}...{head_sha}", token)
    if err or not isinstance(compare, dict):
        report.detail = f"comparing {pinned_sha[:8]}...{head_sha[:8]}: {err or 'unexpected shape'}"
        return report
    status = compare.get("status")
    report.ahead_by = int(compare.get("ahead_by") or 0)
    # `behind` = pin ahead of default; `identical` = same. Both treated as fresh.
    if status in ("behind", "identical"):
        report.status = "fresh"
        report.detail = f"pin at or ahead of HEAD (compare status: {status})"
        return report

    commits = compare.get("commits") or []
    filtered = []
    for c in commits:
        msg = ((c.get("commit") or {}).get("message") or "").strip()
        first_line = msg.splitlines()[0] if msg else ""
        if any(re.search(pat, first_line) for pat in ignore_patterns):
            continue
        # If a path filter is scoped (path != "."), fetch per-commit files
        # and confirm the commit touched the vendored path. Cheap enough
        # for the typical drift window (< 50 commits).
        if path and path != ".":
            commit_detail, cerr = _gh_api_json(
                f"repos/{source_repo}/commits/{c.get('sha', '')}", token)
            if cerr or not isinstance(commit_detail, dict):
                # If we can't fetch files, be conservative -- keep the commit.
                filtered.append({
                    "sha": c.get("sha", "")[:12],
                    "message": first_line[:120],
                    "note": f"could not fetch files ({cerr})",
                })
                continue
            touched = False
            for f in (commit_detail.get("files") or []):
                fname = f.get("filename") or ""
                if fname == path or fname.startswith(path.rstrip("/") + "/"):
                    touched = True
                    break
            if not touched:
                continue
        filtered.append({
            "sha": c.get("sha", "")[:12],
            "message": first_line[:120],
        })

    if not filtered:
        report.status = "fresh"
        report.detail = (f"HEAD moved to {head_sha[:12]} but no non-ignored commits "
                         f"touch {path!r} ({len(commits)} intervening total)")
        return report

    report.status = "drift"
    report.diverging_commits = filtered
    report.detail = (f"{len(filtered)} diverging commit(s) on {source_repo}:{path}@{branch} "
                     f"since pin {pinned_sha[:12]}")
    return report


def _render_markdown(reports: list[TreeReport]) -> str:
    drift = [r for r in reports if r.status == "drift"]
    fresh = [r for r in reports if r.status == "fresh"]
    skip_unknown = [r for r in reports if r.status == "skip-unknown"]
    skip_exempt = [r for r in reports if r.status == "skip-exempt"]
    errors = [r for r in reports if r.status == "error"]

    lines: list[str] = []
    lines.append("# Vendor drift report")
    lines.append("")
    lines.append(f"**Summary:** {len(drift)} DRIFT, {len(fresh)} fresh, "
                 f"{len(skip_unknown)} unknown-lineage, {len(skip_exempt)} exempt, "
                 f"{len(errors)} errors")
    lines.append("")

    if drift:
        lines.append("## Drift detected")
        lines.append("")
        for r in drift:
            gh = r.github
            src = f"{gh.get('owner', '?')}/{gh.get('repo', '?')}"
            lines.append(f"### `{r.name}`")
            lines.append("")
            lines.append(f"- source: `{src}:{gh.get('path', '.')}` on `{gh.get('branch', 'main')}`")
            lines.append(f"- pinned: `{r.pinned_sha[:12]}`")
            lines.append(f"- HEAD:   `{r.head_sha[:12]}` (ahead_by={r.ahead_by})")
            lines.append("")
            lines.append("Diverging commits:")
            lines.append("")
            for c in r.diverging_commits[:20]:
                extra = f" ({c['note']})" if c.get("note") else ""
                lines.append(f"- `{c['sha']}` {c['message']}{extra}")
            if len(r.diverging_commits) > 20:
                lines.append(f"- ... (+{len(r.diverging_commits) - 20} more)")
            lines.append("")
            lines.append("Suggested re-vendor:")
            lines.append("")
            lines.append("```bash")
            lines.append(f"# From CM051 repo root, with $HR015 / $CM041 / etc exported:")
            lines.append(f"scripts/sync_vendor.sh {r.name}")
            lines.append(f"# Then review vendor/divergences/*.patch, regenerate if needed,")
            lines.append(f"# and update pinned_sha in vendor/VENDOR_MANIFEST.toml.")
            lines.append("```")
            lines.append("")

    if skip_unknown:
        lines.append("## Skipped -- source lineage UNKNOWN")
        lines.append("")
        lines.append("These trees carry `<UNKNOWN -- retrofit needed>` in their "
                     "`.vendor-manifests/*.yaml`. Retrofit the GitHub owner/repo "
                     "when the source moves to a mirror we can enumerate:")
        lines.append("")
        for r in skip_unknown:
            lines.append(f"- `{r.name}` -- {r.detail}")
        lines.append("")

    if skip_exempt:
        lines.append("## Skipped -- verify_exempt in VENDOR_MANIFEST.toml")
        lines.append("")
        for r in skip_exempt:
            lines.append(f"- `{r.name}` -- {r.exempt_reason}")
        lines.append("")

    if errors:
        lines.append("## Errors")
        lines.append("")
        for r in errors:
            lines.append(f"- `{r.name}` -- {r.detail}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Detect vendor drift against upstream GitHub sources.")
    ap.add_argument("--json", action="store_true", help="Emit machine-readable JSON report on stdout")
    ap.add_argument("--markdown-out", default=None,
                    help="Write a human-readable markdown report to this file")
    ap.add_argument("--only-name", default=None,
                    help="Only check the vendor tree with this name (useful for smoke tests)")
    ap.add_argument("--ignore-commits-matching", action="append", default=None,
                    help="Regex to filter commit subject lines (repeatable). "
                         "Default: ^chore\\(fmt\\), ^docs:, ^chore\\(docs\\)")
    args = ap.parse_args()

    ignore_patterns = args.ignore_commits_matching or [
        r"^chore\(fmt\)",
        r"^docs:",
        r"^chore\(docs\)",
    ]

    try:
        manifests = _load_vendor_manifests_dir(VENDOR_MANIFESTS_DIR)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    if args.only_name:
        manifests = [m for m in manifests if m.get("name") == args.only_name]
        if not manifests:
            print(f"ERROR: no manifest matches name={args.only_name!r}", file=sys.stderr)
            return 2

    try:
        trees_toml = _load_vendor_toml(VENDOR_TOML)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    reports: list[TreeReport] = []
    for m in manifests:
        toml_tree = _lookup_toml_tree(trees_toml, m["name"])
        reports.append(_check_tree(m, toml_tree, ignore_patterns))

    drift_count = sum(1 for r in reports if r.status == "drift")

    if args.markdown_out:
        Path(args.markdown_out).write_text(_render_markdown(reports), encoding="utf-8")

    if args.json:
        print(json.dumps({
            "reports": [asdict(r) for r in reports],
            "summary": {
                "drift": drift_count,
                "fresh": sum(1 for r in reports if r.status == "fresh"),
                "skip_unknown": sum(1 for r in reports if r.status == "skip-unknown"),
                "skip_exempt": sum(1 for r in reports if r.status == "skip-exempt"),
                "error": sum(1 for r in reports if r.status == "error"),
                "total": len(reports),
            },
        }, indent=2))
    else:
        print(_render_markdown(reports))

    return 1 if drift_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
