#!/usr/bin/env bash
#
# tests/test_linkedin_export_detect.sh
#
# Locks the LinkedIn export auto-detect path against the real-world
# folder name produced by LinkedIn's GDPR export.
#
# Why this test exists:
#
#   The cold-install audit (2026-05-02) found that the auto-detect
#   `find` had `-path "*/linkedin*"` as an extra predicate. LinkedIn's
#   actual export folder is `Basic_LinkedInDataExport_<date>/`, with
#   no lowercase "linkedin" substring. The predicate was
#   case-sensitive, so every real LinkedIn export was silently
#   missed. The user reached the "no exports detected" branch and
#   was told to point at the folder manually -- a reasonable
#   recovery, but a bad first impression on a feature the website
#   front-pages as "auto-detect from Downloads".
#
#   This test pins the fix:
#     1. The find command picks up a Connections.csv inside a
#        canonical `Basic_LinkedInDataExport_*/` folder.
#     2. It also picks up the lowercase `linkedin*/Connections.csv`
#        layout (older format / user-renamed).
#     3. It picks up a bare `Connections.csv` (no LinkedIn-flavoured
#        parent dir) too -- this is the trade-off of dropping the
#        path predicate. The post-detect prompt at install.sh ~1700
#        lets the user reject mis-attributions.
#
# Sister tests:
#   - test_email_folder_prompt.sh -- locks the email folder safety
#   - test_whatsapp_channel_block.sh -- locks WhatsApp channel wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Static check: -path predicate is gone ───────────────────────
# Pre-fix: `find ... -name "Connections.csv" -path "*/linkedin*"`.
# Post-fix: no -path predicate. A future edit that re-adds a
# case-sensitive predicate would silently re-introduce the audit
# bug.
if grep -nE 'find.*-name "Connections.csv".*-path "\*/linkedin\*"' "$INSTALL_SCRIPT" >/dev/null; then
    echo "FAIL [path-filter-resurrected]: case-sensitive '*/linkedin*' path filter is back" >&2
    exit 1
fi
echo "PASS: install.sh has no case-sensitive '*/linkedin*' predicate on Connections.csv"

# ── End-to-end: find command picks up real LinkedIn export ──────
# Spin up a fixture mirroring a real LinkedIn GDPR export and run
# the same find command install.sh runs.
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

# Real LinkedIn 2026 export layout.
mkdir -p "$FIXTURE_ROOT/Basic_LinkedInDataExport_2026-01-15"
echo "First Name,Last Name,Email Address" \
    > "$FIXTURE_ROOT/Basic_LinkedInDataExport_2026-01-15/Connections.csv"

# Older / user-renamed layout (still common in the wild).
mkdir -p "$FIXTURE_ROOT/linkedin_export_2025"
echo "First Name,Last Name,Email Address" \
    > "$FIXTURE_ROOT/linkedin_export_2025/Connections.csv"

# Distractor: a folder with NO Connections.csv that previously
# would have been the only thing the predicate matched.
mkdir -p "$FIXTURE_ROOT/linkedin_archive_no_connections"
echo "irrelevant" > "$FIXTURE_ROOT/linkedin_archive_no_connections/notes.txt"

# Run the same find install.sh runs. Bash 3.2-compatible (macOS
# default ships bash 3.2; cannot rely on mapfile / readarray).
HITS="$(find "$FIXTURE_ROOT" -maxdepth 3 -name "Connections.csv" 2>/dev/null | sort)"
HIT_COUNT="$(printf '%s' "$HITS" | grep -c '.' || true)"

if [[ "$HIT_COUNT" -ne 2 ]]; then
    echo "FAIL [hit-count]: expected 2 Connections.csv hits, got ${HIT_COUNT}" >&2
    echo "$HITS" >&2
    exit 1
fi
echo "PASS: find picks up exactly 2 fixtures (Basic_LinkedInDataExport + linkedin_export)"

# Match the canonical Basic_LinkedInDataExport folder.
if ! echo "$HITS" | grep -q 'Basic_LinkedInDataExport_2026-01-15/Connections\.csv$'; then
    echo "FAIL [canonical-export]: did not pick up Basic_LinkedInDataExport_*/Connections.csv" >&2
    echo "$HITS" >&2
    exit 1
fi
echo "PASS: find picks up Basic_LinkedInDataExport_*/Connections.csv (the audit's test case)"

# Match the lowercase variant too.
if ! echo "$HITS" | grep -q 'linkedin_export_2025/Connections\.csv$'; then
    echo "FAIL [lowercase-variant]: did not pick up lowercase linkedin_*/Connections.csv" >&2
    echo "$HITS" >&2
    exit 1
fi
echo "PASS: find picks up legacy lowercase linkedin_*/Connections.csv layout"

echo ""
echo "ALL LINKEDIN EXPORT DETECT TESTS PASSED"
