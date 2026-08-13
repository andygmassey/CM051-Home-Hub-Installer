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

PASS=0; FAIL=0; WARN=0; CANNOT=0; SKIPPED=0
green() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn()  { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
info()  { printf '          %s\n' "$1"; }
# A CHECK THAT COULD NOT RUN IS NOT A DEFECT (2026-08-13).
#
# Every RED this gate emitted on run 31696154993 was a check that never looked.
# Four CM044 rows reported "ledger sha 0bdc1d16de7b does NOT contain <fix> --
# STALE BINDING" -- a specific, actionable, WRONG accusation that sends whoever
# reads it off to rebuild and re-pin three perfectly good wiki images. The
# images were fine; the gate could not read the repo.
#
# `cannot` keeps the gate fail-closed -- the cut still stops -- while saying the
# true thing: nothing is known about this artefact. Rebuilding is the wrong
# remedy for a missing credential, and a gate that names the wrong remedy is
# worse than one that stays silent, because it gets obeyed.
cannot() { printf '  \033[33mCANNOT-RUN\033[0m  %s\n' "$1"; CANNOT=$((CANNOT+1)); }
skipped() { printf '  \033[36mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED+1)); }

echo "=== Content-provenance gate (CM051) ==="
echo "required fixes:  ${REQUIRED_FIXES_FILE}"
echo "wiki ledger:     ${WIKI_PROVENANCE_FILE}"
echo "install.sh:      ${INSTALL_SH}"
echo

# exit 2, NOT 1 -- see the sibling note in verify_cut_provenance.sh. Without
# the ledger there is no list of fixes to look for, so no artifact has been
# found wanting. The wrapper (check-provenance-content) branches on 2.
[[ -f "${REQUIRED_FIXES_FILE}" ]] || {
  echo "CANNOT RUN: required-fixes file not found at ${REQUIRED_FIXES_FILE} -- nothing was checked." >&2
  exit 2
}

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

# Resolve a GitHub credential for one account. Same shape, same remedy, as
# token_for() in verify_cut_freshness.sh -- env secret first (the only form that
# works on a hosted runner), then the account token the cut already carries for
# ostler-ai, then the operator's multi-account gh CLI.
#
# `gh auth token --user X` is a LOCAL gh concept. It resolves on Andy's Mac and
# NEVER on a runner, which is precisely how this gate came to run its GitHub
# fallback with whatever GH_TOKEN the workflow happened to export -- see the
# note on is_ancestor below.
token_for() {
  local acct="$1" envname cur key
  key="_PROVTOK_$(printf '%s' "$acct" | tr -c 'A-Za-z0-9' '_')"
  eval "cur=\${$key:-}"
  if [[ -z "$cur" ]]; then
    envname="OSTLER_GH_TOKEN_$(printf '%s' "$acct" | tr 'a-z-' 'A-Z_')"
    eval "cur=\${$envname:-}"
    if [[ -z "$cur" && "$acct" == "ostler-ai" ]]; then cur="${OSTLER_RELEASES_TOKEN:-}"; fi
    if [[ -z "$cur" ]]; then cur="$(gh auth token --user "$acct" 2>/dev/null)"; fi
    eval "$key=\$cur"
  fi
  printf '%s' "$cur"
}

# ancestor? <repo> <fix_commit> <candidate_sha>  -> 0 yes / 1 no / 2 cannot-check
#
# WHY THE ANSWER IS PARSED AS A NUMBER, AND WHY THE TOKEN IS CHOSEN (2026-08-13).
#
# This function produced FOUR false REDs on run 31696154993, and the reason is
# worth stating exactly because it has now bitten three times in one day.
#
# It used to end:
#
#     out="$(gh api ... --jq '.behind_by' 2>/dev/null)"
#     [[ -z "$out" ]] && return 2        # "unauthorised gives empty" -- FALSE
#     [[ "$out" == "0" ]] && return 0
#     return 1                           # <- every auth failure landed here
#
# `gh api` DOES NOT APPLY --jq TO A NON-2XX RESPONSE. It prints the raw error
# body to STDOUT:
#
#     {"message":"Bad credentials","documentation_url":"...","status":"401"}
#
# That is 112 bytes, so `-z` is false, so `return 2` was UNREACHABLE on any HTTP
# error, and every unauthorised lookup returned 1 -- "does NOT contain" -- which
# the caller renders as "STALE BINDING". The gate accused three CM044 images of
# being stale because it could not read the repository. Measured, with a control
# on a repo that genuinely does not exist: both emit a JSON body, never empty.
#
# Same mechanism as `--jq '.size'` reporting absent files as present earlier
# today. The lesson generalises: an error body is not empty, so emptiness can
# never be the test for "the call failed". Parse the ANSWER SHAPE instead -- a
# behind_by is a non-negative integer and nothing else is an answer.
#
# The credential half: the cut step exports GH_TOKEN=secrets.GITHUB_TOKEN, which
# is scoped to CM051 and cannot read andygmassey/CM044-PWG-Personal-Wiki. A bare
# `gh api` inherits it and 404s. OSTLER_GH_TOKEN_ANDYGMASSEY is already mapped
# into that step for the freshness gate, so the credential was present and this
# gate simply never asked for it.
is_ancestor() {
  local repo="$1" fix="$2" cand="$3" dir gh
  dir="$(repo_dir_for "$repo")"
  if [[ -n "$dir" ]] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$dir" cat-file -e "${fix}^{commit}" 2>/dev/null \
       && git -C "$dir" cat-file -e "${cand}^{commit}" 2>/dev/null; then
      git -C "$dir" merge-base --is-ancestor "$fix" "$cand" 2>/dev/null && return 0
      return 1
    fi
  fi
  # Fallback: live GitHub compare (base=fix, head=cand). behind_by==0 => cand
  # contains fix.
  gh="$(repo_gh_for "$repo")"
  [[ -z "$gh" ]] && return 2
  local acct=andygmassey
  case "$repo" in ostler-assistant) acct=ostler-ai ;; esac
  local tok out attempt
  tok="$(token_for "$acct")"
  [[ -z "$tok" ]] && return 2          # no credential -> cannot look, not "stale"
  for attempt in 1 2; do               # one retry for a transient 5xx / rate blip
    out="$(HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= \
          GH_TOKEN="$tok" GH_HOST=github.com \
          gh api --hostname github.com -H "Accept: application/vnd.github+json" \
          "repos/${gh}/compare/${fix}...${cand}" --jq '.behind_by' 2>/dev/null)"
    # ONLY a bare non-negative integer is an answer. An error body, an empty
    # string, a jq `null`, or anything else means the question was not answered.
    [[ "$out" =~ ^[0-9]+$ ]] && break
    out=""
  done
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
  # Namespace-AGNOSTIC, and the REF comes from install.sh -- not a constant.
  #
  # This grep was pinned to "ghcr.io/creativemachines-ai/", but install.sh ships
  # "ghcr.io/ostler-ai/" (CI publishes to one namespace, the installer pulls the
  # other -- CM044 #643). So the grep never matched, `digest` came back EMPTY,
  # and EVERY wiki row failed as "UNRECORDED provenance" against a ledger that
  # was perfectly correct -- with a mangled "/creativemac" in the message. The
  # sibling bug in verify_cut_freshness.sh had the same single cause.
  #
  # Building the ref from a hardcoded owner is the worse half: a `docker pull`
  # of ghcr.io/creativemachines-ai/... would fetch an image the customer never
  # runs, and any marker check against it would be answering about the wrong
  # artefact. Lift BOTH digest and owner out of the shipped line.
  local line shipped_ref
  line="$(grep -m1 -E "image: ghcr\.io/[a-z0-9-]+/ostler-${key}@sha256:" "${INSTALL_SH}" 2>/dev/null)"
  digest="$(printf '%s' "$line" | sed -E 's/.*@(sha256:[0-9a-f]+).*/\1/')"
  shipped_ref="$(printf '%s' "$line" \
    | sed -E "s#.*(ghcr\.io/[a-z0-9-]+/ostler-${key}@sha256:[0-9a-f]+).*#\1#")"
  if [[ -n "$override" ]]; then
    ref="$override"
    # Try to lift the digest out of the override ref for the ledger lookup.
    case "$override" in *@sha256:*) digest="sha256:${override##*@sha256:}" ;; esac
  else
    ref="$shipped_ref"
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
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return
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

  # SPLIT THE GATE BY WHAT EACH ENVIRONMENT CAN HONESTLY PROVE.
  #
  # The wiki classes open the pinned image, which needs docker. The cut job is
  # macos-26 and has none; the preflight job is ubuntu-latest and does. Before
  # this filter existed the only way to run the gate was to run every class
  # everywhere, so the macos job reported the wiki rows as unverifiable and the
  # cut stopped on an environment limitation dressed as an artefact fault.
  #
  # Every class still runs exactly once -- it runs where it can look. Skips are
  # COUNTED and NAMED in the verdict, so a narrowed run can never read as a
  # complete one. Same split, same reasoning, as OSTLER_PROVENANCE_ONLY_KINDS in
  # verify_cut_provenance.sh; the vocabulary differs because the axis differs
  # (artifact class here, manifest kind there).
  class="${artifact%%:*}"
  case "$class" in wiki-compiler|wiki-site) class=wiki ;; esac
  if [[ -n "${PROV_GATE_ONLY_CLASSES:-}" ]] \
     && ! printf '%s' ",${PROV_GATE_ONLY_CLASSES}," | grep -q ",${class},"; then
    skipped "${label} :: class '${class}' not selected by PROV_GATE_ONLY_CLASSES"; continue
  fi
  if [[ -n "${PROV_GATE_SKIP_CLASSES:-}" ]] \
     && printf '%s' ",${PROV_GATE_SKIP_CLASSES}," | grep -q ",${class},"; then
    skipped "${label} :: class '${class}' deliberately skipped here -- verified in another job"; continue
  fi

  case "$artifact" in
    wiki-compiler|wiki-site)
      # SPLIT WITHOUT COLLAPSING EMPTY FIELDS. `IFS=$'\t' read -r a b c` looks
      # like a faithful 3-field split, but TAB is an IFS *whitespace* character,
      # so bash collapses runs of it: when resolve_wiki emits an EMPTY
      # ledger_sha (the exact case this gate exists to catch -- a digest with no
      # provenance row) the output is "digest\t\tref" and the two tabs collapse
      # into one. `ref` then slides into `ledger_sha`, the [[ -z "$ledger_sha" ]]
      # UNRECORDED branch below becomes UNREACHABLE, and the gate instead
      # reports "ledger sha ghcr.io/crea does NOT contain <fix> -- STALE
      # BINDING" -- a real fault described as the wrong fault, sending whoever
      # reads it off to rebuild a perfectly good image.
      #
      # Splitting on a literal newline is not affected: the fields are read
      # positionally and an empty one stays empty.
      { IFS= read -r digest; IFS= read -r ledger_sha; IFS= read -r ref; } \
        < <(resolve_wiki "$artifact" | tr '\t' '\n')
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
        cannot "${label} :: could not establish ancestry of ${fix:0:7} in ledger sha ${ledger_sha:0:12} -- no ${repo} checkout AND no usable GitHub credential for that repo"
        info "this says NOTHING about the artefact. Do NOT rebuild or re-pin on the strength of it."
        info "on a runner, export OSTLER_GH_TOKEN_<ACCOUNT> (Contents:Read); locally, gh auth login as that account"
        continue
      fi
      # 2) CONTENT: is the fix actually baked into the pinned image?
      res="$(image_has_marker "$ref" "$marker" "$mpath")"
      case "$res" in
        NODOCKER) cannot "${label} :: docker unavailable here -- the image was never opened, so its content is unknown"
                  info "run this class where docker exists (see PROV_GATE_ONLY_CLASSES) rather than treating it as a defect"
                  continue ;;
        NOIMAGE)  cannot "${label} :: pinned image ${digest:7:12} is not local and could not be pulled -- registry/network, not the artefact"
                  continue ;;
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
        cannot "${label} :: could not resolve the daemon pin to an ostler-assistant tag sha -- needs a local checkout (OSTLER_ASSISTANT_DIR)"
        continue
      fi
      is_ancestor "$repo" "$fix" "$tag_sha"; anc=$?
      # `-ne 0` collapsed "proven absent" and "could not look" into one RED that
      # named the daemon stale. Split them: only 1 is a finding about the daemon.
      if [[ $anc -eq 1 ]]; then
        red "${label} :: daemon tag ${tag_sha:0:12} does NOT contain ${fix:0:7} -- STALE DAEMON"; continue
      elif [[ $anc -eq 2 ]]; then
        cannot "${label} :: could not establish ancestry of ${fix:0:7} in daemon tag ${tag_sha:0:12} -- no ostler-assistant checkout AND no usable credential"
        continue
      fi
      dir="$(repo_dir_for ostler-assistant)"
      # Ancestry can be settled over the API with no checkout at all, so this
      # content grep must prove it CAN read the tree before it reports on it.
      # Without the guard an absent checkout makes `git show` fail and the else
      # branch announces STALE DAEMON SOURCE -- a fabricated finding about a
      # file the gate never opened.
      if ! git -C "$dir" cat-file -e "${tag_sha}:${mpath}" 2>/dev/null; then
        cannot "${label} :: no ostler-assistant checkout holding ${tag_sha:0:12}:${mpath} -- content not read"
        info "set OSTLER_ASSISTANT_DIR to a checkout fetched deep enough to contain that tag"
        continue
      fi
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
echo "  ${PASS} pass / ${FAIL} fail / ${CANNOT} cannot-run / ${WARN} warn / ${SKIPPED} not-run-here"
if [[ "${WARN}" -gt 0 ]]; then
  echo "  ${WARN} advisory WARN(s): a shipped fix is content-proven present but its"
  echo "  source binding is unverifiable from image metadata. Close with the build-time"
  echo "  revision-label stamp (PROVENANCE_GATE.md) so the binding is enforceable."
