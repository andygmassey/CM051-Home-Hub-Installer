#!/usr/bin/env bash
# tests/test_user_root_is_home_ostler_not_documents.sh
# =====================================================
# Privacy defect (measured 2026-11-11): the plaintext user-facing root was
# ~/Documents/Ostler, which iCloud "Desktop & Documents" uploads (19 of 21 files
# dataless on a sync-ON Mac). The root is now ~/Ostler (home top level, never
# synced by that feature). Three claims, each with its own control:
#   1. FRESH: install.sh's USER_FACING_ROOT resolves to $HOME/Ostler.
#   2. MIGRATE: _ostler_migrate_user_root (extracted from install.sh, run under a
#      TEMP HOME) renames a synthetic ~/Documents/Ostler to ~/Ostler, leaves NO
#      symlink or directory in Documents, warns about iCloud copies ONLY when
#      FXICloudDriveDocuments=1, and never merges or deletes when ~/Ostler exists.
#   3. GATE: no tracked file still names Documents/Ostler (any shipped locale
#      form, or the Python "Documents","Ostler" join), outside a short allowlist.
# Never touches the real HOME. `defaults` is shimmed on PATH. Three outcomes:
# exit 0 pass, 1 fail, 2 CANNOT-RUN.
set -u
GREP=/usr/bin/grep
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"
CAT="${REPO}/install.sh.strings.en-GB.sh"
fail=0
ok()  { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
[ -f "$INSTALL" ] && [ -f "$CAT" ] || cannot "install.sh or en-GB catalogue missing"

W="$(mktemp -d)" || cannot "mktemp"
trap 'rm -rf "$W"' EXIT
REAL_HOME="${HOME}"

# ---- 1. FRESH ---------------------------------------------------------------
line="$($GREP -m1 -E '^USER_FACING_ROOT=' "$INSTALL")" || cannot "no USER_FACING_ROOT= in install.sh"
H1="$W/h1"; mkdir -p "$H1"
got="$(HOME="$H1" bash -c "$line"' ; printf %s "$USER_FACING_ROOT"')"
[ "$got" = "$H1/Ostler" ] && ok "fresh root resolves to \$HOME/Ostler" || bad "fresh root is '$got', want '$H1/Ostler'"
ucount="$($GREP -c -E '^USER_FACING_ROOT=' "$INSTALL")"
bad_roots="$($GREP -n -E '^USER_FACING_ROOT=' "$INSTALL" | $GREP -v -F '${HOME}/Ostler"' || true)"
[ -z "$bad_roots" ] && ok "all $ucount USER_FACING_ROOT assignments (installer + uninstaller) are \${HOME}/Ostler" || bad "USER_FACING_ROOT assigned elsewhere: $bad_roots"

# ---- 2. MIGRATE -------------------------------------------------------------
fn="$(awk '/^_ostler_migrate_user_root\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$INSTALL")"
[ -n "$fn" ] || { bad "_ostler_migrate_user_root not found in install.sh"; fn=':'; }
mkdir -p "$W/bin"
printf '#!/bin/sh\n# shim: `defaults read com.apple.finder FXICloudDriveDocuments`\n[ "$1 $2 $3" = "read com.apple.finder FXICloudDriveDocuments" ] && { echo "${SHIM_FX:-0}"; exit 0; }\necho "unexpected defaults call: $*" >&2; exit 1\n' > "$W/bin/defaults"
chmod +x "$W/bin/defaults"

run_case() {   # $1=home $2=FXICloudDriveDocuments value ; prints transcript
    HOME="$1" SHIM_FX="$2" PATH="$W/bin:$PATH" CAT="$CAT" FN="$fn" bash -c '
        set -u
        source "$CAT"
        info() { echo "[info] $*"; }
        warn() { echo "[warn] $*"; }
        USER_FACING_ROOT="${HOME}/Ostler"
        eval "$FN"
        _ostler_migrate_user_root; echo "rc=$?"'
}
mk_old() { mkdir -p "$1/Documents/Ostler/Wiki" "$1/Documents/Ostler/Conversations/2026-10-01/chat-abc"; echo page > "$1/Documents/Ostler/Wiki/p.md"; echo s > "$1/Documents/Ostler/Conversations/2026-10-01/chat-abc/summary.md"; }

