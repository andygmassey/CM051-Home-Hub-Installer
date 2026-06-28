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
MANIFEST="${SCRIPT_DIR}/cut_markers.manifest"
ASSISTANT_DIR="${OSTLER_ASSISTANT_DIR:-${CM051_DIR}/../ostler-assistant}"

PASS=0
FAIL=0
green() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info()  { printf '        %s\n' "$1"; }

echo "=== Cut-provenance preflight (CM051) ==="
echo "CM051:     ${CM051_DIR}"
echo "assistant: ${ASSISTANT_DIR}"
echo "manifest:  ${MANIFEST}"

[[ -f "${MANIFEST}" ]] || { echo "FATAL: manifest not found at ${MANIFEST}" >&2; exit 1; }

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
if [[ -n "${DAEMON_PIN}" && -d "${ASSISTANT_DIR}/.git" ]]; then
  git -C "${ASSISTANT_DIR}" fetch origin --tags -q 2>/dev/null
  for cand in "v${DAEMON_PIN}" "${DAEMON_PIN}" "hub-v${DAEMON_PIN}"; do
    if git -C "${ASSISTANT_DIR}" rev-parse -q --verify "refs/tags/${cand}" >/dev/null 2>&1; then
      DAEMON_TAG="${cand}"; break
    fi
  done
fi

# --- walk the manifest ---
while IFS='|' read -r kind target pattern desc; do
  [[ -z "${kind:-}" || "${kind}" == \#* ]] && continue
  kind="$(echo "${kind}" | tr -d ' ')"
  case "${kind}" in
    daemon_tag)
      sha="${target// /}"
      if [[ -z "${DAEMON_PIN}" ]]; then
        red "daemon_tag ${sha} :: could not read daemon pin -- cannot verify"; continue
      fi
      if [[ ! -d "${ASSISTANT_DIR}/.git" ]]; then
        red "daemon_tag ${sha} :: ostler-assistant not found at ${ASSISTANT_DIR} (set OSTLER_ASSISTANT_DIR)"; continue
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
      if [[ ! -d "${ASSISTANT_DIR}/.git" ]]; then
        red "assistant_tag_grep ${target} :: ostler-assistant not at ${ASSISTANT_DIR} (${desc})"; continue
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
      # FAIL-CLOSED: if docker is unavailable or the pull fails, this is RED, so
      # a cut host that cannot verify the image cannot pass.
      img_key="${target%%:*}"; img_path="${target#*:}"
      ref="$(grep -m1 -E "image: ghcr.io/ostler-ai/ostler-${img_key}@sha256:" "${CM051_DIR}/install.sh" 2>/dev/null | sed -E 's/.*image:[[:space:]]*//' | tr -d ' ')"
      if [[ -z "${ref}" ]]; then
        red "wiki_image_grep ${img_key} :: no pinned digest in install.sh (${desc})"; continue
      fi
      if ! command -v docker >/dev/null 2>&1; then
        red "wiki_image_grep ${img_key} :: docker unavailable -- cannot verify image (${desc})"
        info "run the preflight on the cut host (docker + registry access required)"
        continue
      fi
      docker pull -q "${ref}" >/dev/null 2>&1
      if docker run --rm --entrypoint sh "${ref}" -c "grep -rq -- '${pattern}' '${img_path}' 2>/dev/null"; then
        green "wiki_image_grep ${img_key}@${ref##*@} :${img_path} ~ /${pattern}/ (${desc})"
      else
        red "wiki_image_grep ${img_key} :${img_path} ~ /${pattern}/ NOT FOUND -- STALE WIKI IMAGE (${desc})"
        info "rebuild + repin the ${img_key} digest from current CM044 main before cutting"
      fi
      ;;
    *)
      red "unknown manifest kind '${kind}'"
      ;;
  esac
done < "${MANIFEST}"

echo
echo "=== Verdict ==="
echo "  ${PASS} pass / ${FAIL} fail"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "  PROVENANCE GREEN -- every merged fix is present. Safe to cut."
  exit 0
else
  echo "  PROVENANCE RED -- ${FAIL} stale/missing component(s). DO NOT CUT."
  echo "  Fix each FAIL (graft vendor / re-tag daemon), re-run, ship only on green."
  exit 1
fi