fi
if [[ "${SKIPPED}" -gt 0 ]]; then
  echo "  ${SKIPPED} check(s) NOT RUN HERE by explicit selection -- named above. This run is"
  echo "  a NARROWED one; it is only complete alongside the job that runs those classes."
fi
# THREE-STATE, AND FAIL OUTRANKS CANNOT-RUN.
#
# Both stop the cut -- fail-closed is not negotiable -- but they demand opposite
# actions from whoever reads the log. A FAIL means rebuild and re-pin the
# artefact. A CANNOT-RUN means fix the environment and look again; rebuilding on
# the strength of one is wasted work aimed at a healthy artefact. Run
# 31696154993 spent the day proving how expensive that confusion is.
if [[ "${FAIL}" -gt 0 ]]; then
  echo "  CONTENT-PROVENANCE RED -- ${FAIL} artifact(s) miss a required fix."
  echo "  Rebuild + re-pin the RED artifact(s), fix the ledger row, then re-run. DO NOT CUT."
  exit 1
elif [[ "${CANNOT}" -gt 0 ]]; then
  echo "  CONTENT-PROVENANCE COULD NOT RUN -- ${CANNOT} check(s) never looked at their artifact."
  echo "  NOTHING has been found wrong with any artifact. Do NOT rebuild or re-pin on the"
  echo "  strength of this run: fix the credential / checkout / docker availability named"
  echo "  above and re-run. DO NOT CUT on an unproven artifact either."
  exit 2
else
  echo "  CONTENT-PROVENANCE GREEN -- every required fix is proven baked into its artifact."
  exit 0
fi
