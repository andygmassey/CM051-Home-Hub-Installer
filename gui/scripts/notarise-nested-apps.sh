#!/usr/bin/env bash
# ============================================================================
# notarise-nested-apps.sh -- give every nested .app its OWN notarisation ticket.
#
# WHY THIS EXISTS (HR015 #221, closed properly 2026-08-06)
# -------------------------------------------------------
# install.sh COPIES the nested bundles OUT of OstlerInstaller.app and into
# /Applications on the customer Mac. Once copied out, the outer installer's
# ticket no longer covers them: Gatekeeper looks for a ticket stapled to
# Ostler.app / OstlerAssistant.app themselves. With no ticket and no network
# (cafe, plane, firewall-blocked LAN) the FIRST launch is blocked outright.
#
# The old chain could not satisfy this. `sign-app` resealed the outer bundle
# with `codesign --force --deep`, which RE-SIGNS every nested bundle and so
# strips any ticket stapled beforehand; stapling afterwards mutates a SEALED
# Contents/CodeResources and breaks `codesign --verify --deep --strict` on the
# outer. Nested bundles were therefore structurally unable to hold a staple,
# and the gate was left permanently at 2/3 (or 1/3).
#
# 2026-08-06 fix, in two halves:
#   1. `--deep` dropped from the outer reseal in sign-app (every nested Mach-O
#      is signed explicitly by then, and `--verify --deep --strict` proves it
#      on every run). Apple deprecated --deep for signing for this reason.
#   2. THIS script, run after the last mutation of the nested bundles and
#      BEFORE the outer reseal, so the outer signature seals the stapled state.
#
# ORDERING IS LOAD-BEARING. Run it too early and a later re-sign invalidates
# the ticket; too late and the staple breaks the outer seal. It belongs at the
# tail of sign-app, after the python / daemon / mecard signing steps and
# immediately before "Re-signing outer .app".
#
# WHY NOT NOTARISE THE HUB BEFORE ASSEMBLY
# ----------------------------------------
# Two separate steps mutate Ostler.app after `cargo tauri build` notarises it:
# stage-payload injects Contents/Resources/ostler-payload/, and
# embed-sparkle.sh adds Sparkle.framework + SU* Info.plist keys and re-signs
# `--force --deep`. xcodebuild's archive then deep-re-signs it a third time on
# copy-in. Each changes the CDHash, so any ticket minted earlier is dead. The
# only CDHash worth notarising is the one that ships -- the copy sitting inside
# $APP_PATH at this point in the chain.
#
# BEHAVIOUR
# ---------
# Per nested bundle, cheapest-first:
#   1. `stapler validate` passes  -> already ticketed, skip (idempotent re-run)
#   2. `stapler staple` succeeds  -> Apple already holds a ticket for this
#                                    CDHash (e.g. a previous cut submitted an
#                                    identical bundle), just embed it
#   3. otherwise                  -> ditto-zip, `notarytool submit --wait`,
#                                    staple, and fail CLOSED if it still won't
#
# Then re-validates every bundle and fails closed. A missing bundle is a hard
# error, not a skip: a DMG without both nested apps is broken (verify-dmg-
# contents catches it later, but failing here saves a notarisation round-trip).
#
# USAGE
#   notarise-nested-apps.sh <app-path> <notary-profile> <work-dir>
#
# EXIT CODES
#   0  every nested .app carries a valid stapled ticket
#   1  a bundle is missing, notarisation failed, or a staple would not take
#   2  usage error
#
# TESTABILITY
# Both Apple tools are routed through env vars so the ladder in
# scripts/tests/test_notarise_nested_apps.sh can inject shims and prove the
# script FAILS CLOSED without needing a real notary round-trip:
#   STAPLER_BIN   (default: xcrun stapler)
#   NOTARYTOOL_BIN(default: xcrun notarytool)
# ============================================================================
set -euo pipefail

STAPLER_BIN="${STAPLER_BIN:-xcrun stapler}"
NOTARYTOOL_BIN="${NOTARYTOOL_BIN:-xcrun notarytool}"

APP_PATH="${1:-}"
NOTARY_PROFILE="${2:-}"
WORK_DIR="${3:-${TMPDIR:-/tmp}}"

if [[ -z "${APP_PATH}" || -z "${NOTARY_PROFILE}" ]]; then
    echo "usage: $(basename "$0") <app-path> <notary-profile> [work-dir]" >&2
    exit 2
