#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The wiki provenance checks must READ the image, never EXECUTE it -- and an
# extraction that did not happen must be CANNOT-RUN, never a verdict.
#
# WHAT THIS CAUGHT, 2026-08-15: it burned the v1.0.27 tag.
#
# Both wiki branches of verify_cut_provenance.sh ran:
#     docker run --rm --entrypoint sh "$ref" -c "grep -rq ..."
# The wiki images are arm64-ONLY on purpose -- enforced by
# tests/test_pinned_wiki_images_are_arm64_only.sh, because install.sh refuses an
# Intel Mac with ERR-01-ARCH-INTEL-NOT-SUPPORTED and no supported customer ever
# pulls an amd64 wiki image. cut.yml's preflight runs on ubuntu amd64. So the
# container never started:
#
#     exec /usr/bin/sh: exec format error
#
# and the two branches drew OPPOSITE conclusions from the same non-event:
#
#     wiki_image_grep   -> nothing found -> RED  "NOT FOUND -- STALE WIKI IMAGE"
#     wiki_image_absent -> nothing found -> GREEN "pattern is absent"
#
# The RED was a lie that sent an operator hunting a stale digest that did not
# exist -- the images were fine, and all six "missing" markers were provably
# present. THE GREEN WAS WORSE, because it was silent: an absence assertion
# passes on an empty result, so every wiki_image_absent row had been certifying
# an image it never opened for as long as these images have been arm64-only.
#
# A gate that is wrong in both directions is not a gate. This test pins the fix.
#
# WHAT IT ASSERTS, and each arm has to be able to fail:
#   1. a marker that IS present passes                 (the gate can see content)
#   2. a marker that CANNOT exist fails                (it is not just saying yes)
#   3. wiki_image_absent RED-flags a pattern that IS present  (mirror polarity)
#   4. a path that is NOT in the image is CANNOT-RUN, not pass, on BOTH kinds
#      (the vacuous-pass killer: this is the arm that would have caught v1.0.27)
#   5. the file count is reported, so a zero-file extraction cannot masquerade
#      as a successful read of nothing
#
# British English; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

GATE="scripts/verify_cut_provenance.sh"
PASS=0; FAIL=0
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$1"; }

command -v docker >/dev/null 2>&1 || {
  echo "SKIP: docker unavailable -- this test is about docker behaviour" >&2; exit 0; }
docker info >/dev/null 2>&1 || {
  echo "SKIP: docker daemon not reachable" >&2; exit 0; }

# The image under test is whatever install.sh actually pins, so this test
# follows the cut rather than a hardcoded digest that would rot.
REF="$(grep -m1 -E 'image: ghcr\.io/[a-z0-9-]+/ostler-wiki-compiler@sha256:' install.sh \
        | sed -E 's/.*image:[[:space:]]*//' | tr -d ' ')"
[[ -n "$REF" ]] || { echo "SKIP: no wiki-compiler digest pinned in install.sh" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_gate() { # manifest-body -> stdout
  printf '%s\n' "$1" > "$TMP/manifest"
  CUT_MARKER_MANIFEST="$TMP/manifest" \
  OSTLER_PROVENANCE_ONLY_KINDS=wiki_image_grep,wiki_image_absent \
    bash "$GATE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

echo "=== wiki provenance: extract, never exec ==="
echo "image under test: ${REF##*@}"
echo

# --- 1. POSITIVE: a marker that is genuinely in the image -------------------
out="$(run_gate 'wiki_image_grep|wiki-compiler:/app/compiler|_render_settling_panel|positive control: this string IS in the shipped compiler')"
if grep -q 'PASS.*_render_settling_panel' <<<"$out"; then
  ok "a present marker PASSES (the gate can read image content at all)"
else
  bad "a present marker did not pass -- the gate cannot read the image"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

# --- 2. NEGATIVE: a marker that cannot possibly exist -----------------------
# Without this arm, arm 1 only proves the gate says yes, not that it discriminates.
out="$(run_gate 'wiki_image_grep|wiki-compiler:/app/compiler|zzz-this-string-cannot-exist-in-any-image-9f3a|negative control: must NOT be found')"
if grep -q 'FAIL.*zzz-this-string-cannot-exist' <<<"$out"; then
  ok "an impossible marker FAILS (the gate discriminates, it does not rubber-stamp)"
else
  bad "an impossible marker did NOT fail -- the gate passes everything"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

# --- 3. MIRROR POLARITY: absent-check must fire on something present --------
out="$(run_gate 'wiki_image_absent|wiki-compiler:/app/compiler|_render_settling_panel|mirror control: asserting absence of a string that IS present must go RED')"
if grep -q 'FAIL.*IS PRESENT' <<<"$out"; then
  ok "wiki_image_absent RED-flags a pattern that is present (mirror polarity works)"
else
  bad "wiki_image_absent did not fire on a present pattern -- absence checks are vacuous"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

# --- 4. THE ARM THAT WOULD HAVE CAUGHT v1.0.27 ------------------------------
# A path that is not in the image cannot be extracted. That is CANNOT-RUN on
# BOTH kinds. The absent-kind is the dangerous one: "nothing extracted" reads
# as "pattern is gone" unless the gate refuses to answer.
out="$(run_gate 'wiki_image_grep|wiki-compiler:/no/such/path/in/this/image|anything|extraction must fail, and that is not a content verdict')"
if grep -qE 'CANNOT|could not EXTRACT' <<<"$out"; then
  ok "unextractable path is CANNOT-RUN on wiki_image_grep, not a content verdict"
else
  bad "unextractable path did not report CANNOT-RUN on wiki_image_grep"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

out="$(run_gate 'wiki_image_absent|wiki-compiler:/no/such/path/in/this/image|anything|THE VACUOUS-PASS KILLER: must not pass just because nothing was read')"
if grep -qE 'CANNOT|could not EXTRACT' <<<"$out"; then
  ok "unextractable path is CANNOT-RUN on wiki_image_absent (NOT a silent green)"
elif grep -q 'PASS' <<<"$out"; then
  bad "REGRESSION: wiki_image_absent PASSED on an image it never read -- this is the v1.0.27 bug"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
else
  bad "wiki_image_absent gave neither CANNOT-RUN nor PASS on an unextractable path"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

# --- 5. the extraction itself must be evidenced -----------------------------
out="$(run_gate 'wiki_image_grep|wiki-compiler:/app/compiler|_render_settling_panel|count control')"
if grep -qE '\[[0-9]+ files extracted\]' <<<"$out" && ! grep -qE '\[0 files extracted\]' <<<"$out"; then
  n="$(grep -oE '\[[0-9]+ files extracted\]' <<<"$out" | head -1)"
  ok "the extraction is evidenced by a non-zero file count ${n}"
else
  bad "no non-zero file count reported -- a zero-file extraction could pass unnoticed"
  # Print the ROW, not the verdict tail. The tail is generic boilerplate that
  # names ostler-assistant on every cannot-run, which sent the first diagnosis
  # of this test's own CI failure in entirely the wrong direction.
  printf '%s\n' "$out" | grep -E 'wiki_image_(grep|absent)|docker:|EXTRACT' | head -4 | sed 's/^/        /'
fi

echo
printf 'EXAMINED: %s assertion(s), %s passed, %s failed\n' "$((PASS+FAIL))" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "test_wiki_provenance_extracts_without_exec: FAIL"
  exit 1
fi
echo "test_wiki_provenance_extracts_without_exec: PASS"
exit 0
