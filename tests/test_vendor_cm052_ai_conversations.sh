#!/usr/bin/env bash
# CM052 AI-Conversations vendor regression guard (#553 / #613)
# ============================================================
#
# The DMG ships the VENDORED copy at vendor/cm052_ai_conversations/,
# not the CM052 source repo. A stale or botched re-vendor here means
# the customer's AI Chats leg silently rots. This guard fails if:
#
#   1. The vendored file-set drifts from the contract pinned in CM052
#      docs/VENDOR_CM051.md (pyproject.toml + src/__init__.py +
#      src/cm052/*.py + src/cm052/adapters/*.py).
#   2. The pwg-ai-convo console entrypoint disappears from pyproject.
#   3. wire.py loses the external_llm episodic path or the
#      subscription-gate seam the installer's ordering depends on.
#   4. Excluded material (tests/, fixtures_private/, docs/, repo
#      metadata) sneaks into the vendored tree -- fixtures_private may
#      hold REAL operator data on a dev machine, so this is also a
#      PII guard.
#   5. Any vendored .py stops compiling (py_compile smoke).
#   6. The VENDOR_MANIFEST.toml entry loses its full pinned SHA or
#      its verify=full posture.
#   7. gui/project.yml stops bundling the tree into Resources (ship-
#      dark: the flag flip would then find nothing on a customer Mac).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENDORED="vendor/cm052_ai_conversations"
MANIFEST="vendor/VENDOR_MANIFEST.toml"

# 1. Contract file-set present.
required_files=(
    "pyproject.toml"
    "src/__init__.py"
    "src/cm052/__init__.py"
    "src/cm052/__main__.py"
    "src/cm052/cli.py"
    "src/cm052/provenance.py"
    "src/cm052/routing.py"
    "src/cm052/schemas.py"
    "src/cm052/subscription_gate.py"
    "src/cm052/unifier.py"
    "src/cm052/wire.py"
    "src/cm052/adapters/__init__.py"
    "src/cm052/adapters/channel_jsonl.py"
    "src/cm052/adapters/chatgpt_export.py"
    "src/cm052/adapters/claude_code_watcher.py"
    "src/cm052/adapters/claude_desktop_leveldb.py"
    "src/cm052/adapters/zeroclaw_sessions.py"
)
for f in "${required_files[@]}"; do
    if [ ! -f "$VENDORED/$f" ]; then
        echo "FAIL: $VENDORED/$f missing (stale/botched re-vendor)" >&2
        exit 1
    fi
done
echo "file-set check: all ${#required_files[@]} contract files present"

# 2. Console entrypoint intact.
if ! grep -q 'pwg-ai-convo = "src.cm052.cli:main"' "$VENDORED/pyproject.toml"; then
    echo "FAIL: pwg-ai-convo console entrypoint missing from vendored pyproject.toml" >&2
    exit 1
fi
echo "entrypoint check: pwg-ai-convo = src.cm052.cli:main declared"

# 3. wire.py keeps the external_llm episodic path + subscription gate.
if ! grep -q 'external_llm' "$VENDORED/src/cm052/wire.py"; then
    echo "FAIL: vendored wire.py lost the external_llm source_kind path" >&2
    exit 1
fi
if ! grep -q 'stage_episodic' "$VENDORED/src/cm052/wire.py"; then
    echo "FAIL: vendored wire.py lost stage_episodic (episodic artefacts never written)" >&2
    exit 1
fi
if ! grep -q 'subscription' "$VENDORED/src/cm052/subscription_gate.py"; then
    echo "FAIL: vendored subscription_gate.py no longer references subscription state" >&2
    exit 1
fi
echo "wire check: external_llm + stage_episodic + subscription gate present"

# 4. Excluded material must NOT be vendored (scope + PII guard).
for banned in tests fixtures_private docs prompts .github .claude; do
    if [ -e "$VENDORED/$banned" ]; then
        echo "FAIL: $VENDORED/$banned is vendored but excluded by contract (fixtures_private may hold real data)" >&2
        exit 1
    fi
done
for banned_file in CLAUDE.md README.md PLAN.md .env.example; do
    if [ -e "$VENDORED/$banned_file" ]; then
        echo "FAIL: $VENDORED/$banned_file is vendored but excluded by contract" >&2
        exit 1
    fi
done
echo "exclusion check: no tests/fixtures_private/docs/repo-metadata vendored"

# 5. Every vendored .py compiles.
if ! python3 - "$VENDORED" <<'PYEOF'
import pathlib, py_compile, sys
root = pathlib.Path(sys.argv[1])
bad = []
for p in sorted(root.rglob("*.py")):
    try:
        py_compile.compile(str(p), doraise=True)
    except py_compile.PyCompileError as e:
        bad.append(f"{p}: {e.msg}")
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PYEOF
then
    echo "FAIL: vendored CM052 sources do not compile" >&2
    exit 1
fi
echo "compile check: all vendored .py files py_compile clean"

# 6. Manifest entry: full pinned SHA + verify=full.
entry="$(awk '/name[[:space:]]*=[[:space:]]*"cm052_ai_conversations"/{found=1} found && /pinned_sha/{print; exit}' "$MANIFEST")"
if [ -z "$entry" ]; then
    echo "FAIL: no cm052_ai_conversations entry with pinned_sha in $MANIFEST" >&2
    exit 1
fi
sha="$(printf '%s' "$entry" | sed 's/.*"\([0-9a-f]*\)".*/\1/')"
if [ "${#sha}" -ne 40 ]; then
    echo "FAIL: cm052_ai_conversations pinned_sha is not a full 40-char SHA (got '${sha}')" >&2
    exit 1
fi
verify_line="$(awk '/name[[:space:]]*=[[:space:]]*"cm052_ai_conversations"/{found=1} found && /^verify/{print; exit}' "$MANIFEST")"
if ! printf '%s' "$verify_line" | grep -q '"full"'; then
    echo "FAIL: cm052_ai_conversations manifest entry is not verify=\"full\" (freshness gate would silently skip it)" >&2
    exit 1
fi
echo "manifest check: full pinned SHA ($sha) + verify=full"

# 7. gui/project.yml bundles the tree.
if ! grep -q 'vendor/cm052_ai_conversations' gui/project.yml; then
    echo "FAIL: gui/project.yml does not bundle vendor/cm052_ai_conversations (leg would ship dark FOREVER, flag or no flag)" >&2
    exit 1
fi
echo "bundle check: gui/project.yml copies the vendored tree into Resources"

echo "cm052_ai_conversations vendor regression guard: PASS"
