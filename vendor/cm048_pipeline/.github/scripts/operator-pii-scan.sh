#!/usr/bin/env bash
# operator-pii-scan.sh
#
# Cross-repo scanner for operator real PII + flagged brand references.
# Reads the canonical inventory at $HOME/.ostler-operator-pii.toml and
# greps every file under the target path against every value, computing
# common format variants automatically (phone numbers with/without
# spaces / hyphens / country codes).
#
# Usage:
#   operator-pii-scan.sh                 # scan current directory
#   operator-pii-scan.sh <path>          # scan <path>
#   operator-pii-scan.sh --strict <path> # include test dirs (default
#                                          excludes none – strict is the
#                                          current default; reserved for
#                                          future mode-split)
#
# Exit codes:
#   0 – no operator PII / flagged brand references found
#   1 – at least one hit (printed to stdout, file:line:col: pattern)
#   2 – inventory file missing / unreadable
#   3 – ripgrep not installed
#
# Designed to be wired as a pre-commit hook + CI step in every
# customer-shipping repo.

set -u

TARGET="${1:-.}"
INVENTORY="${HOME}/.ostler-operator-pii.toml"

if [ ! -r "$INVENTORY" ]; then
    echo "operator-pii-scan: inventory not readable at $INVENTORY" >&2
    exit 2
fi

if ! rg --version >/dev/null 2>&1; then
    echo "operator-pii-scan: ripgrep (rg) not available" >&2
    exit 3
fi

# Crude TOML parsing – picks out the values we need. The inventory is
# under operator control so the format is stable.
extract_array() {
    # Reads a TOML array of strings under [section] for key.
    # Args: section, key. Output: one entry per line.
    local section="$1" key="$2"
    awk -v section="[$section]" -v key="$key" '
        $0 == section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\\[" { in_array = 1; next }
        in_array && /^\]/ { in_array = 0 }
        in_array {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|",?$|,$/, "")
            if (length > 0 && substr($0, 1, 1) != "#") print
        }
    ' "$INVENTORY"
}

extract_scalar() {
    # Reads a single-line "key = \"value\"" string. Args: section, key.
    local section="$1" key="$2"
    awk -v section="[$section]" -v key="$key" '
        $0 == section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*"/, "")
            sub(/"[[:space:]]*$/, "")
            print
            exit
        }
    ' "$INVENTORY"
}

HK_DIGITS="$(extract_scalar phone hk_mobile_digits)"
UK_DIGITS="$(extract_scalar phone uk_mobile_digits)"
EMAIL_DOMAINS="$(extract_array email domains | paste -sd '|' -)"
HOME_USERNAMES="$(extract_array home_dir usernames | paste -sd '|' -)"
BRANDS="$(extract_array brands_to_strip names | paste -sd '|' -)"
FAMILY="$(extract_array family_names names | paste -sd '|' -)"
ACTIVITIES="$(extract_array activities names | paste -sd '|' -)"
USERNAME_ANYWHERE="$(extract_array username_anywhere names | paste -sd '|' -)"
SKIP_GLOBS="$(extract_array allow_paths skip)"

# Build the phone-variant regex. HK = 8 digits "ABCD EFGH"; UK = 12 digits
# starting with "44".
build_hk_pattern() {
    local d="$1"
    [ -z "$d" ] || [ "${#d}" -ne 8 ] && { echo ""; return; }
    local p1="${d:0:4}" p2="${d:4:4}"
    # Variants: "ABCDEFGH", "ABCD EFGH", "ABCD-EFGH", "+852 ABCD EFGH",
    # "+852ABCDEFGH", "+852-ABCD-EFGH". Country code optional.
    echo "(?:(?:\\+?852[[:space:]\\-]*)?${p1}[[:space:]\\-]?${p2})|(?:${d})"
}

build_uk_pattern() {
    local d="$1"
    [ -z "$d" ] || [ "${#d}" -ne 12 ] && { echo ""; return; }
    local cc="${d:0:2}" rest="${d:2}"
    local part1="${rest:0:4}" part2="${rest:4:6}"
    # Variants (using the OFCOM drama-range placeholder for documentation):
    # "447700900000", "+447700900000", "+44 7700 900000",
    # "+44 7700-900000", "07700900000", "07700 900000".
    echo "(?:\\+?${cc}[[:space:]\\-]*${part1}[[:space:]\\-]*${part2})|(?:0${part1}[[:space:]\\-]*${part2})|(?:${d})"
}

HK_PATTERN="$(build_hk_pattern "$HK_DIGITS")"
UK_PATTERN="$(build_uk_pattern "$UK_DIGITS")"

# Compose the master pattern. Each alternative is grouped + the group is
# named (via comments) so the human reader of the output can tell which
# value matched.
PATTERNS=()
[ -n "$HK_PATTERN" ] && PATTERNS+=("$HK_PATTERN")
[ -n "$UK_PATTERN" ] && PATTERNS+=("$UK_PATTERN")
[ -n "$EMAIL_DOMAINS" ] && PATTERNS+=("@(${EMAIL_DOMAINS//./\\.})")
if [ -n "$HOME_USERNAMES" ]; then
    PATTERNS+=("/Users/(${HOME_USERNAMES})/")
    PATTERNS+=("/home/(${HOME_USERNAMES})/")
fi
[ -n "$BRANDS" ] && PATTERNS+=("(?i)\\b(${BRANDS// /\\s+})\\b")
[ -n "$FAMILY" ] && PATTERNS+=("\\b(${FAMILY// /\\s+})\\b")
[ -n "$ACTIVITIES" ] && PATTERNS+=("(?i)\\b(${ACTIVITIES// /\\s+})\\b")
[ -n "$USERNAME_ANYWHERE" ] && PATTERNS+=("\\b(${USERNAME_ANYWHERE})@")

if [ ${#PATTERNS[@]} -eq 0 ]; then
    echo "operator-pii-scan: inventory empty – nothing to scan against" >&2
    exit 2
fi

MASTER="$(printf '%s\n' "${PATTERNS[@]}" | paste -sd '|' -)"

# Build the rg glob-exclude args from the skip list.
RG_ARGS=()
while IFS= read -r glob; do
    [ -n "$glob" ] && RG_ARGS+=(--glob "!$glob")
done <<< "$SKIP_GLOBS"

# Run the scan. PCRE2 needed for non-capturing groups + look-around.
rg --pcre2 --no-heading -n -i --hidden \
    "${RG_ARGS[@]}" \
    --type-add 'src:*.{py,swift,rs,ts,js,mjs,yaml,yml,toml,json,sh,plist,conf,html,css,md,txt,xml,xcconfig}' \
    -t src \
    "$MASTER" \
    "$TARGET"

# rg exits 0 if matches found, 1 if no matches. Invert for our contract
# (0 = clean, 1 = hits found).
case $? in
    0) exit 1 ;;
    1) exit 0 ;;
    *) exit 4 ;;
esac
