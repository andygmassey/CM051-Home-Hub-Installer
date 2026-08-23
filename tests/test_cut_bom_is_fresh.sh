#!/usr/bin/env bash
# tests/test_cut_bom_is_fresh.sh
# ============================================================================
# THE VENDORED BOM MUST BE THE BOM FOR THE CUT BEING MADE.
#
# WHY THIS EXISTS. cuts/<version>/MUST_CONTAIN.tsv is vendored out of OS003,
# which is PRIVATE: CM051's GITHUB_TOKEN cannot read it, so the DMG assembly on
# a hosted runner cannot fetch the BOM at cut time. Vendoring is the only way
# to get it into the artefact.
#
# 🔴 THAT MAKES THE BOM A VENDOR PIN, AND VENDOR PINS IN THIS REPO ARE EXACTLY
# WHAT WENT STALE UNNOTICED. cm048_pipeline sat two commits behind source with
# verify="skip" + unverifiable_ack=true and nothing on any box could see it
# (#860). A stale vendored BOM is WORSE than no BOM: the runtime reconciler
# would check a box against the WRONG CUT and return a confident green. An
# absent BOM fails loudly; a wrong one agrees with you.
#
# So this gate ships in the same change as the vendoring, not after it.
#
# WHAT IT PROVES, AND WHAT IT CANNOT
#   PROVES:  a BOM exists for the version being cut, its declared version IS
#            that version, and its bytes match the hash cuts/BOM_PIN recorded.
#   CANNOT:  that the pinned OS003 commit is still OS003's HEAD. No cross-repo
#            token exists. That half is an OPERATOR check:
#            scripts/sync_cut_bom.sh --check before tagging.
#            Stated here rather than implied, because a gate quiet about its
#            blind spot gets read as covering it.
#
# EXIT: 0 fresh   1 FAIL (absent / wrong version / hash mismatch)   2 CANNOT-RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="${CUT_BOM_PIN:-$HERE/cuts/BOM_PIN}"
CUTS_DIR="${CUT_BOM_CUTS_DIR:-$HERE/cuts}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=''; GRN=''; YEL=''; OFF=''; }
ok()     { printf '  %sPASS%s  %s\n' "$GRN" "$OFF" "$*"; }
bad()    { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*" >&2; }
cannot() { printf '  %sCANNOT-RUN%s  %s\n' "$YEL" "$OFF" "$*" >&2; }

check_one() {
  local want="$1"; want="${want#v}"
  # RESOLVED PER CALL, not at script load. The first version read the
  # top-level $PIN/$CUTS_DIR, so the self-test's `CUT_BOM_PIN=... check_one`
  # prefixes were INERT and every case silently measured the real repo. The
  # positive control is what caught it: the correct case "failed" while the
  # gate passed standalone. Same shape as patching a symbol in one module
  # while the code under test reads its own import.
  local PIN="${CUT_BOM_PIN:-$HERE/cuts/BOM_PIN}"
  local CUTS_DIR="${CUT_BOM_CUTS_DIR:-$HERE/cuts}"
  local bom="$CUTS_DIR/v${want}/MUST_CONTAIN.tsv"

  # ABSENCE IS A FAILURE, NOT A SKIP. A missing BOM for the cut being made
  # means the vendoring did not happen, which is the drift being hunted.
  if [[ ! -f "$bom" ]]; then
    bad "no vendored BOM for v${want} at ${bom#$HERE/}"
    bad "  run scripts/sync_cut_bom.sh v${want} before tagging"
    return 1
  fi

  # THE VERSION THE FILE DECLARES MUST BE THE VERSION BEING CUT. This is the
  # limb that catches a STALE vendor: v1.0.41's BOM sitting in the tree while
  # v1.0.42 is cut would otherwise be embedded, shipped, and reconciled
  # against -- green, and about the wrong cut.
  local declared
  declared="$(grep -m1 -oE 'the BOM for v[0-9]+\.[0-9]+\.[0-9]+' "$bom" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [[ -z "$declared" ]]; then
    cannot "cannot read a declared version out of ${bom#$HERE/}"
    return 2
  fi
  if [[ "$declared" != "$want" ]]; then
    bad "vendored BOM declares v${declared} but the cut is v${want}"
    bad "  a BOM for another cut would reconcile a box against the WRONG cut"
    return 1
  fi
  ok "BOM present and declares v${want}"

  # BYTES MATCH THE PIN. Catches a hand edit on the CM051 side, which is how
  # the vendored rollforward gate drifted 239 lines from its source.
  if [[ ! -f "$PIN" ]]; then
    cannot "no BOM_PIN at ${PIN#$HERE/}"
    return 2
  fi
  local want_hash got_hash
  want_hash="$(awk -v k="cuts/v${want}/MUST_CONTAIN.tsv" '$1==k {print $2}' "$PIN")"
  if [[ -z "$want_hash" ]]; then
    bad "BOM_PIN records no hash for cuts/v${want}/MUST_CONTAIN.tsv"
    bad "  an unpinned vendored copy is a fork nobody declared"
    return 1
  fi
  got_hash="$(shasum -a 256 "$bom" | cut -d' ' -f1)"
  if [[ "$want_hash" != "$got_hash" ]]; then
    bad "vendored BOM does not match BOM_PIN"
    bad "  pinned ${want_hash:0:16}...  actual ${got_hash:0:16}..."
    return 1
  fi
  ok "bytes match BOM_PIN (${got_hash:0:16}...)"
  return 0
}

self_test() {
  local tmp rc fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  _c() { local label="$1" want="$2" got="$3"
         if [[ "$want" == "$got" ]]; then printf '  %sPASS%s  %s\n' "$GRN" "$OFF" "$label"
         else printf '  %sFAIL%s  %s (want %s got %s)\n' "$RED" "$OFF" "$label" "$want" "$got" >&2; fails=$((fails+1)); fi; }

  mkdir -p "$tmp/cuts/v1.2.3"
  printf '# MUST_CONTAIN.tsv -- the BOM for v1.2.3.\nwhat\trepo\tref\tlanded\tcapability_id\tverify\tticket\nx\tR\tr\tyes\tc\tv\tt\n' \
    > "$tmp/cuts/v1.2.3/MUST_CONTAIN.tsv"
  local h; h="$(shasum -a 256 "$tmp/cuts/v1.2.3/MUST_CONTAIN.tsv" | cut -d' ' -f1)"
  printf 'os003_sha\tdeadbeef\ncuts/v1.2.3/MUST_CONTAIN.tsv\t%s\n' "$h" > "$tmp/PIN"

  # POSITIVE CONTROL FIRST. A gate that always returns 1 would score 100% on
  # the negative cases below and be worthless.
  CUT_BOM_PIN="$tmp/PIN" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v1.2.3 >/dev/null 2>&1; rc=$?
  _c "a correctly vendored, correctly pinned BOM PASSES" 0 "$rc"

  CUT_BOM_PIN="$tmp/PIN" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v9.9.9 >/dev/null 2>&1; rc=$?
  _c "no BOM for the version being cut is FAIL, not a skip" 1 "$rc"

  # THE STALE-VENDOR CASE: right filename, wrong declared version.
  mkdir -p "$tmp/cuts/v1.2.4"
  sed 's/the BOM for v1.2.3/the BOM for v1.2.3/' "$tmp/cuts/v1.2.3/MUST_CONTAIN.tsv" > "$tmp/cuts/v1.2.4/MUST_CONTAIN.tsv"
  local h4; h4="$(shasum -a 256 "$tmp/cuts/v1.2.4/MUST_CONTAIN.tsv" | cut -d' ' -f1)"
  printf 'cuts/v1.2.4/MUST_CONTAIN.tsv\t%s\n' "$h4" >> "$tmp/PIN"
  CUT_BOM_PIN="$tmp/PIN" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v1.2.4 >/dev/null 2>&1; rc=$?
  _c "a BOM declaring ANOTHER cut's version is FAIL (the stale-vendor case)" 1 "$rc"

  printf 'tampered\n' >> "$tmp/cuts/v1.2.3/MUST_CONTAIN.tsv"
  CUT_BOM_PIN="$tmp/PIN" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v1.2.3 >/dev/null 2>&1; rc=$?
  _c "a hand-edited vendored BOM is FAIL (hash mismatch)" 1 "$rc"

  printf 'os003_sha\tdeadbeef\n' > "$tmp/PIN2"
  CUT_BOM_PIN="$tmp/PIN2" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v1.2.4 >/dev/null 2>&1; rc=$?
  _c "an UNPINNED vendored BOM is FAIL, not a pass" 1 "$rc"

  # Uses v1.2.3, whose declared version MATCHES, so the run reaches the pin
  # limb. Pointing this at v1.2.4 returned 1 from the version limb and the
  # pin check never ran -- a case that passed for the wrong reason.
  printf '# MUST_CONTAIN.tsv -- the BOM for v1.2.5.\nwhat\trepo\n' > "$tmp/cuts/v1.2.5.tmp" 2>/dev/null || true
  mkdir -p "$tmp/cuts/v1.2.5"
  printf '# MUST_CONTAIN.tsv -- the BOM for v1.2.5.\nwhat\trepo\tref\tlanded\tcapability_id\tverify\tticket\n' > "$tmp/cuts/v1.2.5/MUST_CONTAIN.tsv"
  CUT_BOM_PIN="$tmp/nope" CUT_BOM_CUTS_DIR="$tmp/cuts" check_one v1.2.5 >/dev/null 2>&1; rc=$?
  _c "a missing pin file is CANNOT-RUN(2), never a pass" 2 "$rc"

  if [[ $fails -eq 0 ]]; then printf '%sSELF-TEST: 6 passed, 0 failed%s\n' "$GRN" "$OFF"; return 0; fi
  printf '%sSELF-TEST: %d failed%s\n' "$RED" "$fails" "$OFF" >&2; return 1
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") echo "usage: $0 <cut-version> | --self-test" >&2; exit 2 ;;
  *) check_one "$1"; exit $? ;;
esac
