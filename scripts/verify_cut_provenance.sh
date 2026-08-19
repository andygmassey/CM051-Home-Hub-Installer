#!/usr/bin/env bash
# verify_cut_provenance.sh -- PREFLIGHT cut-provenance gate (CM051 canonical).
#
# Proves that every fix MERGED to a source main is actually present in the
# about-to-be-cut artefacts (this CM051 working tree + the daemon tag the cut
# pins). BLOCKS the cut on any stale or missing component.
#
# This is the wall between "merged" and "shipped". It exists because v0.4.8
# shipped a dead-chat daemon (pin said 0.4.8 but tag v0.4.8 predated the cure
# commit) and a stale-vendored Doctor (#171 merged but not re-vendored). Both
# were merged to mains; neither made the cut. This gate catches that class.
#
# It is wired into BOTH cut paths so it cannot be skipped:
#   - gui/Makefile  `package` target depends on `check-provenance` (the DMG)
#   - release.sh    runs it as a preflight (the curl|bash tarball)
#
# Marker ledger:  scripts/cut_markers.manifest  (add ONE line per new blocker).
#
# Usage:  scripts/verify_cut_provenance.sh
# Env:    OSTLER_ASSISTANT_DIR  override the ostler-assistant checkout location
#         (default: ../ostler-assistant relative to this repo).
# Exit 0 = GREEN (safe to cut). Exit 1 = drift/missing (DO NOT CUT).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CM051_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Overridable so the cannot-run path can be exercised by the wrapper self-test
# (tests/test_cut_gate_wrappers.sh). Default is unchanged.
MANIFEST="${CUT_MARKER_MANIFEST:-${SCRIPT_DIR}/cut_markers.manifest}"
ASSISTANT_DIR="${OSTLER_ASSISTANT_DIR:-${CM051_DIR}/../ostler-assistant}"

# WHICH KINDS TO RUN. Empty = all, which is the operator default.
#
# The wiki_image_* kinds need docker + registry access. The `cut` job is
# macos-26 and has neither, so on run 31694278038 all ELEVEN of them reported
# "docker unavailable" and the gate announced "11 stale/missing component(s)"
# having examined none. The preflight job is ubuntu-latest and HAS docker.
#
# So the work is split by what each environment can honestly prove, exactly as
# cut.yml already splits the rollforward gate. Every check still runs; it runs
# where it can actually look.
ONLY_KINDS="${OSTLER_PROVENANCE_ONLY_KINDS:-}"
SKIP_KINDS="${OSTLER_PROVENANCE_SKIP_KINDS:-}"

PASS=0
FAIL=0
CANNOT=0
SKIPPED=0
green() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
# A check whose INPUT is absent has observed nothing. Saying FAIL there claims
# a merged fix is stale, which is a defect this gate did not see. The script
# already made exactly this argument for a missing manifest (see the exit-2
# comment below); it simply never carried it to the missing-checkout branches,
# and on 2026-08-13 run 31693253364 that walled the cut with
#   "assistant_tag_grep ... :: ostler-assistant not at .../gui/../../ostler-assistant"
# -- a hosted runner reporting the absence of a sibling checkout as STALE
# DAEMON SOURCE. Same shape as the OSTLER_APP_PATH default that blocked eight
# cuts.
cannot(){ printf '  \033[33mCANNOT\033[0m %s\n' "$1"; CANNOT=$((CANNOT+1)); }
info()  { printf '        %s\n' "$1"; }

echo "=== Cut-provenance preflight (CM051) ==="
echo "CM051:     ${CM051_DIR}"
echo "assistant: ${ASSISTANT_DIR}"
echo "manifest:  ${MANIFEST}"

# exit 2, NOT 1. An absent manifest means this gate examined nothing; exit 1
# would tell the caller a merged fix is stale, which is a defect the gate
# never looked for. The wrapper (gui/Makefile check-provenance) branches on 2.
[[ -f "${MANIFEST}" ]] || {
  echo "CANNOT RUN: manifest not found at ${MANIFEST} -- nothing was checked." >&2
  exit 2
}