# (a) sync ON: moves, warns
Ha="$W/ha"; mk_old "$Ha"; out="$(run_case "$Ha" 1)"
[ -f "$Ha/Ostler/Wiki/p.md" ] && [ -f "$Ha/Ostler/Conversations/2026-10-01/chat-abc/summary.md" ] && ok "synthetic tree moved to ~/Ostler, contents intact" || bad "tree not moved intact: $out"
[ ! -e "$Ha/Documents/Ostler" ] && [ ! -L "$Ha/Documents/Ostler" ] && ok "nothing (no dir, no symlink) left at ~/Documents/Ostler" || bad "~/Documents/Ostler still present"
echo "$out" | $GREP -q 'earlier copies of your Ostler files may already be in iCloud Drive' && ok "sync ON: iCloud-copies warning printed" || bad "sync ON but no iCloud warning: $out"
echo "$out" | $GREP -q 'rc=0' || bad "migration returned non-zero: $out"
# (b) sync OFF: moves, no warning (control: the warning is conditional, not constant)
Hb="$W/hb"; mk_old "$Hb"; out="$(run_case "$Hb" 0)"
[ -f "$Hb/Ostler/Wiki/p.md" ] && ok "sync OFF: moved" || bad "sync OFF: not moved: $out"
echo "$out" | $GREP -q 'iCloud Drive' && echo "$out" | $GREP -q 'earlier copies' && bad "sync OFF but iCloud warning printed" || ok "sync OFF: no iCloud warning"
# (c) both exist: untouched, warned, nothing deleted
Hc="$W/hc"; mk_old "$Hc"; mkdir -p "$Hc/Ostler"; echo mine > "$Hc/Ostler/keep.md"; out="$(run_case "$Hc" 1)"
[ -f "$Hc/Documents/Ostler/Wiki/p.md" ] && [ -f "$Hc/Ostler/keep.md" ] && [ ! -e "$Hc/Ostler/Wiki" ] && ok "both exist: neither side touched, no merge" || bad "both-exist case mutated something: $out"
echo "$out" | $GREP -q '\[warn\].*could not be moved' && ok "both exist: not-moved warning printed" || bad "both exist: no not-moved warning: $out"
# (d) fresh box: no Documents/Ostler -> nothing created anywhere, no warning
Hd="$W/hd"; mkdir -p "$Hd/Documents"; out="$(run_case "$Hd" 1)"
[ ! -e "$Hd/Ostler" ] && [ ! -e "$Hd/Documents/Ostler" ] && ok "fresh box: migration creates nothing" || bad "fresh box: migration created a path: $out"
echo "$out" | $GREP -q '\[warn\]' && bad "fresh box: spurious warning: $out" || ok "fresh box: silent"
# (e) a symlink at the old path is never followed or moved
He="$W/he"; mkdir -p "$He/Documents" "$He/elsewhere"; ln -s "$He/elsewhere" "$He/Documents/Ostler"; out="$(run_case "$He" 1)"
[ -L "$He/Documents/Ostler" ] && [ ! -e "$He/Ostler" ] && ok "symlink at the old path left alone" || bad "symlink case mutated: $out"
# the real HOME was never the sandbox
[ "$HOME" = "$REAL_HOME" ] || bad "HOME leaked"

# ---- 3. GATE ----------------------------------------------------------------
cd "$REPO" || cannot "cd $REPO"
git rev-parse --git-dir >/dev/null 2>&1 || cannot "not a git checkout; the gate reads tracked files"
PAT='(Documents|Dokumente|Documentos|Documenti|Documenten)/Ostler|"Documents" *(/|,) *"Ostler"|「(文稿|文件|書類)」(内の|/)Ostler|Documents\\/Ostler'
# ALLOWLIST (reason): the walk harness's cold proof WIPES ~/Documents/Ostler on a
# walk box so a legacy root cannot carry state into a cold walk; the wipe script
# and its test are excluded, and ttywalk.sh / post_walk_qa.sh only as COMMENT
# lines. No shipped file is excluded.
hits="$(git grep -n -E "$PAT" -- . \
    ':!cuts' ':!cut-manifests' ':!vendor/divergences/*.patch' ':!tests/test_user_root_is_home_ostler_not_documents.sh' \
    ':!tests/test_uninstall_legacy_documents_root.sh' ':!vendor/divergences/*.UNRECORDED.md' \
    ':!scripts/walk_cold_wipe_state.sh' ':!tests/test_ttywalk_reset_is_cold_or_refuses.sh' \
    | $GREP -v -E '^scripts/(ttywalk|post_walk_qa)\.sh:[0-9]+:[[:space:]]*#' \
    | $GREP -v -E '^install\.sh:[0-9]+:.*(local old=|# Older installs wrote the root under|ensure legacy|# ── Legacy root: |LEGACY_ROOT="\$\{HOME\}/Documents/Ostler")' )"
rc=$?
if [ -z "$hits" ]; then ok "no tracked file outside the allowlist names Documents/Ostler"
else bad "files still name the old root:"; echo "$hits" | cut -c1-200 >&2; fi
# control: the same pattern DOES see the legacy path where it must exist (the migration source)
git grep -q -E "$PAT" -- install.sh && ok "gate control: pattern still matches install.sh's migration source (predicate can fire)" || bad "gate control: pattern matched nothing in install.sh; the predicate is blind"

[ "$fail" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "RESULT: FAIL" >&2; exit 1; }
