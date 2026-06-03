#!/usr/bin/env bash
#
# test_cm048_prompts_packaged.sh
#
# Byte-walking regression test for the CM048 prompt-packaging fix
# (recut 2026-06-03). Refuses the exact failure shape that left every
# dispatched conversation dead at step 01_classify on a fresh install:
# the pipeline loads its LLM prompt templates from a `prompts/` directory
# that must sit beside `src/` in site-packages (src/prompts.py resolves
# Path(__file__).parent.parent / "prompts"), but the vendored
# pyproject.toml packaged only `src*`, so pip never shipped the prompts
# and load_prompt raised "Prompt not found: .../site-packages/prompts/
# 01_classify.md".
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. pyproject packages.find does NOT include prompts*
#   2. there is NO package-data declaration shipping prompts/*.md
#   3. prompts/ is NOT an installable package (no __init__.py marker)
#   4. the prompt templates the pipeline references are absent
#
# All four axes must hold for the prompts to land in site-packages, per
# locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM048="$REPO_ROOT/vendor/cm048_pipeline"
PYPROJECT="$CM048/pyproject.toml"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

# Axis 1: packages.find must include prompts* so setuptools discovers it.
if [[ ! -f "$PYPROJECT" ]]; then
    failure "vendor/cm048_pipeline/pyproject.toml missing"
elif ! grep -Eq 'include *= *\[[^]]*"prompts\*?"' "$PYPROJECT"; then
    failure "pyproject packages.find does not include 'prompts*' — pip ships only src and the pipeline dies at 01_classify"
fi

# Axis 2: a package-data declaration must ship the prompt markdown.
if [[ -f "$PYPROJECT" ]] && ! grep -Eq 'prompts *= *\[[^]]*"\*\.md"' "$PYPROJECT"; then
    failure "pyproject has no [tool.setuptools.package-data] prompts = [\"*.md\"] — the .md templates are not installed"
fi

# Axis 3: prompts/ must be an installable package (find needs the marker).
if [[ ! -f "$CM048/prompts/__init__.py" ]]; then
    failure "vendor/cm048_pipeline/prompts/__init__.py missing — setuptools will not treat prompts/ as a package to ship"
fi

# Axis 4: the prompt templates the pipeline references must be present.
for name in 01_classify _conventions; do
    if [[ ! -f "$CM048/prompts/${name}.md" ]]; then
        failure "vendor/cm048_pipeline/prompts/${name}.md missing — pipeline references it"
    fi
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_cm048_prompts_packaged: FAILED" >&2
    exit 1
fi
echo "test_cm048_prompts_packaged: prompts will ship to site-packages (find + package-data + marker + templates)"
