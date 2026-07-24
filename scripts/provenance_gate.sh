#!/usr/bin/env bash
# provenance_gate.sh -- CONTENT-provenance gate (CM051 canonical).
# ============================================================================
#
# THE HOLE THIS CLOSES
# The two existing cut gates each verify a DIFFERENT half of "did the merged fix
# actually ship", and a wiki fix can slip between them:
#
#   * verify_cut_freshness.sh  trusts the digest->source-SHA binding recorded by
#     hand in scripts/wiki_image_provenance.tsv. It compares that RECORDED sha to
#     CM044 main HEAD. It never checks that the digest was ACTUALLY built from the
#     recorded sha -- the image carries no org.opencontainers.image.revision
#     label (proven: `docker inspect ... .Config.Labels` == null), so the binding
#     is a trust-me row. A repin that records the RIGHT sha but bakes the WRONG
#     content passes freshness GREEN.
#
#   * verify_cut_provenance.sh  DOES grep inside the pinned image -- but only for
#     the fixes an operator remembered to hand-add as `wiki_image_grep` rows in
#     scripts/cut_markers.manifest. CM044 #144/#145/#146 have NO such rows, so
#     their content is unverified by that gate. "Forgot to add the marker" is the
#     same silent-drift class the whole gate suite exists to kill.
#
# THIS GATE drives content verification from the SAME declarative list that names
# the launch-blocking commits (scripts/required_fixes.tsv). For every required
# fix it proves, on the ACTUAL shipped artifact:
#
#   1. ANCESTRY  -- the artifact's recorded source SHA (ledger / vendor pin /
#                   daemon tag) is a descendant of (or equal to) the fix commit.
#                   Catches an HONEST stale binding (ledger row points pre-fix).
#   2. CONTENT   -- the fix's distinctive marker is ACTUALLY baked into the
#                   artifact (grep inside the pulled image / vendored tree / tag).
#                   Catches a FALSE binding (ledger records a post-fix sha but the
#                   image was built from older source) -- the class a merge-base
#                   check alone can NEVER see.
#   3. BINDING   -- (wiki images) if the image exposes a revision label, it MUST
#                   equal the ledger sha. Absent label -> loud WARN naming the
#                   recordability gap (see the build-stamp fix in PROVENANCE_GATE.md);
#                   the CONTENT proof still stands, so absence alone is not a RED.
#
# FAIL-CLOSED. Unresolvable provenance (no ledger row, image unpullable, docker
# down, unknown repo) is ALWAYS a RED -- never a silent pass.
#
# Wire it into the cut next to the sibling gates (gui/Makefile check-provenance).
#
# Usage:   scripts/provenance_gate.sh
# Env (all optional):
#   REQUIRED_FIXES_FILE    default: scripts/required_fixes.tsv
#   WIKI_PROVENANCE_FILE   default: scripts/wiki_image_provenance.tsv
#   INSTALL_SH             default: ../install.sh (the shipping pins)
#   GUI_MAKEFILE           default: ../gui/Makefile
#   CM044_DIR              local CM044 checkout for ancestry (default: ../../CM044 - PWG Personal Wiki)
#   OSTLER_ASSISTANT_DIR   local ostler-assistant checkout (default: ../../ostler-assistant)
#   PROV_GATE_ALLOW_PULL   1 (default) permit `docker pull` when a pinned digest
#                          is not present locally; 0 = local-only (pull miss = RED)
#   PROV_IMAGE_OVERRIDE    <artifact>=<ref>  force one artifact's image ref (test
#                          hook / negative-control demo). Repeatable via newline.
# Exit 0 = GREEN (every required fix proven present). Exit 1 = RED (stale/missing
# /unresolvable). British English throughout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CM051_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REQUIRED_FIXES_FILE="${REQUIRED_FIXES_FILE:-${SCRIPT_DIR}/required_fixes.tsv}"
WIKI_PROVENANCE_FILE="${WIKI_PROVENANCE_FILE:-${SCRIPT_DIR}/wiki_image_provenance.tsv}"
INSTALL_SH="${INSTALL_SH:-${CM051_DIR}/install.sh}"
GUI_MAKEFILE="${GUI_MAKEFILE:-${CM051_DIR}/gui/Makefile}"
CM044_DIR="${CM044_DIR:-${CM051_DIR}/../CM044 - PWG Personal Wiki}"
OSTLER_ASSISTANT_DIR="${OSTLER_ASSISTANT_DIR:-${CM051_DIR}/../ostler-assistant}"
PROV_GATE_ALLOW_PULL="${PROV_GATE_ALLOW_PULL:-1}"
PROV_IMAGE_OVERRIDE="${PROV_IMAGE_OVERRIDE:-}"

