#!/usr/bin/env bash
# check-assistant-name-hardcoded.sh
#
# Hardcoded-assistant-name lint guard. Customer-rendered surfaces must
# never contain the literal word "Marvin" -- the assistant's name is
# chosen by the customer at install time (default "Marvin", but Alison
# chose "Samantha", and v1.2 multi-instance will multiply this).
#
# Locked 2026-05-19 after the THIRD scrub attempt for the same class
# of leak (#141 / #233 / today). Existing Rule 0.9 catches inline
# customer literals in code; this guard catches the brand-noun
# specifically, including INSIDE the catalogues themselves.
#
# Auto-detects repo type by the same catalogue markers Rule 0.9 uses
# (no overlap of checks, complementary coverage).
#
#   Repo type           Files scanned for hardcoded "Marvin"
#   -----------------   ---------------------------------------------
#   HR015               doctor/agent/*_copy.py
#                       ostler_security/wizard_copy.py
#                       doctor/templates/*.md  (if present)
#   CM044               compiler/locale.yaml
#                       compiler/locale.py
#                       compiler/locale.*.yaml
#                       compiler/templates/*.md
#                       compiler/pages/*.py  (literal "Marvin" only,
#                                             not identifiers)
#   CM050               appcast-server/src/templates/*.ts
#                       appcast-server/src/templates/copy.ts
#   CM031               CM031/Sources/Resources/Localizable.xcstrings
#                       CM031/Sources/Resources/InfoPlist.xcstrings
#                       CM031/Sources/Views/**.swift
#                       (Text/Button/Label/.alert arguments only)
#   CM051               install.sh.strings.en-GB.sh
#                       install.sh (echo / printf customer lines only)
#                       gui/OstlerInstaller/Resources/ViewCopy.json
#                       gui/OstlerInstaller/Views/**.swift
#
# Bypass: append `assistant-name-exempt` on the same line for genuine
# non-customer-facing literals (test fixtures explicitly testing this
# class of leak, internal audit references, comments quoting the term).
#
# Modes:
#   pre-commit (default)  scan staged diff against HEAD
#   ci                    scan diff between $BASE_SHA...HEAD
#   audit                 scan the entire working tree (used by CI on
#                         push-to-main to catch regressions that
#                         slipped past the diff-only scan)
#
# Exit codes:
#   0  clean
#   1  one or more violations
#   2  invocation error

set -u

MODE="${1:-pre-commit}"
BASE_SHA="${2:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-assistant-name-hardcoded: not in a git repo" >&2
    exit 2
}
cd "$REPO_ROOT" || exit 2

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

# ── Repo-type auto-detect ────────────────────────────────────────────────
HAS_HR015=0
HAS_CM044=0
HAS_CM050=0
HAS_CM031=0
HAS_CM051=0

[ -f "$REPO_ROOT/ostler_security/wizard_copy.py" ] && HAS_HR015=1
[ -f "$REPO_ROOT/compiler/locale.yaml" ] && HAS_CM044=1
[ -d "$REPO_ROOT/appcast-server/src/templates" ] && HAS_CM050=1
[ -f "$REPO_ROOT/CM031/Sources/Resources/Localizable.xcstrings" ] && HAS_CM031=1
[ -f "$REPO_ROOT/install.sh.strings.en-GB.sh" ] && HAS_CM051=1

if [ "$HAS_HR015" = 0 ] && [ "$HAS_CM044" = 0 ] && [ "$HAS_CM050" = 0 ] && \
   [ "$HAS_CM031" = 0 ] && [ "$HAS_CM051" = 0 ]; then
    echo "check-assistant-name-hardcoded: no catalogue markers found -- nothing to check"
    exit 0
fi

# ── Compute the file list to scan ────────────────────────────────────────
if [ "$MODE" = "ci" ]; then
    if [ -z "$BASE_SHA" ]; then
        echo "check-assistant-name-hardcoded: ci mode requires BASE_SHA as 2nd arg" >&2
        exit 2
    fi
    CHANGED_FILES="$(git diff --name-only --diff-filter=ACMR "$BASE_SHA"...HEAD)"
elif [ "$MODE" = "audit" ]; then
    # Audit mode: scan every tracked file (filtered per-repo below).
    CHANGED_FILES="$(git ls-files)"
else
    CHANGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR)"
