#!/usr/bin/env bash
# check-rule-09-strings.sh
#
# Rule 0.9 lint guard: customer-facing strings must come from per-repo
# string catalogues, not from inline literals in code. Locked 2026-05-19
# in HR015 memory feedback_customer_strings_extractable_from_day_one.md
# and PRODUCTISATION_CHECKLIST.md.
#
# Why: v1.0 ships English-only. v1.2 must be a translation effort, not
# a refactor effort. If contributors land inline literals during a hot
# fix the regression compounds silently until the v1.2 lift bill is huge.
#
# How: scans NEWLY-ADDED lines in staged or PR-diff files only. Each
# repo gets the same script; it auto-detects which repo it is by the
# presence of catalogue files and applies the matching set of checks.
#
#   Repo type           Catalogue marker                       Code path
#   -----------------   ------------------------------------   ------------------
#   HR015               ostler_security/wizard_copy.py         ostler_security/setup_wizard.py
#   CM044               compiler/locale.yaml                   compiler/pages/*.py + compiler/lint.py
#   CM050               appcast-server/src/templates/copy.ts   appcast-server/src/templates/{welcome-email,reset-email,pages}.ts
#   CM031               CM031/Sources/Resources/Localizable.xcstrings  CM031/Sources/Views/**.swift
#   CM051               gui/OstlerInstaller/Resources/ViewCopy.json    gui/OstlerInstaller/Views/**.swift
#
# Bypass: append `i18n-exempt` (case-sensitive, language-appropriate
# comment marker is fine -- the scan just searches for the substring
# on the same line) for genuine non-customer-facing literals (debug
# log lines, internal NSLog, test fixtures, console output users
# never see). Use sparingly.
#
# Modes:
#   pre-commit (default)  scan staged diff against HEAD
#   ci                    scan diff between $BASE_SHA...HEAD (PR Action use)
#
# Exit codes:
#   0  clean
#   1  one or more violations
#   2  invocation error
#
# Regex-based, not full AST. False-positive-tolerant by design --
# blocking work is more expensive than catching the next regression.

set -u

MODE="${1:-pre-commit}"
BASE_SHA="${2:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-rule-09-strings: not in a git repo" >&2
    exit 2
}

# Run all subsequent git operations relative to the repo root so the
# script behaves identically whether invoked by git itself (which sets
# cwd to the working-tree root) or by a developer from a subdirectory
# or from a sibling repo.
cd "$REPO_ROOT" || exit 2

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

# ── Repo-type auto-detect ────────────────────────────────────────────────
# A repo can in principle match more than one type (it doesn't here, but
# the structure permits future colocation). Each block runs independently.

HAS_HR015=0
HAS_CM044=0
HAS_CM050=0
HAS_CM031=0
HAS_CM051=0

[ -f "$REPO_ROOT/ostler_security/wizard_copy.py" ] && HAS_HR015=1
[ -f "$REPO_ROOT/compiler/locale.yaml" ] && HAS_CM044=1
[ -f "$REPO_ROOT/appcast-server/src/templates/copy.ts" ] && HAS_CM050=1
[ -f "$REPO_ROOT/CM031/Sources/Resources/Localizable.xcstrings" ] && HAS_CM031=1
[ -f "$REPO_ROOT/gui/OstlerInstaller/Resources/ViewCopy.json" ] && HAS_CM051=1

if [ "$HAS_HR015" = 0 ] && [ "$HAS_CM044" = 0 ] && [ "$HAS_CM050" = 0 ] && \
   [ "$HAS_CM031" = 0 ] && [ "$HAS_CM051" = 0 ]; then
    echo "check-rule-09-strings: no catalogue markers found -- nothing to check"
    exit 0
fi

# ── Collect the list of "newly added" lines per file ────────────────────
# We want a temp file per source file containing only the line numbers
# and content of lines being ADDED in this commit / PR. The hook only
# blocks based on what is changing now, so existing untouched literals
# don't break the build.

WORKDIR="$(mktemp -d -t rule09-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$MODE" = "ci" ]; then
    if [ -z "$BASE_SHA" ]; then
        echo "check-rule-09-strings: ci mode requires BASE_SHA as 2nd arg" >&2
        exit 2
    fi
    CHANGED_FILES="$(git diff --name-only --diff-filter=ACMR "$BASE_SHA"...HEAD)"