PASS=0; FAIL=0; WARN=0
green() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn()  { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
info()  { printf '          %s\n' "$1"; }

echo "=== Content-provenance gate (CM051) ==="
echo "required fixes:  ${REQUIRED_FIXES_FILE}"
echo "wiki ledger:     ${WIKI_PROVENANCE_FILE}"
echo "install.sh:      ${INSTALL_SH}"
echo

[[ -f "${REQUIRED_FIXES_FILE}" ]] || { echo "FATAL: required-fixes file not found at ${REQUIRED_FIXES_FILE}" >&2; exit 1; }

# --- helpers ---------------------------------------------------------------

# Map a repo key to a local git checkout for ancestry checks.
repo_dir_for() {
  case "$1" in
    CM044)             printf '%s' "${CM044_DIR}" ;;
    ostler-assistant)  printf '%s' "${OSTLER_ASSISTANT_DIR}" ;;
    CM051)             printf '%s' "${CM051_DIR}" ;;
    *)                 printf '' ;;
  esac
}

# Map a repo key to owner/repo for the GitHub-compare ancestry fallback.
repo_gh_for() {
  case "$1" in
    CM044)             printf 'andygmassey/CM044-PWG-Personal-Wiki' ;;
    ostler-assistant)  printf 'ostler-ai/ostler-assistant' ;;
    CM051)             printf 'andygmassey/CM051-Home-Hub-Installer' ;;
    *)                 printf '' ;;
  esac
}

# ancestor? <repo> <fix_commit> <candidate_sha>  -> 0 yes / 1 no / 2 cannot-check
is_ancestor() {
  local repo="$1" fix="$2" cand="$3" dir gh
  dir="$(repo_dir_for "$repo")"
  if [[ -n "$dir" && -d "${dir}/.git" ]]; then
    if git -C "$dir" cat-file -e "${fix}^{commit}" 2>/dev/null \
       && git -C "$dir" cat-file -e "${cand}^{commit}" 2>/dev/null; then
      git -C "$dir" merge-base --is-ancestor "$fix" "$cand" 2>/dev/null && return 0
      return 1
    fi
  fi
  # Fallback: live GitHub compare (base=fix, head=cand). behind_by==0 => cand
  # contains fix. Requires the `gh` andygmassey/ostler-ai account to be usable.
  gh="$(repo_gh_for "$repo")"
  [[ -z "$gh" ]] && return 2
  local acct=andygmassey
  case "$repo" in ostler-assistant) acct=ostler-ai ;; esac
  local out
  out="$(HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= \
        gh api --hostname github.com -H "Accept: application/vnd.github+json" \
        "repos/${gh}/compare/${fix}...${cand}" --jq '.behind_by' 2>/dev/null)"
  [[ -z "$out" ]] && return 2
  [[ "$out" == "0" ]] && return 0
  return 1
}

# Resolve a wiki image artifact -> "<digest>\t<ledger_sha>\t<image_ref>".
# Empty ledger_sha => no ledger row (fail-closed at call site).
resolve_wiki() { # artifact-key (wiki-compiler|wiki-site)
  local key="$1" digest ledger_sha ref override
  # Test / demo override wins.
  override="$(printf '%s\n' "${PROV_IMAGE_OVERRIDE}" | awk -F= -v k="$key" '$1==k{print $2; exit}')"
  digest="$(grep -m1 -E "image: ghcr.io/ostler-ai/ostler-${key}@sha256:" "${INSTALL_SH}" 2>/dev/null \
            | sed -E 's/.*@(sha256:[0-9a-f]+).*/\1/')"
  if [[ -n "$override" ]]; then
    ref="$override"
    # Try to lift the digest out of the override ref for the ledger lookup.
    case "$override" in *@sha256:*) digest="sha256:${override##*@sha256:}" ;; esac
  else
    ref="ghcr.io/ostler-ai/ostler-${key}@${digest}"
  fi
  ledger_sha=""
  if [[ -n "$digest" && -f "${WIKI_PROVENANCE_FILE}" ]]; then
    ledger_sha="$(awk -F'\t' -v k="$key" -v d="$digest" \
      '/^[[:space:]]*#/ {next} NF>=3 && $1==k && $2==d {print $3; exit}' "${WIKI_PROVENANCE_FILE}")"
  fi
  printf '%s\t%s\t%s' "$digest" "$ledger_sha" "$ref"
}

