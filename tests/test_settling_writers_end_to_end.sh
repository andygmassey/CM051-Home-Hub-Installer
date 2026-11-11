#!/usr/bin/env bash
# Wrapper: runs the end-to-end settling test under a throwaway HOME so nothing
# touches the real state dir or Keychain. CM044_ROOT locates the reader; without
# it the reader assertions are CANNOT-RUN (rc 3), never PASS.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
# CI has no CM044 checkout (private cross-repo). The shard assertions still run there;
# the bar assertions are reported CANNOT-RUN with a warning annotation.
[ "${CI:-}" = true ] && export SETTLING_E2E_READER_OPTIONAL=1
HOME="$H" python3 -I "$REPO_ROOT/tests/test_settling_writers_end_to_end.py"
