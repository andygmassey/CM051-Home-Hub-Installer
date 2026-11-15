#!/usr/bin/env bash
# lib_walk_cm019_bundle.sh -- ttywalk.sh --from-dmg exports the artefact's
# cm019 bundle for the WHOLE run.
#
# WHY. The preference seed runs on the DRIVER, from the main checkout, so the
# staged-payload lookup in box_walk_probes/lib/preference_seed.sh (which keys
# on where that library lives) cannot match, and the DMG is mounted under
# mktemp, not /Volumes. v1.0.115 walk: seed CANNOT-RUN "no cm019 bundle".
# Exporting OSTLER_CM019_BUNDLE (the payload root, which the seed descends
# into cm019_preferences) makes every probe that needs it find the same one.
#
# A MISSING bundle is not papered over: the variable is UNSET, so a value
# inherited from an earlier run cannot stand in for this artefact, and the
# seed reads CANNOT-RUN with its own reason. Bash 3.2 safe.

# $1 = payload root (<app>/Contents/Resources of the mounted DMG)
walk_export_cm019_bundle() {
    _wcb_root="${1:-}"
    if [ -n "${_wcb_root}" ] && [ -f "${_wcb_root}/install.sh" ] \
        && [ -d "${_wcb_root}/cm019_preferences" ]; then
        if [ -n "${OSTLER_CM019_BUNDLE:-}" ] && [ "${OSTLER_CM019_BUNDLE}" != "${_wcb_root}" ]; then
            printf '   cm019:   replacing inherited OSTLER_CM019_BUNDLE=%s with the mounted artefact\n' "${OSTLER_CM019_BUNDLE}"
        fi
        OSTLER_CM019_BUNDLE="${_wcb_root}"
        export OSTLER_CM019_BUNDLE
        printf '   cm019:   OSTLER_CM019_BUNDLE=%s (mounted artefact)\n' "${OSTLER_CM019_BUNDLE}"
        return 0
    fi
    unset OSTLER_CM019_BUNDLE
    printf '   cm019:   no cm019_preferences in the mounted payload (%s); OSTLER_CM019_BUNDLE unset, the preference seed will read CANNOT-RUN\n' "${_wcb_root:-<none>}"
    return 1
}