# Grep a distinctive marker inside a wiki image. Pulls if absent (unless
# PROV_GATE_ALLOW_PULL=0). Echoes: FOUND | MISSING | NOIMAGE | NODOCKER
image_has_marker() { # ref  marker  path
  local ref="$1" marker="$2" path="$3"
  command -v docker >/dev/null 2>&1 || { echo NODOCKER; return; }
  docker image inspect "$ref" >/dev/null 2>&1 || {
    if [[ "${PROV_GATE_ALLOW_PULL}" == "1" ]]; then
      HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= docker pull -q "$ref" >/dev/null 2>&1 || { echo NOIMAGE; return; }
    else
      echo NOIMAGE; return
    fi
  }
  if docker run --rm --entrypoint sh "$ref" -c "grep -rq -- '${marker}' '${path}' 2>/dev/null"; then
    echo FOUND
  else
    echo MISSING
  fi
}

# Read the image's recorded CM044 source revision (empty if none).
#
# CRITICAL: the generic org.opencontainers.image.revision label is NOT reliable
# for the CM044 binding -- a derived image inherits it from its BASE image. The
# ostler-wiki-site image, built FROM squidfunk/mkdocs-material, carries that
# project's revision (org.opencontainers.image.source = .../mkdocs-material),
# nothing to do with CM044. So we trust ONLY:
#   1. a dedicated ostler label  ai.ostler.wiki.source_revision  (the build-stamp
#      fix in PROVENANCE_GATE.md sets this to the CM044 sha), or
#   2. the OCI revision label BUT ONLY when org.opencontainers.image.source
#      actually references the CM044 repo.
# Anything else -> empty (treated as "no recorded binding" -> advisory WARN).
image_revision_label() { # ref
  local ref="$1" own oci src
  own="$(docker image inspect "$ref" \
    --format '{{index .Config.Labels "ai.ostler.wiki.source_revision"}}' 2>/dev/null | sed 's/<no value>//')"
  if [[ -n "$own" ]]; then printf '%s' "$own"; return; fi
  src="$(docker image inspect "$ref" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}' 2>/dev/null | sed 's/<no value>//')"
  case "$src" in
    *CM044*|*PWG-Personal-Wiki*)
      docker image inspect "$ref" \
        --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null | sed 's/<no value>//' ;;
    *) printf '' ;;   # base-image label or none -- not a CM044 binding
  esac
}

# Resolve the daemon pin -> ostler-assistant tag SHA (empty if unresolved).
daemon_tag_sha() {
  local mk sh pin dir cand
  mk="$(grep -m1 -E '^DAEMON_VERSION[[:space:]]*\?=' "${GUI_MAKEFILE}" 2>/dev/null \
        | sed -E 's/.*\?=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?).*/\1/')"
  sh="$(grep -m1 -E '^OSTLER_ASSISTANT_VERSION=' "${INSTALL_SH}" 2>/dev/null \
        | sed -E 's/.*:-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?)\}.*/\1/')"
  pin="${mk:-$sh}"; [[ -z "$pin" ]] && return
  dir="$(repo_dir_for ostler-assistant)"
  [[ -d "${dir}/.git" ]] || return
  for cand in "hub-v${pin}" "v${pin}" "${pin}"; do
    if git -C "$dir" rev-parse -q --verify "refs/tags/${cand}^{commit}" >/dev/null 2>&1; then
      git -C "$dir" rev-parse "refs/tags/${cand}^{commit}"; return
    fi
  done
}

# --- walk the required-fixes ledger ----------------------------------------
# Format (TAB-separated, 6 fields):
#   repo  fix_commit  artifact  content_marker  marker_path  description
# artifact is one of: wiki-compiler | wiki-site | daemon | vendor:<path>
# Rows beginning '#' are comments; '#TODO ' rows are surfaced as reminders.

