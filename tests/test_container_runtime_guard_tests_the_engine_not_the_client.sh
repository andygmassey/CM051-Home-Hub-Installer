#!/usr/bin/env bash
#
# THE INSTALLER MUST NOT INFER A CONTAINER ENGINE FROM A CONTAINER CLIENT.
# =======================================================================
#
# THE DEFECT. install.sh guarded the runtime install with:
#
#     if ! command -v docker &>/dev/null; then
#         brew install colima docker docker-compose
#     fi
#
# `command -v docker` finds the CLIENT. On macOS the Docker CLI is only a
# client -- the engine comes from Colima, Docker Desktop, OrbStack or Podman.
# A box that once had Docker Desktop and lost it keeps `/opt/homebrew/bin/
# docker` behind. The installer sees the client, concludes the runtime is
# handled, SKIPS installing Colima, and walks on with no engine at all.
#
# This is the house defect class: THE VERDICT IS INVARIANT TO THE DEFECT.
# The predicate returns the same answer whether or not a container can run.
#
# ── WHAT THIS TEST'S FIRST VERSION GOT WRONG ──────────────────────────────
#
# The first version asserted on the TEXT OF A WINDOW: "the 40 lines before
# `brew install colima` must not contain the literal `command -v docker`, and
# must contain an engine name somewhere". ORM broke it twice, and both mutants
# are instructive because neither is contrived -- each is something a person
# would plausibly write:
#
#   ATTACK A -- the walk defect resurrected, old test 10/0 GREEN:
#       if [[ "$ENGINE_PRESENT" == false && -x /opt/homebrew/bin/docker ]]; then
#           ENGINE_PRESENT=true
#       fi
#   A CLIENT sets ENGINE_PRESENT. The literal `command -v docker` never
#   appears, so the absence-check passed; an engine name appeared elsewhere in
#   the window, so the presence-check passed too.
#
#   ATTACK C -- one pair of quotes, old test 10/0 GREEN:
#       command -v "docker"
#   A routine shellcheck quoting pass silently disarms a literal-matching gate.
#
# The lesson is not "the window was too big". The window was fine. The lesson
# is that the property being guarded is not a property of nearby TEXT -- it is
# a property of the ASSIGNMENTS: nothing may set ENGINE_PRESENT=true on
# evidence that only proves a client is present. So that is what this version
# asserts, per assignment, on its own governing condition.
#
# Both mutants above fail the rewritten predicate. Current code passes it.
#
# ── AND A SECOND, QUIETER FAULT ───────────────────────────────────────────
#
# `sed 's/#.*//'` BLANKS a comment line but LEAVES IT. Of the old 40-line
# window only 14 lines were code; fourteen more lines of anything and the
# guard would have scrolled out of its own window with the test still green.
# Blank lines are dropped below, and that is load-bearing rather than tidy.
#
# The old "runtime considered: colima" limb was also vacuous -- `grep -qi
# colima` matches the string constant MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI,
# so it passed on unfixed main too. It now requires each runtime to appear in
# the ENGINE_PRESENT computation itself.
#
# ⚠️ BOUND, STATED NOT HIDDEN. This is a SOURCE-TEXT test. It proves the guard
# asks the right question. It does NOT prove behaviour on an engine-less Mac,
# which is the state that produced the defect and which CI does not have.
#
# ⚠️ AND A SCOPE CORRECTION WORTH KEEPING. This guard did NOT cause the
# 2026-08-23 dead wiki on the walk box. That was memory pressure killing a
# Colima VM that was correctly installed (see the jetsam chain in the register).
# The defect below is real and was found during that investigation, but the
# outage evidence belongs to the stdout-buffer fix, not to this one.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

echo
echo "== the container-runtime guard must test the ENGINE, not the client =="
echo

