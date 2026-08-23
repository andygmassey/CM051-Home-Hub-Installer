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

# Evidence that proves only a CLIENT.
#
# 🔴 QUOTE-TOLERANT ON *EVERY* LIMB. ORM's MUTANT E was
# `-x /opt/homebrew/bin/"docker"` and it passed 14/0, because I had made the
# `command -v` limb tolerant and left `bin/docker` literal. A predicate that
# is careful in one place and lazy in another is a predicate with a documented
# entrance.
CLIENT_RE='command -v ["'"'"']*docker|which ["'"'"']*docker|bin/["'"'"']*docker'
# Evidence that proves an ENGINE.
ENGINE_RE='colima|orbstack|podman|Docker\.app'

# ── WHY THE NEXT ASSERTION IS A WHITELIST AND NOT A BLACKLIST ─────────────
#
# ORM's MUTANT D assigned a client check to a variable and consulted that
# variable NINE STATEMENTS LATER. It passed 14/0. His diagnosis is exact:
#
#     "a window is a distance, and a distance can be padded with statements"
#
# No blacklist survives laundering, because the launderer's job is to remove
# the blacklisted token from the place you are looking. So the condition
# governing an ENGINE_PRESENT=true must be positively CONSTRAINED instead:
# it may reference the loop variable, the flag itself, and literal engine
# names -- and nothing else. A laundered `$HAS_CLIENT` is not on that list,
# so it fails by not being permitted rather than by being recognised.
#
# The cost is real and worth stating: a future author who legitimately needs
# a new variable in that condition must add it here. That is the intended
# friction. This condition is three lines long and decides whether we install
# a second container engine over a working one.
# HAS_DOCKER is on this list DELIBERATELY and it is the interesting entry.
# It is install.sh:3477-3479 -- `command -v docker && docker info` -- and the
# `docker info` limb is a genuine ENGINE probe: it fails when no daemon is
# reachable, which is the actual question. It gates the whole block from
# outside, so it appears in every window. Adjudicated, not waved through: if
# HAS_DOCKER ever stops consulting `docker info`, assertion 2b below catches
# that separately and this entry becomes wrong. Both must hold.
ALLOWED_VARS='_rt|rt|ENGINE_PRESENT|HAS_DOCKER'

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
VIOLATIONS=0; UNGROUNDED=0; LAUNDERED=0
while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    lo=$(( n > 8 ? n - 8 : 1 ))
    WIN="$(awk -v a="$lo" -v b="$n" 'NR>=a && NR<=b' <<< "$CODE")"
    if grep -qE "$CLIENT_RE" <<< "$WIN"; then
        VIOLATIONS=$((VIOLATIONS+1))
        printf '        line %s: governed by client-only evidence\n' "$n"
    fi
    grep -qE "$ENGINE_RE" <<< "$WIN" || UNGROUNDED=$((UNGROUNDED+1))

    # THE ANTI-LAUNDERING LIMB. Take the conditions in the window and pull out
    # every variable they consult. Anything outside ALLOWED_VARS is a value
    # computed somewhere this predicate cannot see -- which is precisely what
    # MUTANT D was. We do not have to recognise the laundering; we only have to
    # refuse to accept evidence whose provenance we cannot read.
    CONDS="$(grep -E '(^|[[:space:]])(if|elif|while)[[:space:]]' <<< "$WIN")"
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        grep -qE "^(${ALLOWED_VARS})$" <<< "$v" || {
            LAUNDERED=$((LAUNDERED+1))
            printf '        line %s: condition consults unapproved variable $%s\n' "$n" "$v"
        }
    done < <(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<< "$CONDS" | tr -d '${' | sort -u)
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

if [[ "$LAUNDERED" -eq 0 ]]; then
    ok "no condition consults a variable computed out of this predicate's sight"
else
    bad "${LAUNDERED} condition(s) consult unapproved variables" \
        "a client check assigned to a variable and read later is MUTANT D; if the new variable is legitimate, add it to ALLOWED_VARS deliberately"
fi

# ── 2b. THE ONE ALLOWED VARIABLE MUST STAY HONEST ─────────────────────────
# HAS_DOCKER is permitted in a condition above ONLY because its value comes
# from an engine probe. If someone reduces it to a bare `command -v docker`,
# the allowance silently becomes the very laundering it was meant to exclude.
#
# 🔴 THIS ASSERTION WAS PINNED TO A SPELLING AND #994 CHANGED IT. It read
# `grep -A2 '^HAS_DOCKER=false'` and scored CANNOT-RUN the moment Phase 0
# landed, because Phase 0 does not initialise HAS_DOCKER at all. It writes:
#
#     HAS_DOCKER_CLIENT=false
#     HAS_CONTAINER_ENGINE=false
#     command -v docker &>/dev/null && HAS_DOCKER_CLIENT=true
#     if [[ "$HAS_DOCKER_CLIENT" == true ]] && docker info &>/dev/null 2>&1; then
#         HAS_CONTAINER_ENGINE=true
#     ...
#     HAS_DOCKER="$HAS_CONTAINER_ENGINE"
#
# That is STRICTLY BETTER than what the assertion was written against -- the
# client and the engine now have separate names, and HAS_DOCKER is an alias
# for the engine answer. The assertion went CANNOT-RUN on an improvement.
#
# So follow the VALUE, not the spelling: walk HAS_DOCKER's assignments, and
# if one assigns from another variable, follow that variable once more. The
# probe must be reached within that chain. Bounded at one hop deliberately --
# deeper than that and "derives from an engine probe" stops being something a
# reader can check by eye, which is the property this assertion exists to keep.
probe_chain() {
    local var="$1" depth="${2:-0}" line src
    (( depth > 1 )) && return 1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # -B4 as well as -A2: a guarded assignment sits INSIDE the `if` whose
        # condition holds the probe, so the probe is ABOVE it, not below.
        # Looking only forward is why this assertion first reported a break
        # on a tree where the probe was two lines up. The window is anchored
        # on the ASSIGNMENT, which travels with the code -- unlike a distance
        # measured from some consumer elsewhere in the file.
        src="$(grep -B4 -A2 -E "^[[:space:]]*${line}" <<< "$CODE")"
        grep -q 'docker info' <<< "$src" && return 0
        # assigned from another variable? follow it exactly once.
        while IFS= read -r v; do
            [[ -z "$v" || "$v" == "$var" ]] && continue
            probe_chain "$v" $(( depth + 1 )) && return 0
        done < <(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<< "$line" | tr -d '${' | sort -u)
    done < <(grep -oE "^[[:space:]]*${var}=[^;&|]*" <<< "$CODE" | sed 's/^[[:space:]]*//')
    return 1
}
if ! grep -qE "^[[:space:]]*HAS_DOCKER=" <<< "$CODE"; then
    bad "CANNOT-RUN: HAS_DOCKER is never assigned" "assertion 2b measured nothing"
elif probe_chain HAS_DOCKER; then
    ok "HAS_DOCKER's value still derives from 'docker info' (an engine probe), so allowing it is safe"
else
    bad "HAS_DOCKER's value no longer derives from 'docker info'" \
        "it is permitted in engine conditions ONLY because it probes the engine; it now launders the client"
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