# --- read the daemon pin the cut will actually ship ---
# The DMG fetches the daemon via gui/Makefile DAEMON_VERSION; the curl|bash
# tarball uses install.sh OSTLER_ASSISTANT_VERSION. They must agree. We read
# the Makefile (the DMG's real source) and cross-check install.sh.
MK_PIN="$(grep -m1 -E '^DAEMON_VERSION[[:space:]]*\?=' "${CM051_DIR}/gui/Makefile" 2>/dev/null \
  | sed -E 's/.*\?=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?).*/\1/')"
SH_PIN="$(grep -m1 -E '^OSTLER_ASSISTANT_VERSION=' "${CM051_DIR}/install.sh" 2>/dev/null \
  | sed -E 's/.*:-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?)\}.*/\1/')"
DAEMON_PIN="${MK_PIN:-${SH_PIN}}"
echo "daemon pin: Makefile=${MK_PIN:-<none>}  install.sh=${SH_PIN:-<none>}"
echo

if [[ -n "${MK_PIN}" && -n "${SH_PIN}" && "${MK_PIN}" != "${SH_PIN}" ]]; then
  red "daemon pin MISMATCH: gui/Makefile=${MK_PIN} vs install.sh=${SH_PIN} -- the DMG and tarball would ship different daemons"
  info "align DAEMON_VERSION (gui/Makefile) and OSTLER_ASSISTANT_VERSION (install.sh)"
fi

# Resolve the assistant tag the pin maps to (try v<pin>, <pin>, hub-v<pin>).
DAEMON_TAG=""
if [[ -n "${DAEMON_PIN}" ]] && git -C "${ASSISTANT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "${ASSISTANT_DIR}" fetch origin --tags -q 2>/dev/null
  for cand in "v${DAEMON_PIN}" "${DAEMON_PIN}" "hub-v${DAEMON_PIN}"; do
    if git -C "${ASSISTANT_DIR}" rev-parse -q --verify "refs/tags/${cand}" >/dev/null 2>&1; then
      DAEMON_TAG="${cand}"; break
    fi
  done
fi