else
    CHANGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR)"
fi

[ -z "$CHANGED_FILES" ] && {
    echo "check-rule-09-strings: clean (no changed files)"
    exit 0
}

# Returns the added-lines diff for one file (just the `+`-prefixed
# content lines, no `+++` headers, with a synthetic line-number prefix
# so the user can locate the violation).
added_lines_for() {
    local f="$1"
    if [ "$MODE" = "ci" ]; then
        git diff --unified=0 "$BASE_SHA"...HEAD -- "$f" 2>/dev/null
    else
        git diff --cached --unified=0 -- "$f" 2>/dev/null
    fi | awk '
        /^\+\+\+ / { next }
        /^@@ / {
            # Parse: @@ -a,b +c,d @@
            match($0, /\+[0-9]+/);
            lineno = substr($0, RSTART+1, RLENGTH-1) + 0;
            next
        }
        /^\+/ {
            sub(/^\+/, "", $0);
            print lineno ":" $0;
            lineno++;
            next
        }
        /^ / { lineno++; next }
        /^-/ { next }
    '
}

# All matches reported by individual checks land here; we print + exit
# at the end if anything is non-empty.
ALL_HITS=""

record_hit() {
    local label="$1"
    local file="$2"
    local body="$3"
    [ -z "$body" ] && return 0
    ALL_HITS="$ALL_HITS

  ${label} -- ${file}:
$(echo "$body" | sed 's/^/    /')"
}

# Drop lines that contain the bypass marker.
strip_exempt() {
    grep -v 'i18n-exempt' || true
}

# ── HR015: setup_wizard.py inline literals ───────────────────────────────
# Detect: _info("..."), _warn("..."), _h("..."), _ok("...") where the
# first arg is a literal string (starts with " or ').
# Allow: _info("", out=...), _info(_copy.X), _info(f"..."), and
# _info(text_var, ...).
if [ "$HAS_HR015" = 1 ]; then
    SETUP_FILES=$(echo "$CHANGED_FILES" | grep -E '^ostler_security/setup_wizard\.py$' || true)
    for f in $SETUP_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E '_(info|warn|h|ok)\(["'"'"'][^"'"'"']' \
            | grep -vE '_(info|warn|h|ok)\(["'"'"'][[:space:]]*["'"'"']' \
            | strip_exempt \
            | head -5 || true)
        record_hit "HR015 inline wizard literal" "$f" "$hits"
    done
fi

