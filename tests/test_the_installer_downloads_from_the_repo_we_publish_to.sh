#!/bin/bash
# tests/test_the_installer_downloads_from_the_repo_we_publish_to.sh
#
# THE INSTALLER FETCHED FROM ONE REPOSITORY AND WE PUBLISHED TO ANOTHER, AND
# BOTH STRINGS WERE CORRECTLY SPELLED.
#
# MEASURED 2026-09-06, walking the URL the shipped install.sh names, one hop at
# a time so the redirect that identifies the release is not destroyed:
#
#   subject  releases/latest/download/install.tar.gz   302 -> 404
#   control  a real asset on the SAME release          302 -> 302 -> 200
#
# The control resolving through the identical mechanism is what makes the 404 a
# statement about the asset rather than about the network or the URL form.
#
# The cause was a disagreement between two files in this repo:
#
#   install.sh                    ostler-ai/ostler-releases    <- the DAEMON repo
#   scripts/publish_release.sh    ostler-ai/ostler-installer   <- where artefacts go
#
# ostler-releases holds 43 releases and 101 assets and NOT ONE installer tarball
# or DMG. Every installer artefact this product has published lives in
# ostler-installer, which is also where ostler.ai/install.dmg resolves (walked:
# 302 -> 302 -> 302 -> 200, serving v1.0.41).
#
# A URL that is correctly spelled and points at nothing is the worst shape of
# wrong, because every grep for it succeeds. Only a fetch, or a cross-file
# agreement check like this one, can see it.
#
# WHAT THIS DOES NOT CLAIM. Correcting the repo does not make the URL resolve:
# install.tar.gz exists on v0.1.0, v0.2.0 and v0.3.0 of ostler-installer and on
# nothing since, and `latest` is v1.0.41 which carries DMGs only. Publishing an
# asset is an outward-facing act and is not this test's business. What this test
# pins is that the installer and the publisher NAME THE SAME PLACE, so that when
# an artefact is published it lands where the installer looks.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
PUBLISH_SH="${REPO}/scripts/publish_release.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

for f in "${INSTALL_SH}" "${PUBLISH_SH}"; do
    [ -r "${f}" ] || cant "cannot read ${f}"
    [ -s "${f}" ] || cant "${f} is empty, so every predicate below would pass on nothing"
done

# ---------------------------------------------------------------------------
# The two predicates, defined once so the arms and the mutation use the same
# ones. Each prints the repo it found, or nothing.
# ---------------------------------------------------------------------------
installer_repo() {
    /usr/bin/grep -o 'DEFAULT_INSTALLER_TARBALL_URL="https://github.com/[^/]*/[^/]*' "$1" \
        | head -1 | sed 's|.*github.com/||'
}
publisher_repo() {
    /usr/bin/grep -o 'PUBLISH_RELEASE_REPO:-[^}"]*' "$1" | head -1 | sed 's|.*:-||'
}

I_REPO="$(installer_repo "${INSTALL_SH}")"
P_REPO="$(publisher_repo "${PUBLISH_SH}")"

echo "== CONTROL: both predicates actually FOUND something =="
# 🔴 THE ARM THAT MAKES THE NEXT ONE MEAN ANYTHING. Two empty strings compare
# equal. Without this, a rename that broke both greps would report the files in
# perfect agreement, which is the single most likely way this test rots.
if [ -n "${I_REPO}" ] && [ -n "${P_REPO}" ]; then
    ok "CONTROL: installer names '${I_REPO}', publisher names '${P_REPO}' -- both non-empty, so the comparison below is between two measurements and not between two silences"
else
    bad "CONTROL: a predicate returned nothing (installer='${I_REPO}' publisher='${P_REPO}') -- the agreement check below would pass on two empties, so it is reported as a FAILURE of this test and not as agreement"
fi

echo "== the installer downloads from the repo we publish to =="
if [ -n "${I_REPO}" ] && [ "${I_REPO}" = "${P_REPO}" ]; then
    ok "install.sh and scripts/publish_release.sh both name ${I_REPO}"
else
    bad "install.sh fetches from '${I_REPO}' but publish_release.sh uploads to '${P_REPO}' -- an artefact published by the ceremony lands where the installer does not look"
fi

