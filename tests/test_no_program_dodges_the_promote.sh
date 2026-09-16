#!/usr/bin/env bash
# A program written straight to the FINAL bin dir is deleted by the promote.
#
# WHAT HAPPENED, measured rather than reasoned.
# install.sh created ~/.ostler/bin/ostler-ollama-logrotate directly, with a
# comment arguing that this made the plist's ProgramArguments "always valid,
# independent of the later staging-tree promotion", because "nothing else
# writes ${OSTLER_DIR}/bin pre-FDA".
#
# TWO THINGS DO: the ostler-unlock symlink and the engine-supervisor copy. So
# the staging tree HAS a bin/, and _ostler_promote_prelaunch_tree merges per
# top-level entry -- `rm -rf "${OSTLER_FINAL_DIR}/${name}"` then `mv` -- so it
# deletes the whole final bin/ and replaces it with staging's. The file went
# with it.
#
# ON A LIVE BOX: ~/.ostler/bin/ostler-ollama-logrotate absent (ls rc=1),
# ostler-fda in the same directory present (rc=0, 7,925 bytes) as the control.
# launchd: EX_CONFIG (78). Both of the agent's logs 0 bytes: it never ran once.
#
# THE RULE. Every program is written to ${OSTLER_DIR}/bin and reaches the
# customer through the promote. A direct write to the final bin dir is an
# attempt to dodge that machinery, and the machinery wins. Plists may NAME the
# final path, because that is where the promote puts the file and what launchd
# execs; it is the CREATION that must go through staging.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0; PASS=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Creation verbs only. A bare reference (a plist string, a comment, a PATH
# export) is fine and is NOT what this catches.
scan() {
    /usr/bin/grep -nE '^[^#]*(cat[[:space:]]*>|cp[[:space:]]|ln[[:space:]]+-s|install[[:space:]]+-m|chmod[[:space:]]+\+x)[^#]*(\$\{HOME\}/\.ostler/bin/|\$\{OSTLER_FINAL_DIR\}/bin/)' "$1" || true
}

hits="$(scan install.sh)"
if [ -z "$hits" ]; then
    ok "no program is created directly in the final bin dir; every one goes through the promote"
else
    bad "these create a file in the FINAL bin dir, which the promote deletes:
$(printf '%s\n' "$hits" | sed 's/^/           /')
         Write to \${OSTLER_DIR}/bin instead, as every other program does."
fi

# POSITIVE CONTROL. The predicate must be able to fire, or the pass above is
# a statement about the regex rather than about the tree.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf 'cat > "${HOME}/.ostler/bin/ostler-control-probe" <<EOF\nx\nEOF\n' > "$tmp"
if [ -n "$(scan "$tmp")" ]; then
    ok "CONTROL: a deliberate direct write to the final bin dir IS detected"
else
    bad "CONTROL FAILED: a file built to contain the exact defect was not
         detected, so the clean result above proves nothing."
fi

# SECOND CONTROL: a plist STRING naming the final path must NOT be flagged.
# Without this the rule would forbid the correct thing and get switched off.
printf '        <string>${OSTLER_FINAL_DIR}/bin/ostler-ollama-logrotate</string>\n' > "$tmp"
if [ -z "$(scan "$tmp")" ]; then
    ok "CONTROL: a plist naming the final path is NOT flagged, only creation is"
else
    bad "a plist reference was flagged. Plists must name the final path; this
         rule is about where the file is CREATED, not where it is named."
fi

printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