# ── 0. CANNOT-RUN FIRST ───────────────────────────────────────────────────
if [[ ! -r "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: ${INSTALL_SH} is not readable." >&2
    echo "  Nothing was measured. This is NOT a pass -- exit 2." >&2
    exit 2
fi
ok "CANNOT-RUN check: install.sh is readable"

# Comments are not code, and a blanked comment is not an absent line.
CODE="$(sed 's/#.*//' "$INSTALL_SH" | grep -v '^[[:space:]]*$')"

# Evidence that proves only a CLIENT. Quote-tolerant on purpose: `command -v
# "docker"` and `command -v docker` are the same claim and Attack C is exactly
# the difference between them. The character class stops at a shell separator
# so `command -v "$_rt" && ...` cannot be dragged into a match by a later word.
CLIENT_RE='command -v [^;&|]*docker|which [^;&|]*docker|bin/docker'
# Evidence that proves an ENGINE.
ENGINE_RE='colima|orbstack|podman|Docker\.app'

# ── CONTROL, RUN FIRST AND MUST BE NON-ZERO ───────────────────────────────
CTRL="$(grep -c 'docker' <<< "$CODE")"
if [[ "$CTRL" -ge 10 ]]; then
    ok "CONTROL: comment-stripped body still mentions docker ${CTRL} times (non-zero)"
else
    bad "CONTROL FAILED: only ${CTRL} docker references after stripping comments" \
        "the body is empty or sed ate it; every assertion below would be vacuous"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── CONTROL 2: THE PREDICATES THEMSELVES DISCRIMINATE ─────────────────────
# A regex that matches nothing, or matches everything, would make the
# assertions below meaningless in opposite directions. Prove both fire on
# known inputs before trusting either.
if grep -qE "$CLIENT_RE" <<< 'if [[ -x /opt/homebrew/bin/docker ]]; then' \
   && grep -qE "$CLIENT_RE" <<< 'if command -v "docker" &>/dev/null; then' \
   && ! grep -qE "$CLIENT_RE" <<< 'if command -v "$_rt" &>/dev/null; then'; then
    ok "CONTROL: the client-evidence predicate catches both mutants and spares the loop"
else
    bad "CONTROL FAILED: the client-evidence predicate does not discriminate" \
        "it must match Attack A and Attack C, and must NOT match the engine loop"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 1. ANTI-VACUITY: THE ASSIGNMENTS MUST EXIST ───────────────────────────
# Without this, deleting the whole ENGINE_PRESENT block and restoring
# `if ! command -v "docker"` would pass assertion 2 for free -- no assignments,
# no violations. That is Attack C in its wholesale form.
N_ASSIGN="$(grep -cE '^[[:space:]]*ENGINE_PRESENT=true' <<< "$CODE")"
if [[ "$N_ASSIGN" -ge 2 ]]; then
    ok "the engine-presence computation exists (${N_ASSIGN} ENGINE_PRESENT=true assignments)"
else
    bad "only ${N_ASSIGN} ENGINE_PRESENT=true assignments found (expected >= 2)" \
        "the engine computation was removed or reduced; the client check is likely back"
fi

# ── 2. NO ASSIGNMENT MAY REST ON CLIENT-ONLY EVIDENCE ─────────────────────
# THE ASSERTION THAT ACTUALLY HOLDS THE LINE. For each ENGINE_PRESENT=true,
# take the code lines that govern it and require that they name an engine and
# do NOT name a client. Eight lines is enough to reach the enclosing `for` in
# the loop case; because blanks are stripped it cannot be padded by prose.
VIOLATIONS=0; UNGROUNDED=0
while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    lo=$(( n > 8 ? n - 8 : 1 ))
    WIN="$(awk -v a="$lo" -v b="$n" 'NR>=a && NR<=b' <<< "$CODE")"
    if grep -qE "$CLIENT_RE" <<< "$WIN"; then
        VIOLATIONS=$((VIOLATIONS+1))
        printf '        line %s: governed by client-only evidence\n' "$n"
    fi
    grep -qE "$ENGINE_RE" <<< "$WIN" || UNGROUNDED=$((UNGROUNDED+1))
done < <(grep -nE '^[[:space:]]*ENGINE_PRESENT=true' <<< "$CODE" | cut -d: -f1)

if [[ "$VIOLATIONS" -eq 0 ]]; then
    ok "no ENGINE_PRESENT=true rests on client-only evidence"
else
    bad "${VIOLATIONS} ENGINE_PRESENT=true assignment(s) rest on client-only evidence" \
        "the CLIENT is present on any box that ever had Docker Desktop; it does not imply an ENGINE"
fi

if [[ "$UNGROUNDED" -eq 0 ]]; then
    ok "every ENGINE_PRESENT=true names an actual engine in its condition"
else
    bad "${UNGROUNDED} ENGINE_PRESENT=true assignment(s) name no engine" \
        "absence of the wrong predicate is not presence of the right one"
fi

# ── 3. THE DECISION MUST CONSULT THE COMPUTATION, NOT THE CLIENT ──────────
# The assignments could all be correct and still be ignored. Take the nearest
# `if`/`elif` above `brew install colima` -- the line that decides whether the
# runtime gets installed -- and require it to read ENGINE_PRESENT and not the
# client. This is where a quoted `command -v "docker"` would reappear.
DECISION="$(awk '/brew install colima/{print last; exit} /^[[:space:]]*(if|elif)[[:space:]]/{last=$0}' <<< "$CODE")"
if [[ -z "$DECISION" ]]; then
    bad "CANNOT-RUN: found no if/elif governing 'brew install colima'" \
        "the runtime install moved or was removed; this assertion measured nothing"
else
    if grep -q 'ENGINE_PRESENT' <<< "$DECISION"; then
        ok "the runtime-install decision consults ENGINE_PRESENT"
    else
        bad "the runtime-install decision does not consult ENGINE_PRESENT" \
            "found instead: ${DECISION}"
    fi
    if grep -qE "$CLIENT_RE" <<< "$DECISION"; then
        bad "the runtime-install decision consults the CLIENT" \
            "found: ${DECISION}"
    else
        ok "the runtime-install decision does not consult the client"
    fi
fi

# ── 4. EVERY SUPPORTED RUNTIME MUST BE IN THE COMPUTATION ─────────────────
# Scoped to the ENGINE_PRESENT region rather than the whole file. The old
# whole-file `grep -qi colima` matched MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI
# and so passed on unfixed main -- a limb that cannot fail is not a test.
REGION="$(awk '/ENGINE_PRESENT=false/{f=1} f{print} /brew install colima/{exit}' <<< "$CODE")"
if [[ -z "$REGION" ]]; then
    bad "CANNOT-RUN: no ENGINE_PRESENT region found" "assertion 4 measured nothing"
else
    for rt in colima orbstack podman Docker.app; do
        if grep -qi -- "$rt" <<< "$REGION"; then
            ok "runtime considered in the engine computation: ${rt}"
        else
            bad "runtime NOT considered: ${rt}" \
                "a box running ${rt} has an engine; the installer must not ignore it"
        fi
    done
fi

# ── 5. THE RUNTIME IS LOAD-BEARING, SO THE GUARD IS NOT DECORATION ────────
for img in ostler-wiki-site ostler-wiki-compiler; do
    if grep -q "${img}@sha256:" <<< "$CODE"; then
        ok "${img} is still digest-pinned (a real engine is genuinely required)"
    else
        bad "${img} is no longer digest-pinned in install.sh" \
            "either the wiki stopped needing a container engine, or the pin was lost"
    fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
