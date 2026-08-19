#!/usr/bin/env bash
# Scope tests for .github/scripts/ci-pii-shape-scan.sh.
#
# Cases 1-5 pin PR (BASE_REF) mode, which is how CI invokes it.
# Cases 6-8 pin PATH-ARGUMENT mode, which is how a human audits a subtree by
# hand -- the path with no second check behind it, and the one where a
# directory used to read as clean.
#
# WHAT THIS PINS, and why it is a scope test rather than a pattern test:
# .githooks/test_pii_patterns.sh already proves the PATTERNS fire. This proves
# the scan asks the right QUESTION -- "did this change introduce PII-shaped
# content" -- rather than "does any file this change touched contain any".
#
# The v1 scan collected `git diff --name-only` and scanned each named file in
# FULL. Measured on CM051 #587: a two-line Docker-digest change to install.sh
# went red on two `Example:` strings that had been on main for months. Case 2
# below is that exact scenario.
#
# NO PHONE-SHAPED LITERAL IS WRITTEN INTO THIS FILE. Every one is composed from
# parts at runtime, because the repo's own pre-commit hook scans this file and
# a gate's test must not carry the thing the gate hunts.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCAN="$REPO_ROOT/.github/scripts/ci-pii-shape-scan.sh"
LIB="$REPO_ROOT/.githooks/pii_patterns.sh"
PASS=0; FAIL=0

