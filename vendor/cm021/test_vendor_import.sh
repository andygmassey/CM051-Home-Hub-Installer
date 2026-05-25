#!/usr/bin/env bash
# CX-81 B2 + CX-83 vendor/cm021 import regression
# ===============================================
#
# Asserts that vendor/cm021/ ships the pieces install.sh's
# hydrate_email sub-phase + the email-ingest LaunchAgent's hourly
# tick need at customer install time:
#
#   - pyproject.toml         declares pwg-email-ingest console script
#   - src/cli.py             implements the `mbox <path>` subcommand
#   - src/filters.py         EmailFilter (CM021's noise filter)
#   - src/parsers/...        FastMboxParser + MboxParser
#
# Before CX-83 the tick.sh wrapper called `pwg-email-ingest mbox
# <path>` but the CLI did not exist anywhere on disk: tick.sh's
# `command -v pwg-email-ingest` returned nothing and the hourly
# LaunchAgent exited 127 on every customer install. This script
# catches a regression of that exact shape: if a future refactor
# drops the CLI / pyproject / submodule the import fails and the
# script exits non-zero. Wire into make check / CI so the
# regression is visible BEFORE a customer install.
#
# Naming-collision sanity: CM021 (email-intelligence) is the
# canonical email ingest substrate. CM046 (PWG-Email-Intelligence)
# is research-only. If a future agent vendors CM046 in here by
# mistake, this script's structural assertions still pass against
# CM021 -- but `make check` should fail because pwg-email-ingest
# would not be importable. The cross-repo confusion was the
# central CX-81 B2 probe finding.
#
# Network-free, env-var-free, dependency-free for the structural
# check. The optional import-time check needs CM021's runtime
# deps (httpx, beautifulsoup4); falls back to inconclusive when
# those are absent rather than failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Structural check -- always runs, deps-free.
missing=""
for path in \
    pyproject.toml \
    src/__init__.py \
    src/cli.py \
    src/filters.py \
    src/parsers/__init__.py \
    src/parsers/fast_mbox_parser.py \
    src/parsers/mbox_parser.py
do
    if [ ! -e "$SCRIPT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/cm021/ missing paths:$missing" >&2
    echo "      Re-sync from the CM021 email-intelligence repo (see CX-83)." >&2
    exit 1
fi
echo "structural check: vendor/cm021/ contains pyproject.toml + src/cli.py + filters.py + parsers/"

# Pyproject must declare the pwg-email-ingest console_script. If a
# refactor drops the entry point the CLI will not appear on the
# email-ingest venv's PATH after pip-install and tick.sh will exit
# 127 again -- exactly the latent bug CX-83 fixed.
if ! grep -q '^pwg-email-ingest *= *"src\.cli:main"' "$SCRIPT_DIR/pyproject.toml"; then
    echo "FAIL: vendor/cm021/pyproject.toml does not declare pwg-email-ingest = src.cli:main" >&2
    echo "      Without this the hourly LaunchAgent's tick exits 127." >&2
    exit 1
fi
echo "pyproject check: pwg-email-ingest console script declared"

# CLI must expose the `mbox <path>` subcommand shape because
# vendor/email_ingest/bin/email-ingest-tick.sh calls it positionally:
#     "$PWG_EMAIL_INGEST" mbox "$MBOX"
# Switching to a flag-based interface (--mbox) would break the tick
# script silently.
# Use perl -0 for multi-line matching: add_parser + "mbox" can be
# split by argparse's call-style formatting.
if ! perl -0777 -ne 'exit 1 unless /add_parser\s*\(\s*\n?\s*"mbox"/s' "$SCRIPT_DIR/src/cli.py"; then
    echo "FAIL: vendor/cm021/src/cli.py does not register the 'mbox' subcommand" >&2
    echo "      The hourly LaunchAgent's tick.sh expects this call shape." >&2
    exit 1
fi
echo "subcommand check: src/cli.py registers the mbox subcommand"

# Optional import-time check. Mirrors how install.sh's hydrate_email
# step invokes the CLI (pip-installed into the email-ingest venv).
PY_IMPORT_CHECK=$(/usr/bin/env python3 - "$SCRIPT_DIR" <<'PY'
import sys, importlib
sys.path.insert(0, sys.argv[1])
try:
    import src
    import src.cli
    print("OK")
except ImportError as exc:
    msg = str(exc)
    # Differentiate "vendoring broke" from "external dep missing
    # in this CI environment". Vendoring breakage names src or
    # src.cli; external-dep missing names httpx / bs4 / etc.
    for vendored in ("src.cli", "src.filters", "src.parsers"):
        if f"No module named '{vendored}'" in msg:
            print(f"FAIL: {msg}")
            sys.exit(2)
    print(f"INCONCLUSIVE: external dep missing ({msg})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: src + src.cli import cleanly"
        ;;
    INCONCLUSIVE:*)
        echo "import check: skipped (${PY_IMPORT_CHECK#INCONCLUSIVE: })"
        # Not a failure -- CI without the runtime deps still gets
        # the structural + pyproject + subcommand checks above.
        ;;
    FAIL:*)
        echo "$PY_IMPORT_CHECK" >&2
        exit 1
        ;;
    *)
        echo "import check: unexpected output: $PY_IMPORT_CHECK" >&2
        exit 1
        ;;
esac

echo "vendor/cm021 import regression: PASS"
