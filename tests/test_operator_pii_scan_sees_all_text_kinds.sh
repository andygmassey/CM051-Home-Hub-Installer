#!/usr/bin/env bash
# test_operator_pii_scan_sees_all_text_kinds.sh
#
# THE OPERATOR-PII SCANNER MUST SEE EVERY TEXT KIND THAT CAN CARRY A NAME,
# AND MUST STATE HOW MANY FILES IT ACTUALLY EXAMINED.
#
# Measured on the CM051 tree: 1514 tracked files, 1227 visible to the original
# `-t src` extension list, so 287 TEXT files were invisible BY CONSTRUCTION.
# The blind kinds were .tsv 46, .env 36, .patch 17, .example 5, .ttl 4,
# .gitignore 3, .jsonl 2, plus extension-less files. .tsv is the one that
# mattered: .pii-name-registry.tsv is a .tsv, so the PII name registry was
# invisible to the PII scanner.
#
# Demonstrated against the pre-fix scanner, same synthetic inventory, one
# variable (the file kind):
#
#     .tsv carrying a denylisted term  ->  pre-fix exit 0 CLEAN,  fixed exit 1 DIRTY
#     .py  carrying the same term      ->  pre-fix exit 1 DIRTY,  fixed exit 1 DIRTY
#
# The .py arm is the control: it fires in BOTH, so the difference is the type
# filter and not a broken pattern.
#
# SECOND DEFECT PINNED HERE. rg returns 1 for "no matches" whether it searched
# 20,000 files or ZERO, and the scanner maps rc=1 to exit 0 CLEAN. The caller's
# count is not a substitute: operator-pii-scan.yml counts STAGED files, every
# changed tracked file regardless of type, then prints "clean (N files scanned)".
# For a PR touching only invisible kinds that N is non-zero while the number
# actually examined is zero, so the line asserts a scan that did not happen.
# The scanner must therefore print its OWN examined count.
#
# NO REAL INVENTORY IS READ OR WRITTEN. The scanner reads $HOME/.ostler-operator-pii.toml,
# a fixed path, so every invocation here overrides HOME to a temp dir. The token
# is invented for this test and is impersonal; the phone values are the OFCOM
# drama range (reserved for fiction, cited by the scanner's own comments) and an
# all-zero subscriber portion that is not allocatable.
#
# Exit: 0 pass, 1 the scanner is blind, 3 CANNOT-RUN (never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$HERE/.github/scripts/operator-pii-scan.sh"
[ -r "$SCANNER" ] || { echo "CANNOT-RUN: no scanner at $SCANNER" >&2; exit 3; }
command -v rg >/dev/null 2>&1 || { echo "CANNOT-RUN: rg absent, the scanner cannot run at all -- this is not a pass" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t piikinds)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

TOK="qqxzvbrand"

# extract_array needs MULTI-LINE arrays: it opens on `key = [` and closes only
# on a line STARTING with `]`. An inline ["x"] opens the array and never closes
# it, swallowing every following line into the pattern. That is a fixture trap
# worth writing down, not a scanner defect.
# THE FIXTURE DIR IS DELIBERATELY NOT NAMED AFTER A UNIX HOME DIRECTORY.
# ci-pii-shape-scan carries a pattern for that path shape, and it matches on
# SHAPE rather than on a list of known values, so naming the fixture dir that
# way writes the shape into this file and trips the guard. It did exactly that
# on the first push of this test. The guard was right; the fix is to stop
# writing the shape, not to weaken the pattern, and that is why this comment
# describes the shape in prose instead of quoting it.
mkdir -p "$TMP/inv"
cat > "$TMP/inv/.ostler-operator-pii.toml" <<TOML
[phone]
hk_mobile_digits = "85200000000"
uk_mobile_digits = "447700900123"
[email]
domains = [
"example.invalid",
]
[home_dir]
usernames = [
"qqxzvuser",
]
[brands_to_strip]
names = [
"${TOK}",
]
[family_names]
names = [
]
[activities]
names = [
]
[username_anywhere]
names = [
]
[allow_paths]
skip = [
]
TOML

