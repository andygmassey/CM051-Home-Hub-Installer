#!/usr/bin/env bash
#
# verify_app_provenance.sh -- PRE-SEAL provenance gate for the Tauri Ostler.app.
#
# WHY THIS EXISTS
# ---------------
# `notarise-hub` seals Ostler.app with the Developer ID unconditionally. That is
# correct: an unsigned bundle must never reach Apple. But it removed an
# ACCIDENTAL backstop:
#
#   BEFORE   ad-hoc bundle -> notarytool -> Invalid -> cut DIES at step 11
#   AFTER    ad-hoc bundle -> sealed by us -> Accepted -> SHIPS
#
# The only surviving assertion (`TeamIdentifier=$(TEAM_ID)` in
# verify-dmg-contents) runs AFTER the seal we just applied, so it can only fail
# if `codesign` itself failed. That is a gate that cannot fail.
#
# `verify_commit_parity.sh` asks the right question but runs POST-cut, on a
# mounted DMG, after a notarisation round trip has already been spent. This
# script asks it at step 5, before anything is signed.
#
# WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
# --------------------------------------------------
# It does NOT assert wrapper_commit == daemon_commit. That predicate is pinned
# to the wrong axis and it goes RED ON A CORRECT BUNDLE:
#
#   apps/tauri/build.rs resolves the marker with `git rev-parse HEAD`. Despite
#   the name WRAPPER_FRONTEND_COMMIT it records the REPO HEAD, not the last
#   commit that touched the frontend. So a wrapper built at HEAD_1 and a daemon
#   built at HEAD_2 carry different markers even when web/ is byte-identical.
#
#   Measured 2026-08-14: the live bundle carries e0234e71, the shipping daemon
#   is acf991bf, three commits apart. Those three commits touched embeddings.rs,
#   release/ingest-ticks/*/tick.sh and workflow docs. The frontend diff across
#   that range is EMPTY. A SHA-equality gate fails that bundle, and a gate that
#   goes red on a good tree gets switched off.
#
# So parity is asserted on frontend CONTENT: the git tree hash of the frontend
# paths at each commit. Identical content passes however far apart the commits
# are; genuinely different content fails however close they are.
#
# THE UNATTESTABLE CASES, WHICH ARE THE ONES THAT ACTUALLY BITE
# -------------------------------------------------------------
# build.rs falls back to `"0".repeat(40)` when git is unreachable, so an
# unattestable binary still carries a WELL-FORMED marker. A `[0-9a-f]{40}`
# extraction matches it happily. verify_commit_parity.sh rejects only the EMPTY
# case, which means if BOTH binaries were built without a reachable .git they
# both read 000...0, they compare EQUAL, and it prints
# "commit-parity verified: daemon=000...0 wrapper=000...0" and exits 0.
# Two binaries that cannot say what they are, passing a gate whose success
# message asserts their identity. This script rejects the all-zero marker
# explicitly.
#
# EXIT CODES (matching this repo's convention -- see verify_pbxproj_in_sync.sh)
#   0  provenance asserted
#   1  the bundle is WRONG (missing/unattestable marker, or frontend mismatch)
#   2  could not run (bad usage, no bundle, no reference checkout). NOT a pass.
set -euo pipefail

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; OFF=$'\033[0m'
ok(){   printf '%s[ok]%s   %s\n'   "$GRN" "$OFF" "$*"; }
warn(){ printf '%s[warn]%s %s\n'  "$YEL" "$OFF" "$*" >&2; }
bad(){  printf '%s[FAIL]%s %s\n'  "$RED" "$OFF" "$*" >&2; }
cannot(){ printf '%s[CANNOT]%s %s\n' "$YEL" "$OFF" "$*" >&2
          printf '  This gate did not run. That is NOT a pass -- resolve the\n' >&2
          printf '  cause and re-run before cutting.\n' >&2
          exit 2; }

ZEROS="$(printf '0%.0s' $(seq 1 40))"

# Frontend paths whose CONTENT defines "the frontend this wrapper carries".
# apps/tauri/tauri.conf.json declares frontendDist "../../web/dist", built from
# web/ by its beforeBuildCommand. Declared here rather than inferred so a
# reader can see exactly what is compared, and so adding a path is a visible
# one-line change rather than a silent widening.
FRONTEND_PATHS=("web")