# --- read an image's files WITHOUT executing it ------------------------------
#
# WHY EXTRACT RATHER THAN RUN (v1.0.27, and it burned a tag to find out).
#
# Both wiki branches below used to do:
#     docker run --rm --entrypoint sh "$ref" -c "grep -rq ..."
# The wiki images are arm64-ONLY -- deliberately, and enforced by
# tests/test_pinned_wiki_images_are_arm64_only.sh, because install.sh refuses an
# Intel Mac outright with ERR-01-ARCH-INTEL-NOT-SUPPORTED and no supported
# customer ever pulls an amd64 wiki image. cut.yml's preflight job runs on
# ubuntu amd64. So `docker run` died with "exec /usr/bin/sh: exec format error",
# every grep returned nothing, and the two branches drew OPPOSITE conclusions
# from the same non-event:
#
#   wiki_image_grep   -> nothing found -> RED "NOT FOUND -- STALE WIKI IMAGE"
#   wiki_image_absent -> nothing found -> GREEN "pattern is absent"
#
# The RED was a lie that sent an operator hunting a stale digest that did not
# exist. The GREEN was worse and quieter: every absent-assertion has been
# passing on an image it never opened for as long as these images have been
# arm64-only, which makes those greens worthless rather than merely wrong.
#
# `docker create` + `docker cp` never executes a single instruction from the
# image, so architecture stops mattering entirely. This is not a workaround for
# the amd64 runner; it removes the coupling. Measured on the v1.0.27 images:
# 104 files extracted from an arm64-only image on an arm64 host with no exec,
# and the runner log for the burnt tag shows docker CREATING the container fine
# and failing only at exec -- which is the half we no longer need.
#
# Sets EXTRACT_DIR / EXTRACT_N / EXTRACT_ERR. Returns 0 only when files were
# actually written. A ZERO-FILE EXTRACTION IS CANNOT-RUN, NEVER A PASS: it is
# indistinguishable from a successful extraction of nothing, and that confusion
# is the exact bug this function exists to kill.
EXTRACT_DIR=""; EXTRACT_N=0; EXTRACT_ERR=""
image_extract_path() { # ref  path
  local ref="$1" path="$2" cid out rc
  EXTRACT_DIR=""; EXTRACT_N=0; EXTRACT_ERR=""
  EXTRACT_DIR="$(mktemp -d 2>/dev/null)" || {
    EXTRACT_ERR="could not create a temp dir on this host"; EXTRACT_DIR=""; return 1; }
  # --platform IS REQUIRED, and leaving it off is what failed the first CI run
  # of this very function. On an amd64 runner docker tries to resolve the image
  # for the HOST platform; these images are arm64-only, so it has nothing to
  # match and the create fails before any file is read. Naming the platform
  # explicitly tells docker which manifest to instantiate, and instantiating is
  # not executing -- no instruction from the image runs either way.
  #
  # linux/arm64 is HARDCODED ON PURPOSE and is safe precisely because it is
  # already an enforced invariant: tests/test_pinned_wiki_images_are_arm64_only.sh
  # fails the cut if any pinned wiki digest is anything else. If that invariant
  # is ever deliberately changed, that gate goes red FIRST and points here.
  if ! cid="$(docker create --platform linux/arm64 "$ref" 2>&1)"; then
    EXTRACT_ERR="docker create --platform linux/arm64 failed: $(printf '%s' "$cid" | tr '\n' ' ')"
    rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""; return 1
  fi
  out="$(docker cp "${cid}:${path}" "$EXTRACT_DIR/" 2>&1)"; rc=$?
  docker rm -f "$cid" >/dev/null 2>&1
  if [[ $rc -ne 0 ]]; then
    EXTRACT_ERR="docker cp ${cid:0:12}:${path} rc=${rc}: $(printf '%s' "$out" | tr '\n' ' ')"
    rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""; return 1
  fi
  EXTRACT_N="$(find "$EXTRACT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${EXTRACT_N:-0}" -eq 0 ]]; then
    EXTRACT_ERR="docker cp reported success but extracted 0 files from ${path} (container ${cid:0:12}) -- an empty extraction proves nothing about content"
    rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""; return 1
  fi
  return 0
}

