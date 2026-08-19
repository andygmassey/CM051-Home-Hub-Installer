#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A check that COULD NOT RUN must never report the artefact as STALE.
#
# WHAT THIS CAUGHT, 2026-08-13 (run 31696154993).
#
# check-provenance-content was the last gate standing between a fully-signed,
# notarised, stapled build and a DMG. It emitted four REDs:
#
#   FAIL  CM044 f936095 -> wiki-compiler :: ledger sha 0bdc1d16de7b does NOT
#         contain f936095 -- STALE BINDING
#   ... and three more of the same shape.
#
# Every one was false. CM044 main IS 0bdc1d16, and a compare with the right
# credential returns behind_by=0 for all three commits -- they are genuine
# ancestors, dated three weeks BEFORE the sha they were said to be missing from.
# The remedy the gate printed -- rebuild the image, re-pin, fix the ledger row --
# would have burned hours re-cutting three perfectly good wiki images.
#
# THE MECHANISM, and it is the third sighting of it in one day.
#
#     out="$(gh api ... --jq '.behind_by' 2>/dev/null)"
#     [[ -z "$out" ]] && return 2        # "unauthorised gives empty" -- FALSE
#     [[ "$out" == "0" ]] && return 0
#     return 1                           # every auth failure landed HERE
#
# `gh api` does not apply --jq to a non-2xx response; it prints the raw error
# body to stdout. `{"message":"Bad credentials",...}` is 112 bytes, so -z is
# false, so return 2 was UNREACHABLE and every unauthorised lookup returned "not
# an ancestor". The cut step exports a CM051-scoped GH_TOKEN that cannot read
# andygmassey/CM044-PWG-Personal-Wiki, and the gate never asked for the
# andygmassey credential that was already sitting in its environment.
#
# WHAT IS ASSERTED HERE. Not the wording of a message -- the DECISION:
#   1. an unusable credential is CANNOT-RUN, never STALE BINDING
#   2. a genuine non-ancestor is STILL A RED               (teeth preserved)
#   3. a genuine ancestor with the marker present is a PASS (no false green)
#   4. docker being absent is CANNOT-RUN, never a stale image
#   5. an explicitly skipped class is COUNTED and NAMED, never silent
#   6. the raw error body must not be mistaken for an answer -- asserted
#      directly, because that single false premise caused all four REDs
#
# Exit: 0 all assertions pass, 1 a failure, 2 the harness could not run.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/provenance_gate.sh"
[ -f "$GATE" ] || { echo "::error::$GATE not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# FIXTURE SHAPES ARE HEX-WITH-LETTERS ON PURPOSE. DO NOT "SIMPLIFY" THEM.
#
# The first draft used a digest of 64 repeated '1' and a ledger sha padded with
# zeros. Both are pure-digit runs, and .github/scripts/ci-pii-shape-scan.sh
# matches '\b[0-9]{15,}\b' -- it tests SHAPE, not a list of known values, so a
# plainly synthetic number still reads as an account or phone identifier. The
# scan was right to fire and the fix belongs here, not in the pattern.
#
# Every literal below is valid hex containing letters, so the longest digit run
# is two. Real digests and shas look like this anyway, which makes the fixture
# more faithful rather than less.
DIGEST="sha256:deadbeefcafef00ddeadbeefcafef00ddeadbeefcafef00ddeadbeefcafef00d"
FIX=f936095
LEDGER_SHA=0bdc1d16de7bdeadbeefcafef00ddeadbeefcafe

# --- fixtures --------------------------------------------------------------
printf 'image: ghcr.io/ostler-ai/ostler-wiki-compiler@%s\n' "$DIGEST" > "$WORK/install.sh"
printf 'wiki-compiler\t%s\t%s\n' "$DIGEST" "$LEDGER_SHA" > "$WORK/ledger.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    CM044 "$FIX" wiki-compiler SETTLING_MARKER /app "settling-panel redesign" \
    > "$WORK/required.tsv"

# A directory that is deliberately NOT a git checkout, so the gate takes the
# GitHub fallback -- the path that produced the false REDs. Assert it, rather
# than assume it: if it were a repo the whole harness would test nothing.
mkdir -p "$WORK/not-a-checkout"
if git -C "$WORK/not-a-checkout" rev-parse --git-dir >/dev/null 2>&1; then
    echo "::error::harness dir is inside a git repo; the API fallback would not run"; exit 2
fi

mkdir -p "$WORK/bin"
PRISTINE_PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin"

make_gh() {  # $1 = mode
    cat >"$WORK/bin/gh" <<STUB
#!/bin/bash
case "$1" in
  bad_creds)
    # EXACTLY what the real gh emits on a non-2xx: the error body, on STDOUT,
    # with --jq NOT applied. Reproduced verbatim from a live 401.
    echo '{'
    echo '  "message": "Bad credentials",'
    echo '  "documentation_url": "https://docs.github.com/rest",'
    echo '  "status": "401"'
    echo '}'
    exit 1 ;;
  not_ancestor) echo 7; exit 0 ;;
  ancestor)     echo 0; exit 0 ;;