APP="${1:-}"
[[ -n "$APP" ]] || cannot "usage: verify_app_provenance.sh <path-to-Ostler.app> [reference-checkout]"
[[ -d "$APP" ]] || cannot "not a bundle directory: $APP"

# The reference checkout that can resolve commits into trees. Explicit second
# argument wins (the self-test injects a fixture); otherwise the ostler-assistant
# checkout that sits BESIDE this one. Never a home literal -- that is the rot
# already documented at verify_commit_parity.sh:130.
REF="${2:-}"
if [[ -z "$REF" ]]; then
    REF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ostler-assistant"
fi
[[ -d "$REF/.git" ]] || cannot "reference checkout is not a git repo: $REF"

# --------------------------------------------------------------------------
# Ask the bundle what it execs. Never hardcode the executable name: it was
# pinned to "zeroclaw-desktop" once, a name retired in the rename, and a
# hardcoded name both fails a correct bundle AND passes a bundle whose real
# executable is missing so long as a stale-named file sits beside it.
# --------------------------------------------------------------------------
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$EXE" ]] || cannot "$APP declares no CFBundleExecutable (Info.plist missing or unreadable)"
BIN="$APP/Contents/MacOS/$EXE"
[[ -e "$BIN" ]] || cannot "declared executable not present: Contents/MacOS/$EXE"

WRAPPER_SHA="$(strings "$BIN" 2>/dev/null \
    | grep -oE 'WRAPPER_FRONTEND_COMMIT=[0-9a-f]{40}' | head -1 | cut -d= -f2 || true)"

# --------------------------------------------------------------------------
# (1) The bundle must be able to say what built it. THIS is the case that was
#     described as "built from an unidentified commit" -- it must fail here,
#     before the seal, not after a notarisation.
# --------------------------------------------------------------------------
if [[ -z "$WRAPPER_SHA" ]]; then
    bad "Ostler.app carries NO WRAPPER_FRONTEND_COMMIT marker."
    printf '  bundle : %s\n' "$APP" >&2
    printf '  execs  : %s\n' "$EXE" >&2
    printf '\n  It cannot attest which commit built it, so nothing downstream can\n' >&2
    printf '  either. Sealing it would launder an unknown binary into a signed,\n' >&2
    printf '  notarised DMG. Rebuild it: cd %s/apps/tauri && cargo tauri build --release\n' "$REF" >&2
    exit 1
fi
if [[ "$WRAPPER_SHA" == "$ZEROS" ]]; then
    bad "Ostler.app marker is the all-zero UNATTESTABLE sentinel."
    printf '  WRAPPER_FRONTEND_COMMIT=%s\n' "$WRAPPER_SHA" >&2
    printf '\n  apps/tauri/build.rs emits 40 zeros when git is unreachable at build\n' >&2
    printf '  time. The marker is well-formed but means "I do not know". It is NOT\n' >&2
    printf '  a commit. Rebuild from a checkout with a reachable .git, or pass\n' >&2
    printf '  WRAPPER_FRONTEND_COMMIT_OVERRIDE for a source-tarball build.\n' >&2
    exit 1
fi
if ! git -C "$REF" cat-file -e "${WRAPPER_SHA}^{commit}" 2>/dev/null; then
    bad "Ostler.app claims a commit that does not exist in the reference checkout."
    printf '  claims : %s\n  ref    : %s\n' "$WRAPPER_SHA" "$REF" >&2
    printf '\n  Either the bundle was built from an unpushed or discarded branch, or\n' >&2
    printf '  the reference checkout is not the repo it was built from. Both mean we\n' >&2
    printf '  cannot attest what is inside it.\n' >&2
    exit 1
fi
ok "bundle attests provenance: $WRAPPER_SHA ($(git -C "$REF" log -1 --format=%s "$WRAPPER_SHA" 2>/dev/null | cut -c1-56))"

