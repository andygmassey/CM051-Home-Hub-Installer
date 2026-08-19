#!/usr/bin/env bash
# lib_image_extract.sh -- read files OUT of a container image without RUNNING it.
# ============================================================================
#
# WHY THIS EXISTS AS A SHARED LIBRARY RATHER THAN A LOCAL HELPER. IT COST TWO TAGS.
#
# The wiki images are arm64-ONLY on purpose -- tests/test_pinned_wiki_images_are_arm64_only.sh
# enforces it, because install.sh refuses an Intel Mac with
# ERR-01-ARCH-INTEL-NOT-SUPPORTED and no supported customer ever pulls an amd64
# wiki image. cut.yml's preflight runs on ubuntu amd64. So
#
#     docker run --entrypoint sh <pinned-image> -c 'grep ...'
#
# dies with "exec format error", the grep reads NOTHING, and the caller then
# reports a verdict about content it never saw. Presence-checks go falsely RED.
# Absence-checks go falsely GREEN, which is worse because it is silent.
#
#   v1.0.27 burned on scripts/verify_cut_provenance.sh.
#   The fix went in there, the class was declared closed, and v1.0.28 burned on
#   scripts/provenance_gate.sh -- the twin, seen in the first search and then
#   not revisited. A third file, tests/test_pinned_wiki_image_has_design_system.sh,
#   carried three more sites and was found only by a repo-wide predicate.
#
# One copy, one place, so the next caller cannot inherit the bug by writing its
# own. tests/test_no_gate_execs_a_pinned_image.sh fails the build if anyone
# reintroduces the exec shape anywhere in the tree.
#
# --platform IS REQUIRED. docker resolves an image for the HOST platform unless
# told otherwise, so on amd64 an arm64-only image has nothing to match and the
# create fails before a byte is read. Naming the platform tells docker which
# manifest to instantiate, and instantiating is not executing -- no instruction
# from the image runs either way. linux/arm64 is the default here and is safe
# precisely because arm64-only is already an enforced invariant; if that ever
# changes deliberately, that gate goes red FIRST and points here.
#
# A ZERO-FILE EXTRACTION IS CANNOT-RUN, NEVER A PASS. That is the whole bug in
# one line: "extracted nothing" and "read it and the pattern was absent" must
# never be the same answer.
#
# British English; " -- " not em-dashes.

# Sets IMG_EXTRACT_DIR / IMG_EXTRACT_N / IMG_EXTRACT_ERR. Returns 0 only when
# files were actually written. Caller owns rm -rf "$IMG_EXTRACT_DIR".
#
#   image_extract_path <image-ref> <path-in-image> [platform]
IMG_EXTRACT_DIR=""; IMG_EXTRACT_N=0; IMG_EXTRACT_ERR=""
image_extract_path() {
    local ref="$1" path="$2" platform="${3:-linux/arm64}" cid out rc
    IMG_EXTRACT_DIR=""; IMG_EXTRACT_N=0; IMG_EXTRACT_ERR=""

    if ! command -v docker >/dev/null 2>&1; then
        IMG_EXTRACT_ERR="docker is not installed on this host"
        return 1
    fi

    IMG_EXTRACT_DIR="$(mktemp -d 2>/dev/null)" || {
        IMG_EXTRACT_ERR="could not create a temp dir on this host"
        IMG_EXTRACT_DIR=""; return 1; }

    if ! cid="$(docker create --platform "$platform" "$ref" 2>&1)"; then
        IMG_EXTRACT_ERR="docker create --platform ${platform} failed: $(printf '%s' "$cid" | tr '\n' ' ')"
        rm -rf "$IMG_EXTRACT_DIR"; IMG_EXTRACT_DIR=""; return 1
    fi

    out="$(docker cp "${cid}:${path}" "$IMG_EXTRACT_DIR/" 2>&1)"; rc=$?
    docker rm -f "$cid" >/dev/null 2>&1

    if [[ $rc -ne 0 ]]; then
        IMG_EXTRACT_ERR="docker cp ${cid:0:12}:${path} rc=${rc}: $(printf '%s' "$out" | tr '\n' ' ')"
        rm -rf "$IMG_EXTRACT_DIR"; IMG_EXTRACT_DIR=""; return 1
    fi

    IMG_EXTRACT_N="$(find "$IMG_EXTRACT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${IMG_EXTRACT_N:-0}" -eq 0 ]]; then
        IMG_EXTRACT_ERR="docker cp reported success but extracted 0 files from ${path} (container ${cid:0:12}) -- an empty extraction proves nothing about content"
        rm -rf "$IMG_EXTRACT_DIR"; IMG_EXTRACT_DIR=""; return 1
    fi
    return 0
}

# Pull an image for a NAMED platform, fail-closed. Same reason as above: a bare
# `docker pull` resolves for the host and cannot find an arm64-only manifest on
# amd64. Echoes docker's error on failure so the caller can name it.
#   image_pull_platform <image-ref> [platform]
image_pull_platform() {
    local ref="$1" platform="${2:-linux/arm64}"
    docker pull -q --platform "$platform" "$ref" 2>&1
}