ok()  { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m  %s (rc=%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Composed, never a literal: this file is scanned by the guard it tests.
#
# MUST BE A NON-RESERVED NUMBER, and this is not a detail. An earlier version
# used the OFCOM drama range (07700 900xxx) because the library then in this
# repo fired on it. Re-provisioning the library from HR015 brought
# pii_reserved_placeholder_re with it, whose whole job is to EXCUSE that range,
# and 7 of these 8 cases inverted at once: every limb expecting RED went green,
# because the fixture had become invisible to the scanner rather than because
# any scope logic changed.
#
# The number below is shape-valid and outside every reserved range, so it
# exercises the scan rather than the exemption. If a future change makes these
# cases mysteriously pass, check the FIXTURE before the logic.
phone() { printf '+44%s%s' "7911" "123456"; }

mkrepo() { # -> echoes a fresh repo dir with one commit on main
    d="$(mktemp -d -t pii-scope-XXXXXX)"
    git -C "$d" init -q -b main
    git -C "$d" config user.email a@b.c
    git -C "$d" config user.name t
    mkdir -p "$d/.github/scripts" "$d/.githooks"
    cp "$SCAN" "$d/.github/scripts/"
    cp "$LIB"  "$d/.githooks/"
    printf 'clean baseline\n' > "$d/seed.txt"
    git -C "$d" add -A >/dev/null
    git -C "$d" commit -qm base
    printf '%s' "$d"
}

run_scan() { # repo base -> rc
    ( cd "$1" && BASE_REF="$2" bash .github/scripts/ci-pii-shape-scan.sh >/dev/null 2>&1 )
}

run_paths() { # repo path... -> rc   (path-argument mode, no BASE_REF)
    r="$1"; shift
    ( cd "$r" && bash .github/scripts/ci-pii-shape-scan.sh "$@" >/dev/null 2>&1 )
}

echo "ci-pii-shape-scan: PR-mode scope"

# ── Case 1. THE DEMONSTRATED RED. Modified file, phone ADDED by the change. ──
d="$(mkrepo)"; base="$(git -C "$d" rev-parse HEAD)"
printf 'contact = "%s"\n' "$(phone)" >> "$d/seed.txt"
git -C "$d" commit -aqm add-phone
run_scan "$d" "$base"; rc=$?
[ "$rc" -eq 1 ] && ok "(1) phone ADDED to a modified file -> RED" || bad "(1) added phone must be RED" "$rc"
rm -rf "$d"

# ── Case 2. THE #587 FALSE POSITIVE. Phone pre-exists; change is elsewhere. ──
d="$(mkrepo)"
printf 'echo "  Example: %s"\n' "$(phone)" >> "$d/seed.txt"
git -C "$d" commit -aqm preexisting-example
base="$(git -C "$d" rev-parse HEAD)"
printf 'unrelated line\n' >> "$d/seed.txt"
git -C "$d" commit -aqm unrelated-change
run_scan "$d" "$base"; rc=$?
[ "$rc" -eq 0 ] && ok "(2) phone PRE-EXISTS, change is elsewhere -> green (the #587 case)" \
                || bad "(2) pre-existing content must not fail the PR" "$rc"
rm -rf "$d"

# ── Case 3. THE HOLE NARROWING WOULD OPEN. Rename carries the payload. ──
# A rename can move a file full of PII to a new path with no added lines, so
# renames are scanned in FULL. Without that, case 3 goes green and the
# narrowing is a bypass.
d="$(mkrepo)"
printf 'contact = "%s"\n' "$(phone)" > "$d/old_name.txt"
git -C "$d" add -A >/dev/null; git -C "$d" commit -qm seed-old
base="$(git -C "$d" rev-parse HEAD)"
git -C "$d" mv old_name.txt new_name.txt
git -C "$d" commit -qm rename-only
run_scan "$d" "$base"; rc=$?
[ "$rc" -eq 1 ] && ok "(3) RENAME carrying a phone -> RED (narrowing did not open a bypass)" \
                || bad "(3) rename must be scanned in full" "$rc"
rm -rf "$d"

# ── Case 4. New file with a phone is scanned in full. ──
d="$(mkrepo)"; base="$(git -C "$d" rev-parse HEAD)"
printf 'contact = "%s"\n' "$(phone)" > "$d/brand_new.txt"
git -C "$d" add -A >/dev/null; git -C "$d" commit -qm add-file
run_scan "$d" "$base"; rc=$?
[ "$rc" -eq 1 ] && ok "(4) ADDED file carrying a phone -> RED" || bad "(4) added file must be RED" "$rc"
rm -rf "$d"

# ── Case 5. Removing PII is not a violation. ──
d="$(mkrepo)"
printf 'contact = "%s"\n' "$(phone)" >> "$d/seed.txt"
git -C "$d" commit -aqm seed-phone
base="$(git -C "$d" rev-parse HEAD)"
printf 'clean baseline\n' > "$d/seed.txt"
git -C "$d" commit -aqm remove-phone
run_scan "$d" "$base"; rc=$?
[ "$rc" -eq 0 ] && ok "(5) REMOVING a phone -> green (removed lines are never scanned)" \
                || bad "(5) deleting PII must not be a violation" "$rc"
rm -rf "$d"

# ── Cases 6-8. PATH-ARGUMENT mode: a directory must never read as clean. ──
# MEASURED 2026-08-15: `ci-pii-shape-scan.sh vendor/` printed "examining 0
# file(s) ... nothing was found" and exited 0, while the same tree as an
# explicit file list exited 1 on twelve files. The `[ -f ]` filter dropped the
# directory as quietly as it drops a stale path.
#
# Case 7 is the load-bearing one. Case 6 alone would still pass if the scanner
# had simply started refusing everything, and it would pass over an EMPTY
# directory, where a zero is the truth. Case 7 proves the directory really did
# hold a hit -- so the old exit 0 was a false clean, not an honest one.
d="$(mkrepo)"
mkdir -p "$d/subtree"
printf 'contact = "%s"\n' "$(phone)" > "$d/subtree/buried.txt"
git -C "$d" add -A >/dev/null; git -C "$d" commit -qm seed-subtree

run_paths "$d" subtree; rc=$?
[ "$rc" -eq 2 ] && ok "(6) DIRECTORY argument -> CANNOT-RUN (rc 2), never a pass" \
                || bad "(6) a directory must not report clean" "$rc"

run_paths "$d" subtree/buried.txt; rc=$?
[ "$rc" -eq 1 ] && ok "(7) same content as an explicit FILE -> RED (so case 6 was a false clean)" \
                || bad "(7) the expanded file list must still find the phone" "$rc"

# The refusal must not have swallowed the legitimate drop. git can name a path
# the working tree no longer has; that is not a caller error and stays green.
run_paths "$d" seed.txt no/such/file.txt; rc=$?
[ "$rc" -eq 0 ] && ok "(8) a STALE path is still dropped silently -> green" \
                || bad "(8) a non-existent path must not be CANNOT-RUN" "$rc"
rm -rf "$d"

echo
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ]