# --------------------------------------------------------------------------
# (2) Frontend CONTENT parity against the daemon this cut ships.
# --------------------------------------------------------------------------
DAEMON_SHA="${OSTLER_DAEMON_COMMIT:-}"
if [[ -z "$DAEMON_SHA" ]]; then
    # WAS: fall back to `git -C "$REF" rev-parse HEAD` with a warn. That made
    # this check VACUOUS on every real cut, and the warn read as informational.
    #
    # The bundle is BUILT FROM the reference checkout, so its attested commit
    # and that clone's HEAD are normally the SAME COMMIT. The parity loop then
    # compares tree "<sha>:web" against tree "<sha>:web" -- the artefact
    # against itself -- and reports "frontend parity: identical commit". It
    # cannot fail. Measured on the shipping v1.0.33 cut (run 31998597024,
    # 05:39:50Z): wrapper 5b7efb00, daemon operand 5b7efb00, self-comparison.
    #
    # The question in this section's own heading is parity "against the daemon
    # this cut ships". A clone's HEAD is not that, and no default can guess it.
    # So refuse. An unmeasured parity is not a pass -- the same rule already
    # applied above to a missing sentinel and to a non-git reference checkout.
    cannot "OSTLER_DAEMON_COMMIT is not set, so this gate cannot determine which daemon this cut ships.

  Frontend parity is meaningless without it: the bundle is built from the
  reference checkout, so defaulting to that clone's HEAD compares the artefact
  against ITSELF and always agrees.

  The caller must say which daemon it ships. gui/Makefile resolves this from
  cuts/<tag>/cut.env DAEMON_COMMIT and exports it; if you are invoking this
  script directly, pass it the same way:

      OSTLER_DAEMON_COMMIT=<sha> $(basename "$0") <app> <reference-checkout>"
fi
git -C "$REF" cat-file -e "${DAEMON_SHA}^{commit}" 2>/dev/null \
    || cannot "daemon commit $DAEMON_SHA not found in $REF"

MISMATCH=0
for p in "${FRONTEND_PATHS[@]}"; do
    wt="$(git -C "$REF" rev-parse "${WRAPPER_SHA}:${p}" 2>/dev/null || echo MISSING)"
    dt="$(git -C "$REF" rev-parse "${DAEMON_SHA}:${p}"  2>/dev/null || echo MISSING)"
    if [[ "$wt" == MISSING || "$dt" == MISSING ]]; then
        bad "frontend path '$p' is absent at one side (wrapper=$wt daemon=$dt)"
        MISMATCH=1
    elif [[ "$wt" != "$dt" ]]; then
        bad "frontend CONTENT differs at '$p'"
        printf '    wrapper %s -> tree %s\n' "${WRAPPER_SHA:0:8}" "${wt:0:12}" >&2
        printf '    daemon  %s -> tree %s\n' "${DAEMON_SHA:0:8}"  "${dt:0:12}" >&2
        MISMATCH=1
    fi
done

if (( MISMATCH )); then
    printf '\n  This is the HR015 #225 class: daemon rebuilt fresh, wrapper not, DMG\n' >&2
    printf '  ships two different frontends and customer first-launch UI is broken.\n' >&2
    printf '  Fix: cd %s/apps/tauri && cargo tauri build --release  (from %s)\n' "$REF" "${DAEMON_SHA:0:8}" >&2
    exit 1
fi

if [[ "$WRAPPER_SHA" == "$DAEMON_SHA" ]]; then
    ok "frontend parity: identical commit ${WRAPPER_SHA:0:8}"
else
    N="$(git -C "$REF" rev-list --count "${WRAPPER_SHA}..${DAEMON_SHA}" 2>/dev/null || echo '?')"
    ok "frontend parity by CONTENT: wrapper ${WRAPPER_SHA:0:8} is $N commit(s) behind daemon ${DAEMON_SHA:0:8}, frontend identical"
fi

# --------------------------------------------------------------------------
# (3) Report the signing state BEFORE the seal absorbs it. Not fatal -- sealing
#     an ad-hoc bundle is what notarise-hub is for -- but it must be SAID at
#     step 5 rather than discovered never. Silence here is what turned a noisy
#     backstop into a silent pass.
# --------------------------------------------------------------------------
TEAM="$(codesign -dvv "$APP" 2>&1 | grep -o 'TeamIdentifier=.*' | cut -d= -f2 || true)"
if [[ -z "$TEAM" || "$TEAM" == "not set" ]]; then
    warn "bundle is AD-HOC signed (TeamIdentifier not set). notarise-hub will seal it"
    warn "with the Developer ID. Provenance above is why that is safe to do; without"
    warn "it, this cut would be laundering an unattested binary into a signed DMG."
else
    ok "bundle already carries TeamIdentifier=$TEAM"
fi
exit 0