fi

[ -z "$CHANGED_FILES" ] && {
    echo "check-assistant-name-hardcoded: clean (no changed files)"
    exit 0
}

# ── added_lines_for: return added-line content with line numbers ─────────
# In audit mode this just enumerates EVERY line in the file (no diff
# context). In pre-commit / ci modes it returns only newly-added lines.
added_lines_for() {
    local f="$1"
    if [ "$MODE" = "audit" ]; then
        awk '{ print NR ":" $0 }' "$REPO_ROOT/$f" 2>/dev/null
        return
    fi
    local range_arg
    if [ "$MODE" = "ci" ]; then
        range_arg=("$BASE_SHA"...HEAD)
        git diff --unified=0 "${range_arg[@]}" -- "$f" 2>/dev/null
    else
        git diff --cached --unified=0 -- "$f" 2>/dev/null
    fi | awk '
        /^\+\+\+ / { next }
        /^@@ / {
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

# ── strip_exempt + strip_comments helpers ────────────────────────────────
# Bypass: explicit per-line `assistant-name-exempt`.
strip_exempt() {
    grep -v 'assistant-name-exempt' || true
}

# Comment strippers. Each filters out lines whose content (after the
# "LINENO:" prefix) is a comment in the relevant language. We strip
# comments after the colon -- the prefix is "LINENO:" so we look at $2+.
strip_python_bash_comments() {
    awk -F: '{
        # Strip everything after the first colon: that is the content.
        idx = index($0, ":");
        line = substr($0, idx+1);
        # ltrim
        sub(/^[ \t]+/, "", line);
        if (line ~ /^#/) next;
        print $0;
    }'
}

strip_cstyle_comments() {
    awk -F: '{
        idx = index($0, ":");
        line = substr($0, idx+1);
        sub(/^[ \t]+/, "", line);
        if (line ~ /^\/\//) next;
        if (line ~ /^\/\*/) next;
        if (line ~ /^\*/) next;
        print $0;
    }'
}

strip_yaml_comments() {
    # YAML uses `#` for comments same as Python. The string "Marvin"
    # inside a YAML quoted value is NOT a comment even if preceded by
    # `#` in another field on the same line, so we only filter lines
    # that START with a comment.
    strip_python_bash_comments
}

# ── All match collector ──────────────────────────────────────────────────
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

# ── Marvin pattern ───────────────────────────────────────────────────────
# Word-boundary match. Case-sensitive by design -- "marvin" lower-case
# as a config-default value (e.g. PWG_AI_CHAT_WINGS="marvin,unknown")
# is a code identifier, not a customer-rendered string. The display
# string would be "Marvin" or "Your assistant".
MARVIN_PATTERN='\bMarvin\b'

# ── HR015 customer-rendered surfaces ─────────────────────────────────────
if [ "$HAS_HR015" = 1 ]; then
    HR015_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^(doctor/agent/.*_copy\.py|ostler_security/wizard_copy\.py|doctor/templates/.*\.md)$' \
        || true)
    for f in $HR015_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_python_bash_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "HR015 hardcoded Marvin in customer copy" "$f" "$hits"
    done
fi

# ── CM044 customer-rendered surfaces ─────────────────────────────────────
if [ "$HAS_CM044" = 1 ]; then
    # Catalogue files: any literal "Marvin" inside a value is a bug.
    CAT_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^compiler/(locale.*\.yaml|locale\.py)$' \
        || true)
    for f in $CAT_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_python_bash_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM044 hardcoded Marvin in locale catalogue" "$f" "$hits"
    done
    # Wiki templates: rendered into customer pages as-is.
    TPL_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^compiler/templates/.*\.md$' \
        || true)
    for f in $TPL_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM044 hardcoded Marvin in wiki template" "$f" "$hits"
    done
    # Page generators: only literal-string emission of "Marvin", not
    # the existing _render_marvin_facts_section identifier.
    PAGE_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^compiler/(pages/.*\.py|lint\.py)$' \
        || true)
    for f in $PAGE_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "\"[^\"]*${MARVIN_PATTERN}[^\"]*\"|'[^']*${MARVIN_PATTERN}[^']*'" \
            | strip_python_bash_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM044 hardcoded Marvin in page generator literal" "$f" "$hits"
    done
fi

# ── CM050 customer-rendered surfaces ─────────────────────────────────────
if [ "$HAS_CM050" = 1 ]; then
    TS_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^appcast-server/src/templates/.*\.(ts|tsx|html)$' \
        || true)
    for f in $TS_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_cstyle_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM050 hardcoded Marvin in email/page template" "$f" "$hits"
    done
fi

# ── CM031 customer-rendered surfaces ─────────────────────────────────────
if [ "$HAS_CM031" = 1 ]; then
    # xcstrings catalogues: any "Marvin" in a value position is a bug.
    XC_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^CM031/Sources/Resources/.*\.xcstrings$' \
        || true)
    for f in $XC_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM031 hardcoded Marvin in xcstrings catalogue" "$f" "$hits"
    done
    # Swift views: Text("Marvin..."), Button("..."), Label("...").
    SWIFT_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^CM031/Sources/Views/.*\.swift$' \
        || true)
    for f in $SWIFT_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "(Text|Button|Label)\\(\"[^\"]*${MARVIN_PATTERN}[^\"]*\"" \
            | strip_cstyle_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM031 hardcoded Marvin in Swift view literal" "$f" "$hits"
    done
fi

# ── CM051 customer-rendered surfaces ─────────────────────────────────────
if [ "$HAS_CM051" = 1 ]; then
    # Strings catalogue (bash MSG_* assignments). Any literal "Marvin"
    # in a MSG_*="..." value is a bug.
    SHELL_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^install\.sh\.strings\.en-GB\.sh$' \
        || true)
    for f in $SHELL_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_python_bash_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM051 hardcoded Marvin in install strings" "$f" "$hits"
    done
    # install.sh customer-rendered echo / printf lines. Match only echo /
    # printf / ok / warn / info / progress lines containing literal
    # "Marvin" -- skip variable expansions like "${ASSISTANT_NAME}".
    INSTALL_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^install\.sh$' \
        || true)
    for f in $INSTALL_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "(echo|printf|ok|warn|info|progress)\\b.*${MARVIN_PATTERN}" \
            | strip_python_bash_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM051 hardcoded Marvin in install.sh customer echo" "$f" "$hits"
    done
    # GUI installer copy + views.
    JSON_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^gui/OstlerInstaller/Resources/ViewCopy\.json$' \
        || true)
    for f in $JSON_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "$MARVIN_PATTERN" \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM051 hardcoded Marvin in GUI ViewCopy.json" "$f" "$hits"
    done
    GUI_SWIFT_FILES=$(echo "$CHANGED_FILES" \
        | grep -E '^gui/OstlerInstaller/Views/.*\.swift$' \
        || true)
    for f in $GUI_SWIFT_FILES; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits=$(added_lines_for "$f" \
            | grep -E "(Text|Button|Label)\\(\"[^\"]*${MARVIN_PATTERN}[^\"]*\"" \
            | strip_cstyle_comments \
            | strip_exempt \
            | head -5 || true)
        record_hit "CM051 hardcoded Marvin in GUI Swift view literal" "$f" "$hits"
    done
fi

# ── Report ───────────────────────────────────────────────────────────────
if [ -n "$ALL_HITS" ]; then
    {
        echo "${RED}BLOCKED:${RESET} hardcoded \"Marvin\" in customer-rendered surface."
        echo "$ALL_HITS"
        echo ""
        echo "The customer chooses the assistant's name at install time (default \"Marvin\","
        echo "but Alison chose \"Samantha\"). Customer-rendered surfaces must read the name"
        echo "from settings or fall back to \"your assistant\" -- never hardcode \"Marvin\"."
        echo ""
        echo "Fix paths:"
        echo "  Catalogue values     -> change \"Marvin\" to \"your assistant\""
        echo "  Template variables   -> use {{ assistant_name }} where supported"
        echo "  Swift views          -> read OnboardingSettings.assistantName + String(format:)"
        echo ""
        echo "${YELLOW}Bypass${RESET} (test fixtures explicitly testing this leak, internal audit refs):"
        echo "  append ${YELLOW}assistant-name-exempt${RESET} in a comment on the same line."
        echo ""
        echo "Locked 2026-05-19. Third scrub attempt after #141 + #233."
    } >&2
    exit 1
fi

echo "${GREEN}check-assistant-name-hardcoded: clean.${RESET}"
exit 0