# ── CM044: compiler/pages/*.py + compiler/lint.py inline sentence appends ──
# Detect: lines.append("Sentence...") -- starts with capital, contains
# a lowercase character (so we don't flag class names) and a space.
# Skip: HTML/markdown fragments (start with `<` or `|` or `-` or `#`),
# pure markup like `lines.append("</p>")`.
if [ "$HAS_CM044" = 1 ]; then
    PAGE_FILES=$(echo "$CHANGED_FILES" | grep -E '^compiler/(pages/[^/]+\.py|lint\.py)$' || true)
    for f in $PAGE_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        # Only enforce if the file already imports _locale (=  has been
        # lifted). New files not yet in the catalogue scope shouldn't
        # block a contributor; flag in PR review instead.
        if ! grep -qE 'from\s+\.\.?\s+import.*locale|import\s+.*locale' "$REPO_ROOT/$f" 2>/dev/null \
           && ! grep -q '_locale\.' "$REPO_ROOT/$f" 2>/dev/null; then
            continue
        fi
        hits=$(added_lines_for "$f" \
            | grep -E 'lines\.append\(["'"'"'][A-Z][^"'"'"']*[a-z][^"'"'"']* [^"'"'"']*["'"'"']\)' \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM044 inline page sentence" "$f" "$hits"
    done
fi

# ── CM050: appcast-server/src/templates/*.ts inline sentences ────────────
# Detect: sentence-shaped literals outside copy.ts. Sentence-shaped =
# starts with capital, contains a space and a lowercase letter, runs
# at least ~6 chars. We deliberately allow short tokens like "Mac" or
# "iOS" because they're brand names not catalogue keys.
# Skip: copy.ts itself, URLs, content-type / header strings, code
# comments (lines that match before the literal a `//` or `/*`).
if [ "$HAS_CM050" = 1 ]; then
    TS_FILES=$(echo "$CHANGED_FILES" | grep -E '^appcast-server/src/templates/(welcome-email|reset-email|pages)\.ts$' || true)
    for f in $TS_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        # We tolerate single-word capitalised tokens. The regex demands
        # at least one space + at least one lowercase letter after it,
        # so brand tokens, URLs and content-types skim under.
        hits=$(added_lines_for "$f" \
            | grep -E '["'"'"'`][A-Z][a-z]+[^"'"'"'`]*[ ][a-z]' \
            | grep -vE '://' \
            | grep -vE '^\s*[0-9]+:\s*//\b' \
            | grep -vE '^\s*[0-9]+:\s*\*' \
            | grep -vE '^\s*[0-9]+:\s*import\b' \
            | grep -vE '^\s*[0-9]+:\s*export\b' \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM050 inline template sentence (move to copy.ts)" "$f" "$hits"
    done
fi

# ── CM031: Sources/Views/**.swift sentence literals ──────────────────────
# Detect: Text("Sentence ..."), Button("Sentence ..."), Label("Sentence ...").
# Allow: dotted-key shorthand (Text("about.title")) because LocalizedStringKey
# auto-resolves; interpolated runtime values (Text(variable)) because the
# regex matches only quote-string-quote literals.
# Heuristic: literal contains a space AND a lowercase letter. Dotted keys
# don't contain spaces.
if [ "$HAS_CM031" = 1 ]; then
    SWIFT_FILES=$(echo "$CHANGED_FILES" | grep -E '^CM031/Sources/Views/.*\.swift$' || true)
    for f in $SWIFT_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        # Only enforce if file already uses String(localized:) or a
        # dotted-key Text("foo.bar") -- a fully unconverted file isn't
        # in scope.
        if ! grep -qE 'String\(localized:|Text\("[a-z]+\.[a-z]' "$REPO_ROOT/$f" 2>/dev/null; then
            continue
        fi
        hits=$(added_lines_for "$f" \
            | grep -E '(Text|Button|Label)\("[A-Z][^"]*[ ][^"]*[a-z][^"]*"\)' \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM031 inline view sentence (use String(localized:) or dotted key)" "$f" "$hits"
    done
fi

# ── CM051 GUI: Views/**.swift sentence literals ──────────────────────────
# Detect: Text("..."), Button("..."), Label("...") with a sentence
# literal. Must use ViewCopy.shared.string(for: "key.subkey").
if [ "$HAS_CM051" = 1 ]; then
    GUI_FILES=$(echo "$CHANGED_FILES" | grep -E '^gui/OstlerInstaller/Views/.*\.swift$' || true)
    for f in $GUI_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E '(Text|Button|Label)\("[A-Z][^"]*[ ][^"]*[a-z][^"]*"\)' \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM051 inline view sentence (use ViewCopy.shared.string(for:))" "$f" "$hits"
    done
fi

# ── Report ───────────────────────────────────────────────────────────────
if [ -n "$ALL_HITS" ]; then
    {
        echo "${RED}BLOCKED:${RESET} Rule 0.9 violation -- customer-facing strings must come from the per-repo catalogue, not inline literals."
        echo "$ALL_HITS"
        echo ""
        echo "Catalogues (per repo):"
        echo "  HR015     -> ostler_security/wizard_copy.py"
        echo "  CM044     -> compiler/locale.yaml + compiler/locale.py helpers"
        echo "  CM050     -> appcast-server/src/templates/copy.ts"
        echo "  CM031     -> CM031/Sources/Resources/Localizable.xcstrings"
        echo "  CM051 GUI -> gui/OstlerInstaller/Resources/ViewCopy.json"
        echo ""
        echo "${YELLOW}Bypass${RESET} (debug logs / non-customer literals): append ${YELLOW}i18n-exempt${RESET} in a comment on the same line."
        echo ""
        echo "Why: v1.0 is English-only but v1.2 translation must be a catalogue swap, not a refactor."
        echo "See PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19)."
    } >&2
    exit 1
fi

echo "${GREEN}check-rule-09-strings: clean.${RESET}"
exit 0