while IFS=$'\t' read -r repo fix artifact marker mpath desc; do
  [[ -z "${repo:-}" ]] && continue
  case "$repo" in
    \#TODO*) info "TODO (not yet gated): ${fix} ${artifact} ${marker} ${desc}"; continue ;;
    \#*)     continue ;;
  esac
  fix="${fix// /}"; artifact="${artifact// /}"
  label="${repo} ${fix:0:7} -> ${artifact} (${desc})"

  case "$artifact" in
    wiki-compiler|wiki-site)
      IFS=$'\t' read -r digest ledger_sha ref < <(resolve_wiki "$artifact")
      if [[ -z "$digest" ]]; then
        red "${label} :: no pinned digest for ${artifact} in install.sh -- unresolvable provenance"; continue
      fi
      if [[ -z "$ledger_sha" ]]; then
        red "${label} :: digest ${digest:7:12} has NO row in wiki_image_provenance.tsv -- UNRECORDED provenance (fail-closed)"
        info "add a ledger row binding this digest to the CM044 source sha before cutting"; continue
      fi
      # 1) ANCESTRY: does the recorded sha contain the fix?
      is_ancestor "$repo" "$fix" "$ledger_sha"; anc=$?
      if [[ $anc -eq 1 ]]; then
        red "${label} :: ledger sha ${ledger_sha:0:12} does NOT contain ${fix:0:7} -- STALE BINDING"
        info "rebuild the ${artifact} image from a CM044 sha that includes ${fix:0:7}, re-pin + update the ledger row"
        continue
      elif [[ $anc -eq 2 ]]; then
        red "${label} :: cannot verify ancestry of ${fix:0:7} in ledger sha (no CM044 checkout + GitHub unreachable) -- fail-closed"
        continue
      fi
      # 2) CONTENT: is the fix actually baked into the pinned image?
      res="$(image_has_marker "$ref" "$marker" "$mpath")"
      case "$res" in
        NODOCKER) red "${label} :: docker unavailable -- cannot verify image content (fail-closed)"; continue ;;
        NOIMAGE)  red "${label} :: pinned image ${digest:7:12} not present locally and could not be pulled -- fail-closed"; continue ;;
        MISSING)
          red "${label} :: image ${digest:7:12} does NOT contain /${marker}/ under ${mpath} -- STALE IMAGE (ledger claims ${ledger_sha:0:12} but ${fix:0:7} content is absent)"
          info "the digest was NOT built from source containing ${fix:0:7}; rebuild the ${artifact} image from current CM044 main + re-pin + fix the ledger row"
          continue ;;
        FOUND) : ;;
      esac
      # 3) BINDING integrity (advisory today; enforceable once the build stamps a label).
      rev="$(image_revision_label "$ref")"
      if [[ -z "$rev" ]]; then
        warn "${label} :: content PROVEN present, but the image carries NO org.opencontainers.image.revision label -- the ledger sha is an unverifiable hand-recorded claim"
        info "stamp CM044 sha into the image at build time (see PROVENANCE_GATE.md) so this becomes an enforceable check next cut"
      elif ! printf '%s' "$ledger_sha" | grep -q "^${rev}" && ! printf '%s' "$rev" | grep -q "^${ledger_sha}"; then
        red "${label} :: image revision label ${rev:0:12} != ledger sha ${ledger_sha:0:12} -- ledger MISBINDING"
        continue
      fi
      green "${label} :: ${fix:0:7} content baked into ${digest:7:12}; ledger ${ledger_sha:0:12} contains ${fix:0:7}"
      ;;

    daemon)
      tag_sha="$(daemon_tag_sha)"
      if [[ -z "$tag_sha" ]]; then
        red "${label} :: could not resolve daemon pin -> ostler-assistant tag sha (need a local checkout) -- fail-closed"; continue
      fi
      is_ancestor "$repo" "$fix" "$tag_sha"; anc=$?
      if [[ $anc -ne 0 ]]; then
        red "${label} :: daemon tag ${tag_sha:0:12} does NOT contain ${fix:0:7} -- STALE DAEMON"; continue
      fi
      dir="$(repo_dir_for ostler-assistant)"
      if git -C "$dir" show "${tag_sha}:${mpath}" 2>/dev/null | grep -qE -- "${marker}"; then
        green "${label} :: ${fix:0:7} present in daemon tag ${tag_sha:0:12} (${mpath})"
      else
        red "${label} :: ${mpath} at daemon tag ${tag_sha:0:12} lacks /${marker}/ -- STALE DAEMON SOURCE"
      fi
      ;;

    vendor:*)
      vp="${artifact#vendor:}"
      tgt="${CM051_DIR}/${vp}"
      if [[ ! -e "$tgt" ]]; then
        red "${label} :: vendored path ${vp} missing -- STALE/absent vendor (fail-closed)"; continue
      fi
      if grep -rqE -- "${marker}" "$tgt" 2>/dev/null; then
        green "${label} :: /${marker}/ present in vendored ${vp}"
      else
        red "${label} :: /${marker}/ NOT in vendored ${vp} -- STALE VENDOR"
      fi
      ;;

    *)
      red "${label} :: unknown artifact class '${artifact}' -- fail-closed"
      ;;
  esac
done < "${REQUIRED_FIXES_FILE}"

echo
echo "=== Verdict ==="
echo "  ${PASS} pass / ${FAIL} fail / ${WARN} warn"
if [[ "${WARN}" -gt 0 ]]; then
  echo "  ${WARN} advisory WARN(s): a shipped fix is content-proven present but its"
  echo "  source binding is unverifiable from image metadata. Close with the build-time"
  echo "  revision-label stamp (PROVENANCE_GATE.md) so the binding is enforceable."
fi
if [[ "${FAIL}" -eq 0 ]]; then
  echo "  CONTENT-PROVENANCE GREEN -- every required fix is proven baked into its artifact."
  exit 0
else
  echo "  CONTENT-PROVENANCE RED -- ${FAIL} artifact(s) miss a required fix, or cannot be"
  echo "  verified. Rebuild + re-pin the RED artifact(s), then re-run. DO NOT CUT."
  exit 1
fi
