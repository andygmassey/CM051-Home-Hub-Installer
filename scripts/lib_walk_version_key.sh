#!/usr/bin/env bash
# lib_walk_version_key.sh -- a walk record must be findable under either spelling.
#
# CM051 #1744. `post_walk_qa.sh:362` names the record from the string it was
# TOLD: `RECORD="${WALK_DIR}/${CUT_VERSION}.tsv"`. `verify_walk_record.sh:86`
# rebuilds the path from ITS OWN caller's argument and then string-compares the
# version field at :124. Nothing normalises the leading `v`.
#
# So a walk filed as `1.0.71` is invisible to a gate asked about `v1.0.71`, and
# the gate reports
#
#     [walk-gate] NO WALK RECORD for v1.0.71.
#
# for a walk that actually happened. It HAS happened: two records for the same
# release, 13 minutes apart, `walks/1.0.71.tsv` and `walks/v1.0.71.tsv`, each
# internally consistent and each satisfying the gate for its own spelling only.
#
# 🗿 THE FAILURE DIRECTION IS SAFE AND THE MESSAGE IS NOT. It refuses to promote
# rather than promoting something bad, so nothing ships wrongly. What it costs is
# a walk cycle, and a walk is the single most expensive thing in this pipeline.
# "NO WALK RECORD" reads as *the walk never happened* rather than *I looked under
# the other name*, which is what sends somebody to re-run it.
#
# WHAT THIS DOES NOT DO. It normalises ONE leading `v`, and nothing else. A
# record of a genuinely different version is still refused: that check is the
# reason the gate exists ("a stale v1.0.38 record would clear the gate for a
# build it never touched"), and loosening it would be a worse bug than the one
# being fixed. `v` is stripped only when followed by a digit, so a name that
# merely starts with v is untouched.

# walk_version_key <string> -> the version without a leading v
walk_version_key() {
    local _s="${1:-}"
    case "$_s" in
        v[0-9]*) printf '%s\n' "${_s#v}" ;;
        *)       printf '%s\n' "$_s" ;;
    esac
}

# walk_versions_agree <a> <b>  -> 0 if they name the same version, 1 otherwise
walk_versions_agree() {
    [ "$(walk_version_key "${1:-}")" = "$(walk_version_key "${2:-}")" ]
}

# walk_record_path <walk_dir> <version>
#   Three outcomes, because "I found two" is not "I found one":
#     rc 0 + path   exactly one spelling exists
#     rc 1          neither exists -- caller says NO WALK RECORD
#     rc 2          BOTH exist -- ambiguous, caller must refuse rather than pick
#   This widens the search; it does not invent a record and does not choose
#   between two that disagree.
walk_record_path() {
    local _dir="${1:-}" _v="${2:-}" _key _alt
    _key="$(walk_version_key "$_v")"
    if [ "$_v" = "$_key" ]; then _alt="v${_key}"; else _alt="$_key"; fi

    # 🔴 AMBIGUITY IS A REFUSAL, NOT A PREFERENCE. Widening the search created a
    # hazard the old code did not have: before, asking for v1.0.73 could only
    # ever read v1.0.73.tsv. Now it might read 1.0.73.tsv. #1744 documented two
    # records for ONE release, 13 minutes apart, with DIFFERENT content -- so if
    # both spellings exist, picking either would make the verdict depend on how
    # the caller happened to type it. Return 2 and let the caller say so.
    if [ -f "${_dir}/${_v}.tsv" ] && [ -f "${_dir}/${_alt}.tsv" ]; then
        return 2
    fi

    if [ -f "${_dir}/${_v}.tsv" ]; then
        printf '%s\n' "${_dir}/${_v}.tsv"
        return 0
    fi
    if [ -f "${_dir}/${_alt}.tsv" ]; then
        printf '%s\n' "${_dir}/${_alt}.tsv"
        return 0
    fi
    return 1
}

# walk_record_paths_tried <walk_dir> <version> -> both candidates, for the
# refusal message. A gate that says what it looked for is one somebody can act
# on; the old message named a single path and read as "it never happened".
walk_record_paths_tried() {
    local _dir="${1:-}" _v="${2:-}" _key _alt
    _key="$(walk_version_key "$_v")"
    if [ "$_v" = "$_key" ]; then _alt="v${_key}"; else _alt="$_key"; fi
    printf '%s\n%s\n' "${_dir}/${_v}.tsv" "${_dir}/${_alt}.tsv"
}
