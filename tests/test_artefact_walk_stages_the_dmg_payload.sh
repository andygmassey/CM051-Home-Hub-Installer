#!/usr/bin/env bash
# --from-dmg must stage the ARTEFACT, and must refuse loudly when it cannot.
#
# WHY THIS EXISTS. Every walk this harness ran before #1454 staged the REPO and
# called the result a walk. The gap was carried in prose on every green,
# including walk 18 of v1.0.65, and prose is not a gate.
#
# It is not a theoretical gap. On v1.0.65, 23 of the DMG's 48 payload entries
# were ABSENT from a full repo checkout; walk 9 died at step 21 on exactly that,
# and the only way past it was copying 22 of them in by hand from a mounted DMG
# into a worktree under /private/tmp, which macOS clears on boot.
#
# WHAT THIS TEST DOES NOT COVER, said here so it is not assumed: it does not
# mount a DMG. `hdiutil` needs a real image and CI has none. It drives the
# LOCATE-AND-VALIDATE half against fixture trees shaped like a mounted volume,
# and asserts the staging half is wired to the variable that mode sets. The
# mount half was measured by hand against OstlerInstaller-1.0.63.dmg and that
# measurement is recorded in #1454's commit body, not here.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WALK="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$WALK" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${WALK}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# The locate expression, taken FROM the script rather than restated, so this
# tests the shipped predicate and not a copy of it that can drift.
_expr="$(/usr/bin/grep -oE "/usr/bin/find \"\\\$DMG_MNT\" -maxdepth 3 -type d -name Resources -path '[^']*'" "$WALK" | head -1)"
if [ -z "$_expr" ]; then
    echo "CANNOT-RUN: could not read the Resources locate expression out of ${WALK}." >&2
    echo "  Restating it here would test a copy, not the shipped predicate." >&2
    exit 2
fi
_path_glob="$(printf '%s' "$_expr" | sed -E "s/.*-path '([^']*)'.*/\1/")"

# Build a tree shaped like a mounted volume and run the shipped predicate on it.
_locate() {  # $1 = mount root
    /usr/bin/find "$1" -maxdepth 3 -type d -name Resources -path "$_path_glob" 2>/dev/null | head -1
}

echo "── the locate predicate, against fixture volumes ──"

_good="${WORK}/good"
mkdir -p "${_good}/OstlerInstaller.app/Contents/Resources"
: > "${_good}/OstlerInstaller.app/Contents/Resources/install.sh"
mkdir -p "${_good}/OstlerInstaller.app/Contents/Resources/contact_syncer"
_r="$(_locate "$_good")"
if [ -n "$_r" ] && [ -f "${_r}/install.sh" ]; then
    ok "a well-formed volume yields <app>/Contents/Resources with install.sh in it"
else
    bad "a well-formed volume did not resolve: got '${_r:-<empty>}'"
fi

# CONTROL 1. A volume with NO app bundle must yield nothing, or the predicate
# would match any directory called Resources anywhere and stage the wrong tree.
_bare="${WORK}/bare"
mkdir -p "${_bare}/Resources"
: > "${_bare}/Resources/install.sh"
_r="$(_locate "$_bare")"
if [ -z "$_r" ]; then
    ok "CONTROL: a bare Resources/ NOT inside an .app bundle does not match"
else
    bad "CONTROL: matched '${_r}', which is not inside an .app. The predicate would stage any directory named Resources."
fi

# CONTROL 2. An app bundle whose Resources has no install.sh is not a payload
# root, and the script must say so rather than stage it.
_noinstall="${WORK}/noinstall"
mkdir -p "${_noinstall}/OstlerInstaller.app/Contents/Resources"
_r="$(_locate "$_noinstall")"
if [ -n "$_r" ] && [ ! -f "${_r}/install.sh" ]; then
    ok "CONTROL: a Resources with no install.sh is located but has no install.sh, which is the case the script refuses on"
else
    bad "CONTROL: expected to locate a Resources lacking install.sh; got '${_r:-<empty>}'"
fi

echo "── the refusals must exist and must be fatal ──"

for probe in \
    'no file at' \
    'hdiutil attach failed' \
    'no <app>/Contents/Resources inside' \
    'has no install.sh'
do
    if /usr/bin/grep -qF "$probe" "$WALK"; then
        ok "refuses with a named reason: \"${probe}\""
    else
        bad "no refusal containing \"${probe}\" -- a malformed artefact could stage silently"
    fi
done

# Each of those four must be a `die`, not a warning. A mode that warns and then
# stages the repo would produce a SOURCE walk labelled as an artefact walk,
# which is worse than refusing.
_n_die=$(/usr/bin/grep -cE 'die "--from-dmg' "$WALK")
if [ "$_n_die" -ge 4 ]; then
    ok "all ${_n_die} --from-dmg refusals are die(), so none of them degrades into a repo walk"
else
    bad "only ${_n_die} of the --from-dmg refusals call die(); a warn here silently swaps the subject"
fi

echo "── the staging must actually use what the mode set ──"

if /usr/bin/grep -qE '"\$\{STAGE_SRC\}/" "\$\{HOST\}:\$\{REMOTE_DIR\}/"' "$WALK"; then
    ok "rsync stages \$STAGE_SRC, so --from-dmg reaches the box"
else
    bad "rsync does not stage \$STAGE_SRC. The mode would compute a path and then send the repo anyway."
fi

# CONTROL. STAGE_SRC must DEFAULT to the repo, or a plain walk would stage
# nothing and the mode would be mandatory.
if /usr/bin/grep -qE '^STAGE_SRC="\$REPO_ROOT"' "$WALK"; then
    ok "CONTROL: STAGE_SRC defaults to the repo, so a plain walk is unchanged"
else
    bad "CONTROL: STAGE_SRC has no repo default; a plain walk would stage an empty path"
fi

echo "── both modes must SAY which subject they measured ──"

if /usr/bin/grep -qF 'THIS IS A SOURCE-TRUTH WALK' "$WALK"; then
    ok "the repo path announces that it is NOT the artefact"
else
    bad "a repo walk does not say so, so its green can be quoted as an artefact result"
fi
if /usr/bin/grep -qF 'the .app is NOT launched' "$WALK"; then
    ok "the artefact path discloses that it still does not launch the .app"
else
    bad "the artefact path claims more coverage than it has: nothing states the .app is never launched"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
