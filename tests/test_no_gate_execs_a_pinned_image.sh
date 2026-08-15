#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# REPO-WIDE: no gate may EXECUTE a pinned image in order to READ a file from it.
#
# WHY THIS IS REPO-WIDE AND NOT PER-FILE. IT COST TWO TAGS.
#
# The wiki images are arm64-ONLY on purpose (tests/test_pinned_wiki_images_are_arm64_only.sh
# enforces it, because install.sh refuses an Intel Mac outright). cut.yml's
# preflight runs on ubuntu amd64. Any gate that does
#
#     docker run --entrypoint sh <pinned-image> -c 'grep ...'
#
# therefore gets "exec format error", reads nothing, and then REPORTS A VERDICT
# ABOUT CONTENT IT NEVER SAW. Presence-checks go falsely RED; absence-checks go
# falsely GREEN, which is worse because it is silent.
#
#   v1.0.27 burned on scripts/verify_cut_provenance.sh.
#   That file was fixed, the class was declared closed, and v1.0.28 burned on
#   scripts/provenance_gate.sh -- the twin, found in the very first search and
#   then not revisited.
#
# BOTH TIMES THE RIGHT GREP WAS RUN AND THEN SCOPED WRONG: once to a single
# file while reporting a verdict about the repo. So the fix is not another
# careful reading. It is a predicate that asks the WHOLE TREE, every run,
# and prints what it examined.
#
# WHAT COUNTS, AND WHAT DELIBERATELY DOES NOT
#
# The signature is `--entrypoint`, because that is the shape that means "start
# a shell inside this image and have it read something out for me". It is the
# only reason to override an image's entrypoint in a gate.
#
# RUNNING A SERVICE IS NOT THIS, and is deliberately allowed:
#   * tests/test_wiki_tailnet_gate.sh runs $NGINX_IMAGE (a MULTI-ARCH nginx
#     digest lifted from install.sh) to validate nginx.conf and to stand up
#     network aliases. It needs the thing running, and nginx runs on amd64.
#   * tests/test_v1010_store_front_proxy.sh runs nginx:1.27-alpine and an image
#     the test BUILDS ITSELF ("ostler-storeproxy-selftest-$$"). Neither is a
#     pinned arm64-only wiki image.
# Both were adjudicated rather than swept: checked what their refs resolve to,
# found them multi-arch or locally built, and left them alone on purpose.
#
# TO READ A FILE OUT OF AN IMAGE, use docker create + docker cp (see
# image_extract_path in scripts/verify_cut_provenance.sh). It never executes a
# single instruction from the image, so architecture stops being a variable,
# and it can report CANNOT-RUN when the extraction genuinely fails instead of
# guessing.
#
# British English; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "=== repo-wide: no gate execs a pinned image to read it ==="

# Everything tracked by git, so a stray file in the working tree cannot hide a
# site and an untracked scratch copy cannot manufacture one.
mapfile -t FILES < <(git ls-files '*.sh' '*.py' '*.yml' '*.yaml' 2>/dev/null)
echo "files examined: ${#FILES[@]}"
if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "REFUSING: git ls-files returned nothing -- the predicate examined no files, which is not a pass" >&2
  exit 2
fi

# POSITIVE CONTROL, on every run. If the scanner cannot find `docker run` AT ALL
# in a tree that certainly contains it, the scanner is broken and a zero result
# means nothing. This is the check that a zero denominator is not read as clean.
ALL_RUNS=0
for f in "${FILES[@]}"; do
  n="$(grep -cE 'docker[[:space:]]+run' "$f" 2>/dev/null || true)"
  ALL_RUNS=$((ALL_RUNS + ${n:-0}))
done
echo "control -- 'docker run' mentions anywhere (must be > 0): ${ALL_RUNS}"
if [[ "$ALL_RUNS" -eq 0 ]]; then
  echo "REFUSING: the scanner found no 'docker run' anywhere, so it cannot be trusted to find the bad shape" >&2
  exit 2
fi

# THE PREDICATE: a LIVE (non-comment) `docker run` carrying `--entrypoint`.
VIOLATIONS=0
VIOL_LINES=()
for f in "${FILES[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOL_LINES+=("${f}:${hit}")
  done < <(grep -nE 'docker[[:space:]]+run[^|]*--entrypoint' "$f" 2>/dev/null \
             | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done

echo "EXAMINED: ${#FILES[@]} tracked file(s); ${ALL_RUNS} 'docker run' mention(s); ${VIOLATIONS} live exec-to-read site(s)"

if [[ "$VIOLATIONS" -gt 0 ]]; then
  echo
  echo "FAIL -- these EXECUTE a pinned image to read a file out of it:"
  for v in "${VIOL_LINES[@]}"; do echo "    ${v}" | cut -c1-160; done
  echo
  echo "On an amd64 runner an arm64-only image cannot exec, so each of these"
  echo "reports a verdict about content it never read: presence-checks go"
  echo "falsely RED, absence-checks go falsely GREEN."
  echo "Use docker create + docker cp (image_extract_path) instead."
  exit 1
fi

echo "PASS: no gate executes a pinned image to read it"
exit 0