run() {  # $1 = dir -> prints the scanner's exit code
    set +e
    HOME="$TMP/inv" bash "$SCANNER" "$1" >/dev/null 2>&1
    local rc=$?
    set -e
    printf '%s' "$rc"
}

carrier() {  # $1 = filename -> a dir containing exactly that file, carrying the token
    local d="$TMP/case_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
    mkdir -p "$d"
    printf 'a\t%s\tb\n' "$TOK" > "$d/$1"
    printf '%s' "$d"
}

printf '== test_operator_pii_scan_sees_all_text_kinds ==\n'

# (0) POSITIVE CONTROL. A .py carrier must be found. If this does not fire the
#     inventory or the patterns are wrong and every verdict below is meaningless.
if [ "$(run "$(carrier mod.py)")" = "1" ]; then
    ok "CONTROL: a .py carrier is found (exit 1)"
else
    echo "  CANNOT-RUN: the .py control did not fire. Inventory or patterns broken," >&2
    echo "  so a miss below would be unreadable. This is not a pass." >&2
    exit 3
fi

# (1) NEGATIVE CONTROL. A dir with the SAME kind but NO token must be clean, so
#     a pass below means "found the token", not "reports dirty for everything".
mkdir -p "$TMP/clean"; printf 'nothing interesting here\n' > "$TMP/clean/mod.py"
[ "$(run "$TMP/clean")" = "0" ] \
    && ok "CONTROL: a carrier-free .py is clean (exit 0), so DIRTY means found" \
    || bad "a file with no denylisted term reported dirty -- the scanner matches anything"

# (2) THE DEFECT AND ITS SIBLINGS. Each of these kinds was invisible before the
#     type list was widened. .tsv is the one that shipped: the PII name registry
#     is a .tsv.
for f in data.tsv notes.env change.patch feed.jsonl graph.ttl conf.example Makefile NOTICE; do
    rc="$(run "$(carrier "$f")")"
    [ "$rc" = "1" ] \
        && ok "a ${f} carrier is found (exit 1)" \
        || bad "a ${f} carrier read as exit ${rc}; the scanner is blind to this kind"
done

# (3) THE EXAMINED DENOMINATOR must be stated. A zero here is otherwise
#     invisible, and the caller prints a STAGED count that is a different number.
# Count matches rather than piping into a short-circuiting consumer: under
# pipefail such a consumer SIGPIPEs the producer and the pipeline reports
# failure ON A MATCH. The repo ratchets that construct in
# tests/pipefail_shortcircuit_baseline.txt, and it caught two instances of it
# in the first push of this very file. This comment therefore describes the
# construct rather than spelling it, so the warning does not itself become a
# new ratchet instance.
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }
hasre() { [ "$(printf '%s\n' "$2" | grep -cE "$1" || true)" -gt 0 ]; }

out="$(HOME="$TMP/inv" bash "$SCANNER" "$(carrier stated.tsv)" 2>&1)"
if hasre 'examined [0-9]+ file\(s\)' "$out"; then
    ok "the scanner states how many files it examined"
else
    bad "no examined-count line; a zero denominator would be invisible"
fi

# (4) AND IT MUST SAY SO OUT LOUD WHEN THAT COUNT IS ZERO. This is the arm that
#     separates "searched and found nothing" from "searched nothing".
mkdir -p "$TMP/nofiles"; printf 'binary-ish\n' > "$TMP/nofiles/thing.unknownkind"
out="$(HOME="$TMP/inv" bash "$SCANNER" "$TMP/nofiles" 2>&1)"
if has 'NOTHING EXAMINED' "$out"; then
    ok "a zero examined-count is announced, not reported as clean"
else
    bad "0 files examined printed no warning -- it reads as a clean scan"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