esac
STUB
    chmod +x "$WORK/bin/gh"
}

make_docker() {  # $1 = present|absent, $2 = found|missing
    if [ "$1" = absent ]; then rm -f "$WORK/bin/docker"; return; fi
    # THE STUB MODELS create + cp, NOT run, AND THAT IS THE POINT OF THE CHANGE.
    #
    # provenance_gate.sh used to exec the image (`docker run --entrypoint sh`)
    # to grep it. On the amd64 cut runner an arm64-only image cannot exec, so it
    # read nothing and called that STALE IMAGE -- which burned v1.0.28. It now
    # EXTRACTS with docker create + docker cp, which executes nothing.
    #
    # This stub therefore has to materialise FILES rather than return an exit
    # code. Left as a `run` stub it fell through to a bare `exit 0` with no
    # container id, the extraction found 0 files, and the gate correctly said
    # CANNOT-RUN (exit 2) -- which read as three test failures against a gate
    # that was behaving properly. The harness was modelling the old mechanism.
    cat >"$WORK/bin/docker" <<STUB
#!/bin/bash
# image_revision_label passes --format; plain inspect is the presence probe.
for a in "\$@"; do [ "\$a" = "--format" ] && exit 0; done
case "\$1" in
  image)  exit 0 ;;                     # digest already local, no pull needed
  create) echo stubcontainerid0000; exit 0 ;;
  rm)     exit 0 ;;
  cp)     # \$2 = <cid>:<path>, \$3 = destination directory
          d="\$3"
          mkdir -p "\$d/app" || exit 1
          # A NON-EMPTY extraction either way: "missing" must mean the marker is
          # genuinely absent from files that WERE read, not that nothing was read.
          # Those are different verdicts and conflating them is the whole bug.
          if [ "$2" = found ]; then
              printf 'SETTLING_MARKER\n' > "\$d/app/marker.txt"
          else
              printf 'this build carries no such marker\n' > "\$d/app/marker.txt"
          fi
          exit 0 ;;
esac
exit 0
STUB
    chmod +x "$WORK/bin/docker"
}

run_gate() {
    PATH="$PRISTINE_PATH" \
    OSTLER_GH_TOKEN_ANDYGMASSEY="fixture-token-not-a-real-credential" \
    REQUIRED_FIXES_FILE="$WORK/required.tsv" \
    WIKI_PROVENANCE_FILE="$WORK/ledger.tsv" \
    INSTALL_SH="$WORK/install.sh" \
    CM044_DIR="$WORK/not-a-checkout" \
    OSTLER_ASSISTANT_DIR="$WORK/not-a-checkout" \
    PROV_GATE_ALLOW_PULL=0 \
    PROV_GATE_ONLY_CLASSES="${ONLY:-}" \
    PROV_GATE_SKIP_CLASSES="${SKIP:-}" \
    bash "$GATE" >"$WORK/out" 2>&1
    echo $?
}

fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"
          else printf '  FAIL  %s  (expected %s, got %s)\n' "$1" "$2" "$3"; fail=1
               sed 's/^/          /' "$WORK/out"; fi }
absent() { if grep -q "$2" "$WORK/out"; then
               printf '  FAIL  %s  (found forbidden text: %s)\n' "$1" "$2"; fail=1
               sed 's/^/          /' "$WORK/out"
           else printf '  PASS  %s\n' "$1"; fi }
present() { if grep -q "$2" "$WORK/out"; then printf '  PASS  %s\n' "$1"
            else printf '  FAIL  %s  (missing: %s)\n' "$1" "$2"; fail=1
                 sed 's/^/          /' "$WORK/out"; fi }

echo "== 6. the false premise itself: an error body is NOT empty"
# Asserted first and directly. Every other assertion below is downstream of this
# one fact, and if it ever stops holding the rest stop meaning anything.
make_gh bad_creds
body="$(PATH="$PRISTINE_PATH" gh api anything --jq '.behind_by' 2>/dev/null)"
if [ -z "$body" ]; then
    echo "  FAIL  the harness's own error body is empty -- it cannot reproduce the defect"; fail=1
else
    echo "  PASS  error body is non-empty ($(printf '%s' "$body" | wc -c | tr -d ' ') bytes), so -z can never detect the failure"
fi
case "$body" in
  ''|*[!0-9]*) echo "  PASS  error body is not a bare integer, so a shape test rejects it" ;;
  *)           echo "  FAIL  error body parsed as an integer -- the new predicate would accept it"; fail=1 ;;
esac

echo
echo "== 1. THE DEFECT: an unusable credential is CANNOT-RUN, not STALE BINDING"
make_gh bad_creds; make_docker present found
rc="$(run_gate)"
check   "unusable credential does not exit 1 (a finding about the artefact)" "2" "$rc"
present "says it could not establish ancestry" "could not establish ancestry"
absent  "does NOT accuse the ledger of being stale" "STALE BINDING"
absent  "does NOT tell anyone to rebuild the image" "rebuild the"

echo
echo "== 2. TEETH: a genuine non-ancestor is still a RED"
make_gh not_ancestor; make_docker present found
rc="$(run_gate)"
check   "genuine non-ancestor exits 1" "1" "$rc"
present "names it as a stale binding" "STALE BINDING"

echo
echo "== 3. NO FALSE GREEN: ancestor + marker present passes"
make_gh ancestor; make_docker present found
rc="$(run_gate)"
check   "ancestor with content present exits 0" "0" "$rc"

echo "   3b. ancestor but marker ABSENT is still a RED"
make_gh ancestor; make_docker present missing
rc="$(run_gate)"
check   "content genuinely missing exits 1" "1" "$rc"
present "names it as a stale image" "STALE IMAGE"

echo
echo "== 4. docker absent is CANNOT-RUN, not a stale image"
make_gh ancestor; make_docker absent
rc="$(run_gate)"
check   "no docker exits 2, not 1" "2" "$rc"
absent  "does NOT call the image stale" "STALE IMAGE"

echo
echo "== 5. a skipped class is counted and named, never silent"
make_gh ancestor; make_docker absent
SKIP=wiki rc="$(SKIP=wiki run_gate)"
check   "skipping the only class leaves nothing failing" "0" "$rc"
present "the skip is named" "deliberately skipped here"
present "the verdict counts it" "not-run-here"
present "the verdict says the run was narrowed" "NARROWED"

echo
if [ "$fail" -eq 0 ]; then echo "provenance-gate cannot-run: all assertions pass"
else echo "provenance-gate cannot-run: FAILURES ABOVE"; fi
exit "$fail"
