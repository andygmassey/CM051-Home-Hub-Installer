# scripts/box_walk_probes/lib/ical_pin.sh
# ============================================================================
# THE ICAL-SERVER PIN, PASSED TO THE WALK.
#
# no_l3_in_tool_results refuses to run unless EXPECTED_ICAL_SHA256 is set to the
# sha256 of the ical-server the cut ships. Nothing set it, so the probe was
# CANNOT-RUN on every walk that did not export it by hand. This file derives the
# pin from the cut itself and exports it, so run_box_walk.sh and every probe it
# runs see the same value.
#
# SOURCE OF THE PIN: vendor/cm041/assistant_api/ical-server.py at the cut's ref,
# cut/<OSTLER_CUT_VERSION>, read with git show (not the working tree, so a dirty
# checkout cannot change the pin). OSTLER_ICAL_PIN_REF overrides the ref.
#
# REFUSED, NOT GUESSED: a file that does not import pwg_privacy_readers is not
# the 134 ical-server and gets no pin. A missing ref leaves the pin unset, and the
# probe then reports CANNOT-RUN naming the unset variable. Nothing here ever
# writes a pin the file does not earn.
#
# Bash 3.2. Sourced, never executed.
# ============================================================================

# ical_pin_resolve <repo-root> <git-ref>
#   prints the sha256 of the file at <ref> (rc 0), or refuses on stderr (rc 78).
ical_pin_resolve() {
    local _repo="$1" _ref="$2" _src _sha
    _src="$(mktemp)"
    if ! git -C "${_repo}" show "${_ref}:vendor/cm041/assistant_api/ical-server.py" > "${_src}" 2>/dev/null; then
        rm -f "${_src}"
        printf 'ical pin: %s:vendor/cm041/assistant_api/ical-server.py is not readable\n' "${_ref}" >&2
        return 78
    fi
    if ! grep -q -F pwg_privacy_readers "${_src}"; then
        rm -f "${_src}"
        printf 'ical pin: %s does not import pwg_privacy_readers; refusing to pin a file that is not the 134 ical-server\n' "${_ref}" >&2
        return 78
    fi
    if command -v shasum >/dev/null 2>&1; then
        _sha="$(shasum -a 256 "${_src}" | awk '{print $1}')"
    else
        _sha="$(sha256sum "${_src}" | awk '{print $1}')"
    fi
    rm -f "${_src}"
    if ! printf '%s' "${_sha}" | grep -q -E '^[0-9a-f]{64}$'; then
        printf 'ical pin: could not compute a sha256 for %s\n' "${_ref}" >&2
        return 78
    fi
    printf '%s\n' "${_sha}"
}

# ical_pin_export <repo-root>
#   Exports EXPECTED_ICAL_SHA256. An already-set value is kept (an explicit
#   operator pin wins). Returns 0 in every case: an unset pin is the probe's
#   CANNOT-RUN to report, not this function's to hide.
ical_pin_export() {
    local _repo="$1" _ref _sha
    if [ -n "${EXPECTED_ICAL_SHA256:-}" ]; then
        export EXPECTED_ICAL_SHA256
        return 0
    fi
    _ref="${OSTLER_ICAL_PIN_REF:-}"
    if [ -z "${_ref}" ] && [ -n "${OSTLER_CUT_VERSION:-}" ]; then
        _ref="cut/${OSTLER_CUT_VERSION}"
    fi
    if [ -z "${_ref}" ]; then
        printf 'ical pin: no cut version and no OSTLER_ICAL_PIN_REF; EXPECTED_ICAL_SHA256 stays unset\n' >&2
        return 0
    fi
    if _sha="$(ical_pin_resolve "${_repo}" "${_ref}")"; then
        EXPECTED_ICAL_SHA256="${_sha}"
        export EXPECTED_ICAL_SHA256
        printf 'ical pin: EXPECTED_ICAL_SHA256 from %s (%s...)\n' "${_ref}" "$(printf '%s' "${_sha}" | cut -c1-16)" >&2
    else
        printf 'ical pin: EXPECTED_ICAL_SHA256 stays unset; no_l3_in_tool_results will report CANNOT-RUN\n' >&2
    fi
    return 0
}
