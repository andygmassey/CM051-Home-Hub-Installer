#!/usr/bin/env bash
# ============================================================================
# tests/lib/fda_run_all.sh -- the ONE place that names the shipped extract call
# and the stand-in run_all signature, for every test that runs the install.sh
# ostler-fda wrapper against a fake ostler_fda package.
#
# WHY: #3098 changed the wrapper line to pass skip_sources and writer, and four
# tests that hard-coded `run_all(fda_dir)` or `def run_all(output_dir=None,
# enabled_sources=None)` went red one at a time. They now source this file, so
# the next signature change fails in fda_run_all_contract_check, once, with a
# message that says what moved, instead of as eleven unrelated arm failures.
#
# Source it; do not execute it. Exact strings, never looser patterns.
# ============================================================================

# The exact extract line in the shipped wrapper (install.sh).
FDA_RUN_ALL_CALL="_summary = run_all(fda_dir, skip_sources={'apple_music'}, writer='fda-rerun')"

# The stand-in's def line. Same parameters as vendor/ostler_fda/extract_all.py.
FDA_RUN_ALL_STUB_DEF='def run_all(output_dir=None, enabled_sources=None, skip_sources=None, writer="unrecorded"):'

# The keywords the shipped call passes, which the real run_all must accept.
FDA_RUN_ALL_REQUIRED_PARAMS="output_dir enabled_sources skip_sources writer"

# fda_run_all_contract_check <repo-root>
#   rc 0  install.sh holds FDA_RUN_ALL_CALL exactly once, the real run_all
#         takes every FDA_RUN_ALL_REQUIRED_PARAMS name, and the stub's
#         parameters equal the real ones.
#   rc 1  one of them moved. Prints which, on stderr.
#   rc 2  could not look (file missing / no python): CANNOT-RUN, not a pass.
fda_run_all_contract_check() {
    local root="$1" install real n py="${PY:-python3}"
    # A self-test sandbox holds a deliberately mutated install.sh and no vendor
    # tree; its parent run has already passed this check on the real tree.
    [[ "${FDA_RUN_ALL_SKIP_CONTRACT:-}" == "1" ]] && return 0
    install="${root}/install.sh"
    real="${root}/vendor/ostler_fda/extract_all.py"
    [[ -f "$install" && -f "$real" ]] || {
        echo "CANNOT-RUN: ${install} or ${real} missing" >&2; return 2; }
    n="$(grep -cxF -- "$FDA_RUN_ALL_CALL" "$install")"
    if [[ "$n" != "1" ]]; then
        echo "CONTRACT: install.sh has ${n} copies of the exact line: ${FDA_RUN_ALL_CALL}" >&2
        echo "          update tests/lib/fda_run_all.sh (call AND stub def) deliberately." >&2
        return 1
    fi
    "$py" -I - "$real" "$FDA_RUN_ALL_REQUIRED_PARAMS" "$FDA_RUN_ALL_STUB_DEF" <<'PYEOF' || return $?
import ast, sys
src = open(sys.argv[1]).read()
want = sys.argv[2].split()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.FunctionDef) and node.name == "run_all":
        have = [a.arg for a in node.args.args + node.args.kwonlyargs]
        missing = [w for w in want if w not in have]
        stub = ast.parse(sys.argv[3] + "\n    pass\n").body[0]
        stub_have = [a.arg for a in stub.args.args]
        if stub_have != have:
            print("CONTRACT: stub run_all params %s differ from the real %s; update "
                  "FDA_RUN_ALL_STUB_DEF in tests/lib/fda_run_all.sh" % (stub_have, have),
                  file=sys.stderr)
            sys.exit(1)
        if missing:
            print("CONTRACT: real run_all lacks %s (has %s); update tests/lib/fda_run_all.sh"
                  % (missing, have), file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
print("CANNOT-RUN: no def run_all in " + sys.argv[1], file=sys.stderr)
sys.exit(2)
PYEOF
}