# --- walk the manifest ---
while IFS='|' read -r kind target pattern desc; do
  [[ -z "${kind:-}" || "${kind}" == \#* ]] && continue
  kind="$(echo "${kind}" | tr -d ' ')"
  # Filter BEFORE dispatch. Skips are counted and named at the end -- a check
  # that did not run must never be invisible, or the verdict silently narrows.
  if [[ -n "${ONLY_KINDS}" && ",${ONLY_KINDS}," != *",${kind},"* ]]; then
    SKIPPED=$((SKIPPED+1)); continue
  fi
  if [[ -n "${SKIP_KINDS}" && ",${SKIP_KINDS}," == *",${kind},"* ]]; then
    SKIPPED=$((SKIPPED+1)); continue
  fi

  case "${kind}" in
    daemon_tag)
      sha="${target// /}"
      if [[ -z "${DAEMON_PIN}" ]]; then
        red "daemon_tag ${sha} :: could not read daemon pin -- cannot verify"; continue
      fi
      if ! git -C "${ASSISTANT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        cannot "daemon_tag ${sha} :: ostler-assistant checkout absent at ${ASSISTANT_DIR} -- NOT a stale daemon, this check observed nothing (set OSTLER_ASSISTANT_DIR)"; continue
      fi
      if [[ -z "${DAEMON_TAG}" ]]; then
        red "daemon_tag ${sha} :: no tag for pin '${DAEMON_PIN}' in ostler-assistant (${desc})"
        info "the cut ships pin ${DAEMON_PIN} but no v${DAEMON_PIN} tag exists to build from"
        continue
      fi
      if git -C "${ASSISTANT_DIR}" merge-base --is-ancestor "${sha}" "${DAEMON_TAG}" 2>/dev/null; then
        green "daemon_tag ${sha} in ${DAEMON_TAG} (${desc})"
      else
        red "daemon_tag ${sha} NOT in ${DAEMON_TAG} -- STALE DAEMON (${desc})"
        info "pin=${DAEMON_PIN} -> tag ${DAEMON_TAG} predates the fix; cut a fresh tag containing ${sha} and bump the pin"
      fi
      ;;
    vendor_file)
      if [[ -f "${CM051_DIR}/${target}" ]]; then
        green "vendor_file ${target} (${desc})"
      else
        red "vendor_file ${target} MISSING -- STALE VENDOR (${desc})"
        info "graft from source-of-truth main before cutting"
      fi
      ;;
    vendor_grep)
      tgt="${CM051_DIR}/${target}"
      if [[ ! -e "${tgt}" ]]; then
        red "vendor_grep ${target} :: path missing (${desc})"; continue
      fi
      if grep -rqE -- "${pattern}" "${tgt}" 2>/dev/null; then
        green "vendor_grep ${target} ~ /${pattern}/ (${desc})"
      else
        red "vendor_grep ${target} ~ /${pattern}/ NOT FOUND -- STALE VENDOR (${desc})"
        info "graft from source-of-truth main before cutting"
      fi
      ;;
    assistant_tag_grep)
      # Verify a daemon-side (ostler-assistant) source fix is present in the
      # exact tag the daemon tarball is built from. Gates UI / gateway fixes
      # that have no vendored footprint -- e.g. the Hub web bundle, rebuilt
      # from source at cut time. `target` = path inside ostler-assistant;
      # `pattern` = regex that must appear in that file at the pinned tag.
      if ! git -C "${ASSISTANT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        cannot "assistant_tag_grep ${target} :: ostler-assistant checkout absent at ${ASSISTANT_DIR} -- NOT stale daemon source, this check observed nothing (${desc})"; continue
      fi
      if [[ -z "${DAEMON_TAG}" ]]; then
        red "assistant_tag_grep ${target} :: no tag for pin '${DAEMON_PIN}' to inspect (${desc})"; continue
      fi
      if git -C "${ASSISTANT_DIR}" show "${DAEMON_TAG}:${target}" 2>/dev/null | grep -qE -- "${pattern}"; then
        green "assistant_tag_grep ${DAEMON_TAG}:${target} ~ /${pattern}/ (${desc})"
      else
        red "assistant_tag_grep ${DAEMON_TAG}:${target} ~ /${pattern}/ NOT FOUND -- STALE DAEMON SOURCE (${desc})"
        info "the daemon tag predates this fix; re-tag from a main HEAD that contains it"
      fi
      ;;
    wiki_image_grep)
      # Verify a fix is baked into the PINNED wiki Docker image digest the cut
      # actually ships (install.sh `image: ghcr.io/...@sha256:...`). This closes
      # the hole that made wiki staleness a manual grep: the gate pulls the
      # exact digest and greps inside it. target = `<image-key>:<path-in-image>`
      # where image-key is wiki-site or wiki-compiler; pattern = regex to find.
      # FAIL-CLOSED, but as CANNOT-RUN rather than RED: a host that cannot
      # verify the image still cannot pass, and it no longer claims the image
      # is stale. Those are different facts and only one of them was observed.
      img_key="${target%%:*}"; img_path="${target#*:}"
      # NAMESPACE-AGNOSTIC ON PURPOSE. This grep was pinned to
      # "ghcr.io/ostler-ai/", but install.sh ships
      # "ghcr.io/creativemachines-ai/" -- so it never matched, `ref` came back
      # empty, and EVERY wiki_image_grep / wiki_image_absent row reported
      # "no pinned digest in install.sh" against an install.sh that has always
      # carried one. All 11 wiki rows in cut_markers.manifest had therefore
      # NEVER ONCE been evaluated. It failed CLOSED, which is the only reason
      # this was not a shipping defect -- but a gate that cannot run is not
      # coverage, it is the appearance of coverage.
      #
      # verify_cut_freshness.sh and provenance_gate.sh were both already fixed
      # this way (see their equivalent comments); this was the third copy of the
      # same hardcoded-namespace rot. Match ANY owner and let the digest plus
      # the provenance ledger bind the artefact, never a hand-typed org name.
      ref="$(grep -m1 -E "image: ghcr\.io/[a-z0-9-]+/ostler-${img_key}@sha256:" "${CM051_DIR}/install.sh" 2>/dev/null | sed -E 's/.*image:[[:space:]]*//' | tr -d ' ')"
      if [[ -z "${ref}" ]]; then
        red "wiki_image_grep ${img_key} :: no pinned digest in install.sh (${desc})"; continue
      fi
      if ! command -v docker >/dev/null 2>&1; then
        cannot "wiki_image_grep ${img_key} :: docker unavailable -- this check examined nothing, it did NOT find the image stale (${desc})"
        info "run the preflight on the cut host (docker + registry access required)"
        continue
      fi
      # THE PULL RESULT IS A VERDICT INPUT, NOT NOISE.
      #
      # This was `docker pull -q "${ref}" >/dev/null 2>&1` with the status
      # discarded. A pull that fails for registry auth, a rate limit or a
      # network blip then fell through to `docker run` failing, and the else
      # branch below announced "NOT FOUND -- STALE WIKI IMAGE" about an image
      # it had never opened. Fail-closed is correct; naming a defect that was
      # never observed is not.
      if ! pull_err="$(docker pull -q --platform linux/arm64 "${ref}" 2>&1)"; then
        cannot "wiki_image_grep ${img_key} :: cannot pull ${ref##*@} -- this check examined nothing (${desc})"
        printf '%s\n' "$pull_err" | sed 's/^/        docker: /'
        continue
      fi
      # EXTRACT, never execute -- see image_extract_path() for why.
      if ! image_extract_path "${ref}" "${img_path}"; then
        cannot "wiki_image_grep ${img_key} :: could not EXTRACT ${img_path} from ${ref##*@} -- ${EXTRACT_ERR} (${desc})"
        info "this says NOTHING about the image content: no file was read, so the pattern was neither found nor missing"
        continue
      fi
      if grep -rq -- "${pattern}" "${EXTRACT_DIR}" 2>/dev/null; then
        green "wiki_image_grep ${img_key}@${ref##*@} :${img_path} ~ /${pattern}/ [${EXTRACT_N} files extracted] (${desc})"
      else
        red "wiki_image_grep ${img_key} :${img_path} ~ /${pattern}/ NOT FOUND in ${EXTRACT_N} extracted file(s) -- STALE WIKI IMAGE (${desc})"
        info "rebuild + repin the ${img_key} digest from current CM044 main before cutting"
      fi
      rm -rf "${EXTRACT_DIR}"; EXTRACT_DIR=""
      ;;
    wiki_image_absent)
      # The mirror of wiki_image_grep: assert a pattern is GONE from the pinned
      # image and stays gone.
      #
      # Some things are removed on purpose and must never come back. The faked
      # compile-time settling card is the case that forced this: Andy walked
      # THREE DMGs with a static, fabricated progress card on the wiki homepage
      # -- "That is a STATIC card. It's faked... remove the fucking thing
      # entirely! I don't EVER want to see it again."
      #
      # A presence-only manifest cannot express that. Worse, the rows asserting
      # the old card's PRESENCE survived its deletion and turned the provenance
      # gate red against a correct image -- a gate that fails on the right
      # answer teaches people to ignore it.
      img_key="${target%%:*}"; img_path="${target#*:}"
      # NAMESPACE-AGNOSTIC ON PURPOSE -- see the note at wiki_image_grep above.
      ref="$(grep -m1 -E "image: ghcr\.io/[a-z0-9-]+/ostler-${img_key}@sha256:" "${CM051_DIR}/install.sh" 2>/dev/null | sed -E 's/.*image:[[:space:]]*//' | tr -d ' ')"
      if [[ -z "${ref}" ]]; then
        red "wiki_image_absent ${img_key} :: no pinned digest in install.sh (${desc})"; continue
      fi
      if ! command -v docker >/dev/null 2>&1; then
        cannot "wiki_image_absent ${img_key} :: docker unavailable -- this check examined nothing, it did NOT find the pattern present (${desc})"
        continue
      fi
      # THE PULL RESULT IS A VERDICT INPUT, NOT NOISE.
      #
      # This was `docker pull -q "${ref}" >/dev/null 2>&1` with the status
      # discarded. A pull that fails for registry auth, a rate limit or a
      # network blip then fell through to `docker run` failing, and the else
      # branch below announced "NOT FOUND -- STALE WIKI IMAGE" about an image
      # it had never opened. Fail-closed is correct; naming a defect that was
      # never observed is not.
      if ! pull_err="$(docker pull -q --platform linux/arm64 "${ref}" 2>&1)"; then
        cannot "wiki_image_absent ${img_key} :: cannot pull ${ref##*@} -- this check examined nothing (${desc})"
        printf '%s\n' "$pull_err" | sed 's/^/        docker: /'
        continue
      fi
      # EXTRACT, never execute. THIS BRANCH IS WHY IT MATTERS MOST: an absence
      # assertion passes on an empty result, so a container that never started
      # used to read as proof the pattern was gone. Extraction failure must be
      # CANNOT-RUN here, or the check certifies an image it never opened.
      if ! image_extract_path "${ref}" "${img_path}"; then
        cannot "wiki_image_absent ${img_key} :: could not EXTRACT ${img_path} from ${ref##*@} -- ${EXTRACT_ERR} (${desc})"
        info "this check examined nothing; it did NOT establish that the pattern is absent"
        continue
      fi
      if grep -rq -- "${pattern}" "${EXTRACT_DIR}" 2>/dev/null; then
        red "wiki_image_absent ${img_key} :${img_path} ~ /${pattern}/ IS PRESENT in ${EXTRACT_N} extracted file(s) -- a deliberately removed component came back (${desc})"
        info "this pattern was deleted on purpose; find what reintroduced it before cutting"
      else
        green "wiki_image_absent ${img_key}@${ref##*@} :${img_path} !~ /${pattern}/ [${EXTRACT_N} files extracted] (${desc})"
      fi
      rm -rf "${EXTRACT_DIR}"; EXTRACT_DIR=""
      ;;
    *)
      red "unknown manifest kind '${kind}'"
      ;;
  esac