fi
[[ -d "${APP_PATH}" ]] || { echo "ERROR: not a directory: ${APP_PATH}" >&2; exit 2; }

# Bundles that install.sh copies OUT to /Applications, relative to APP_PATH.
# Anything listed here MUST end up individually stapled or the cut fails.
# (Sparkle's nested Updater.app is deliberately absent: it is never copied out
# on its own, it has no standalone ticket, and verify_stapling.sh's -maxdepth 6
# walk does not reach it.)
NESTED_RELS=(
    "Contents/Resources/Ostler.app"
    "Contents/Resources/assistant-agent/OstlerAssistant.app"
)

mkdir -p "${WORK_DIR}"

printf '\n[STEP] Notarising + stapling nested .apps (each needs its OWN ticket -- #221)\n'

for rel in "${NESTED_RELS[@]}"; do
    app="${APP_PATH}/${rel}"

    if [[ ! -d "${app}" ]]; then
        echo "" >&2
        echo "ERROR: nested bundle missing: ${rel}" >&2
        echo "  Expected at: ${app}" >&2
        echo "  Every DMG must ship BOTH nested apps -- install.sh copies them to" >&2
        echo "  /Applications. A missing bundle means an earlier stage silently" >&2
        echo "  skipped (check OSTLER_APP_PATH for the Hub, stage-daemon for the" >&2
        echo "  daemon) -- see the 2026-05-21 Hub-less DMG incident." >&2
        exit 1
    fi

    if ${STAPLER_BIN} validate "${app}" >/dev/null 2>&1; then
        printf '  [SKIP]   already ticketed + stapled: %s\n' "${rel}"
        continue
    fi

    # Apple may already hold a ticket for this exact CDHash -- codesign is
    # deterministic over identical content + identity + options + entitlements
    # (the CMS timestamp is not part of the cdhash), so a re-signed-but-
    # unchanged bundle keeps the CDHash it was notarised under. Try the free
    # lookup before spending a submission.
    if ${STAPLER_BIN} staple "${app}" >/dev/null 2>&1; then
        printf '  [OK]     ticket already at Apple for this CDHash, stapled: %s\n' "${rel}"
        continue
    fi

    printf '  [SUBMIT] no ticket for current CDHash -- notarising %s\n' "${rel}"
    zip_path="${WORK_DIR}/nested-notary-$(basename "${app}" .app).zip"
    rm -f "${zip_path}"
    # Apple-blessed archive form for notary submissions. `zip -r` loses
    # resource forks / xattrs and has caused "unable to build submission".
    ditto -c -k --sequesterRsrc --keepParent "${app}" "${zip_path}"

    if ! ${NOTARYTOOL_BIN} submit "${zip_path}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait; then
        echo "" >&2
        echo "ERROR: notarisation FAILED for ${rel}." >&2
        echo "  Find the submission ID above and read the per-binary reasons:" >&2
        echo "    xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}" >&2
        echo "  Most common cause: a nested Mach-O without the hardened runtime" >&2
        echo "  (CX-20 python3.11, CX-124 daemon, BW2-1 ostler-mecard all had it)." >&2
        rm -f "${zip_path}"
        exit 1
    fi
    rm -f "${zip_path}"

    if ! ${STAPLER_BIN} staple "${app}"; then
        echo "" >&2
        echo "ERROR: stapler failed on ${rel} after a SUCCESSFUL notarisation." >&2
        echo "  That means the bundle changed between submission and staple." >&2
        echo "  Nothing may mutate a nested bundle at this point in sign-app." >&2
        exit 1
    fi
    printf '  [OK]     notarised + stapled: %s\n' "${rel}"
done

# Fail closed. verify_stapling.sh re-checks this from inside the finished DMG,
# but that is ~15 minutes and one full package + notarise-dmg later; catching
# it here keeps the feedback loop short.
printf '\n[STEP] Verifying every nested ticket took\n'
for rel in "${NESTED_RELS[@]}"; do
    app="${APP_PATH}/${rel}"
    if ${STAPLER_BIN} validate "${app}" >/dev/null 2>&1; then
        printf '  [VERIFIED] %s\n' "${rel}"
    else
        echo "" >&2
        echo "ERROR: ${rel} is STILL unstapled after this step." >&2
        echo "  verify-stapling (#221) would fail the cut. DO NOT SHIP." >&2
        exit 1
    fi
done

echo "[OK] every nested .app carries its own stapled ticket."