echo "== --help advertises the URL the code actually uses =="
CODE_URL="$(/usr/bin/grep -o 'DEFAULT_INSTALLER_TARBALL_URL="[^"]*"' "${INSTALL_SH}" | head -1 | sed 's|.*="||; s|"$||')"
HELP_URL="$(/usr/bin/grep -o 'Default: https://github.com/[^ "]*install\.tar\.gz' "${INSTALL_SH}" | head -1 | sed 's|Default: ||')"
if [ -z "${CODE_URL}" ] || [ -z "${HELP_URL}" ]; then
    bad "could not extract both URLs (code='${CODE_URL}' help='${HELP_URL}') -- an empty extraction is not agreement"
elif [ "${CODE_URL}" = "${HELP_URL}" ]; then
    ok "--help and the code agree: ${CODE_URL}"
else
    bad "--help advertises '${HELP_URL}' but the code uses '${CODE_URL}' -- the documented default is not the real one"
fi

echo "== the failure path names the route that actually works =="
# Measured: ostler.ai/install.dmg walks 302 -> 302 -> 302 -> 200. The tarball
# route does not resolve. When the fetch fails, the user must be told the one
# that does, not only asked to wait.
if /usr/bin/grep -q 'https://ostler.ai/install.dmg' "${INSTALL_SH}"; then
    ok "the bootstrap failure path points at https://ostler.ai/install.dmg"
else
    bad "the bootstrap failure path never names the .dmg, so a user whose fetch failed is told only to wait for an artefact nobody publishes"
fi

echo "== CONTROL: the daemon and RemoteCapture repos are NOT swept up =="
# ostler-releases is the CORRECT home for those two. A test that simply banned
# the string would be a blanket, and would break the daemon fetch the next time
# somebody 'fixed' it.
d_ok=0; r_ok=0
/usr/bin/grep -q 'OSTLER_ASSISTANT_REPO:-ostler-ai/ostler-releases' "${INSTALL_SH}" && d_ok=1
/usr/bin/grep -q 'OSTLER_REMOTECAPTURE_REPO:-ostler-ai/ostler-releases' "${INSTALL_SH}" && r_ok=1
if [ "${d_ok}" -eq 1 ] && [ "${r_ok}" -eq 1 ]; then
    ok "CONTROL: the daemon and RemoteCapture still resolve to ostler-releases, so this is a targeted correction and not a ban on the string"
else
    bad "CONTROL: daemon=${d_ok} remotecapture=${r_ok} -- ostler-releases is the right home for those two and one of them has moved"
fi

echo "== MUST-MISS: the agreement predicate can tell two repos apart =="
# If the predicate cannot see a disagreement, every arm above is decoration.
# 🔴 `mktemp -t NAME` WITH NO X's IS BSD-ONLY, AND THIS REPO ALREADY SAYS SO
# FIVE TIMES. GNU rejects it ("too few X's"), so on an ubuntu runner this line
# fired cant() and the gate returned rc=2. CI refused to call that a pass,
# which is correct -- CANNOT-RUN is not a pass -- but the refusal was about my
# portability, not about the estate. Measured on the host that runs it, not on
# the one I wrote it on. The house pattern here is `mktemp -d`, 102 uses.
MUTDIR="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "${MUTDIR}"' EXIT
MUT="${MUTDIR}/bootstrap-mutant"
sed 's|DEFAULT_INSTALLER_TARBALL_URL="https://github.com/ostler-ai/[^/]*|DEFAULT_INSTALLER_TARBALL_URL="https://github.com/ostler-ai/some-other-repo|' \
    "${INSTALL_SH}" > "${MUT}"
M_REPO="$(installer_repo "${MUT}")"
if [ "${M_REPO}" = "ostler-ai/some-other-repo" ] && [ "${M_REPO}" != "${P_REPO}" ]; then
    ok "MUST-MISS: a mutated install.sh reads as '${M_REPO}' and compares UNEQUAL to the publisher, so the arm above is a real comparison"
else
    bad "MUST-MISS: the mutated install.sh read as '${M_REPO}' -- the mutation did not land or the predicate cannot discriminate, so the agreement arm proves nothing"
fi

echo
echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="
[ "${fail}" -eq 0 ] || exit 1
exit 0