done < "${MANIFEST}"

echo
echo "=== Verdict ==="
echo "  ${PASS} pass / ${FAIL} fail / ${CANNOT} could-not-run / ${SKIPPED} not-run-here"
if [[ "${SKIPPED}" -gt 0 ]]; then
  echo "  ${SKIPPED} check(s) were filtered out of THIS invocation"
  echo "    only=${ONLY_KINDS:-<all>}  skip=${SKIP_KINDS:-<none>}"
  echo "  They are not verified by this run. Another invocation must cover them."
fi
# THREE outcomes, and the order matters. A real FAIL outranks a cannot-run,
# because a fix proven stale is worse news than a check that did not execute.
if [[ "${FAIL}" -gt 0 ]]; then
  echo "  PROVENANCE RED -- ${FAIL} stale/missing component(s). DO NOT CUT."
  echo "  Fix each FAIL (graft vendor / re-tag daemon), re-run, ship only on green."
  exit 1
fi
if [[ "${CANNOT}" -gt 0 ]]; then
  echo "  PROVENANCE COULD NOT RUN -- ${CANNOT} check(s) had no input to examine."
  echo "  This is NOT a stale component. Nothing has been shown to be wrong; the"
  echo "  gate was simply unable to look, so it refuses to certify. Fail-closed,"
  echo "  exit 2, distinct from the exit 1 that names a defect."
  echo "  On a hosted runner this usually means the ostler-assistant checkout is"
  echo "  absent: supply it and set OSTLER_ASSISTANT_DIR."
  exit 2
fi
echo "  PROVENANCE GREEN -- every merged fix is present. Safe to cut."
exit 0
