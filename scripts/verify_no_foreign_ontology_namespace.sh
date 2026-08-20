#!/usr/bin/env bash
#
# verify_no_foreign_ontology_namespace.sh -- the identifiers we stamp into a
# customer's own data must live on a domain WE OWN.
#
# PROVED-RED-BY: scripts/tests/test_no_foreign_ontology_namespace.sh
#
# ============================================================================
# WHY. MEASURED 2026-08-17, AND IT IS NOT HYPOTHETICAL.
# ============================================================================
#
#     pwg.dev                                NXDOMAIN
#     web.dev                                NOERROR    <- positive control
#     thisdomainreallydoesnotexist12345.dev  NXDOMAIN   <- negative control
#
# Reproduced from two independent networks. `pwg.dev` returns exactly what an
# invented domain returns: IT IS NOT REGISTERED. Anyone can buy it.
#
# And it is not incidental. RDF requires every entity, class and property to
# carry a globally unique URI, so this string is the PRIMARY KEY of the
# customer's own graph:
#
#     https://pwg.dev/ontology#Person
#     https://pwg.dev/data/preference/{subject}
#
# Those identifiers are written into Oxigraph, into every RDF export, and into
# the portability promise. If someone else registers the domain, every
# customer's data permanently carries identifiers pointing at a stranger, and
# we cannot take it back.
#
# THE LIVE HAZARD, not merely the branding one. "Follow your nose" is standard
# linked-data behaviour: RDF tooling encountering an unknown namespace MAY
# dereference it to fetch the ontology. Our code does not -- verified, all 276
# occurrences are PREFIX declarations or R2RML templates, none passed to an
# HTTP client. But a customer opening their export in third-party RDF software
# might, and would then be fetching whatever the new owner serves. That turns a
# naming problem into a network one without us touching a line.
#
# It is also the old internal project name (pwg = Personal World Graph) stamped
# into a shipped artefact, which is the same class as the standing rule that
# gamingrig and Andypedia must not reach a customer -- except this one is in
# the DATA, not a document.
#
# ============================================================================
# ADVISORY WHILE NON-ZERO, HARD AT ZERO, AND IT PROMOTES ITSELF
# ============================================================================
#
# Archie's call, 2026-08-17, and his reasoning beat mine. I proposed holding
# the gate back until his in-flight CM051 work merged. He pointed out that
# assumes the only risk direction is additions someone would notice, and that
# an advisory gate gives the signal in BOTH directions immediately at zero cost
# to anyone's PR, with nothing bought by waiting.
#
# So while the declared count is ABOVE zero this gate WARNS and exits 0. The
# moment the declared count reaches zero it becomes HARD automatically. That is
# deliberately not "a one-line change later": a promotion that depends on
# somebody remembering is a promotion that does not happen.
#
# A WARNING IS NOT A PASS. It is printed as WARN, never as GREEN, because a
# three-state result read as two states silently promotes warn to pass and the
# warn line is where the program confesses the defect.
#
# ============================================================================
# WHY A RATCHET AND NOT A CLIFF
# ============================================================================
#
# 276 occurrences across 63 files exist TODAY. A gate that simply fails would
# red every PR in the repo from the moment it lands, and a gate that is red on
# everything gets routed around or deleted -- which is how we would end up
# shipping the thing this exists to stop.
#
# So it is a RATCHET. The declared count may never INCREASE, and every step of
# the migration lowers it. It reaches zero when the source repos are fixed and
# re-vendored, and at that point the declared count becomes 0 and the gate
# turns into a permanent floor.
#
# THE MIGRATION IS UPSTREAM. Most occurrences are in vendor/ (cm041 24 files,
# cm019_preferences 7, contact_syncer 12). Those are COPIES. Fixing them here
# is undone by the next re-vendor, so the real fix lands in the source repos
# and arrives here as a re-vendor. This gate does not care where the fix comes
# from; it only refuses to let the number go up.
#
# EXIT
#   0  at the declared count; OR out of step while the declared count is still
#      above zero, in which case it WARNS loudly and is explicitly NOT a pass
#   1  out of step while the declared count is ZERO (the promoted, hard state)
#   2  could not run. NOT a pass.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" 2>/dev/null || { echo "CANNOT-RUN: cannot enter '$REPO'" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "CANNOT-RUN: not a git repository: $REPO" >&2; exit 2; }

COUNT_FILE="${OSTLER_NS_COUNT_FILE:-$REPO/scripts/.foreign-ontology-namespace-count}"

# The namespaces that are NOT ours. Add a row when another one is found; never
# remove one to make a build pass.
# BOTH pwg domains, not just the unregistered one.
#
# The first version of this regex was `pwg\.dev` alone. Measured 2026-08-17,
# the shipping tree also carries `http://pwg.local/ontology#` in 5 files: the
# CM019 enrichment service writes every enriched preference into it. That is a
# THIRD pwg-branded namespace, and with a pwg.dev-only regex this ratchet
# could not see it. Retiring pwg.dev while leaving pwg.local in place would
# have looked like a completed migration and left "pwg" stamped into the
# customer's graph forever.
#
# pwg.local is not unregistered, it is worse in one respect and better in
# another: `.local` is reserved for mDNS, so it can never be resolved or
# owned, and any tooling that dereferences it is querying the local network.
# It is better only in that it cannot be taken by a stranger.
FOREIGN_RE='pwg\.(dev|local)'

# Ours, for the message. Any replacement must land on a domain we control.
OURS='https://ostler.ai/ontology#'

[ -f "$COUNT_FILE" ] || {
    echo "CANNOT-RUN: no declared count at '$COUNT_FILE'." >&2
    echo "  Without it this gate has nothing to compare against and would pass" >&2
    echo "  any tree, including one that had just doubled." >&2
    exit 2
}
declared="$(grep -vE '^[[:space:]]*#' "$COUNT_FILE" | tr -dc '0-9')"
[ -n "$declared" ] || { echo "CANNOT-RUN: '$COUNT_FILE' declares no number." >&2; exit 2; }

# grep -c per file then sum: `git grep -c` prints per-file counts, and a plain
# line count would undercount two occurrences on one line.
# THE INSTRUMENT MUST NOT COUNT ITSELF.
#
# This script and its count file both NAME the namespaces, in prose, in
# order to explain what they are for. Without these exclusions the gate
# measures its own documentation: widening the regex made the number rise
# purely because the new comment mentioned the new domain. A guard whose
# reading moves when you edit its comments is measuring the wrong thing.
SELF=(
  ":(exclude)scripts/verify_no_foreign_ontology_namespace.sh"
  ":(exclude)scripts/.foreign-ontology-namespace-count"
  # 🔴 THIS PATH IS LOAD-BEARING AND IT WAS WRONG. It read
  # `tests/test_no_...` while the file lives at `scripts/tests/test_no_...`,
  # so the fixture was never excluded and its occurrence was counted as a
  # shipping one -- the declared number said 292 against a tree holding 291.
  # A pathspec that matches nothing excludes nothing and reports no error.
  # Control 9 pins the behaviour rather than the spelling.
  ":(exclude)scripts/tests/test_no_foreign_ontology_namespace.sh"
)
actual="$(git grep -ohE "$FOREIGN_RE" -- . "${SELF[@]}" 2>/dev/null | grep -c . || true)"
files="$(git grep -lE "$FOREIGN_RE" -- . "${SELF[@]}" 2>/dev/null | grep -c . || true)"

echo "foreign ontology namespace: occurrences=${actual} files=${files} declared=${declared}"

if [ "${actual:-0}" -gt "$declared" ]; then
    echo >&2
    echo "WARN: the count went UP, ${declared} -> ${actual}." >&2
    echo "  Something new is stamping an unregistered domain into customer data." >&2
    echo "  Use ${OURS} instead. If this arrived via a re-vendor, the fix belongs" >&2
    echo "  in the SOURCE repo, not here, or the next re-vendor undoes it." >&2
    git grep -nE "$FOREIGN_RE" -- . "${SELF[@]}" | head -20 >&2
    [ "$declared" -eq 0 ] && exit 1
    echo >&2
    echo "  ADVISORY while the declared count is above zero (currently ${declared})." >&2
    echo "  NOT a pass. This becomes a hard failure automatically at zero." >&2
    exit 0
fi

if [ "${actual:-0}" -lt "$declared" ]; then
    echo >&2
    echo "WARN: the count went DOWN, ${declared} -> ${actual}, and the" >&2
    echo "  declared number was not lowered in the same commit." >&2
    echo "  That is good news being recorded badly. Set ${COUNT_FILE} to ${actual}" >&2
    echo "  so the ratchet holds the ground you just took. A floor nobody lowers" >&2
    echo "  after a migration stops being evidence about anything." >&2
    [ "$declared" -eq 0 ] && exit 1
    echo "  ADVISORY while the declared count is above zero. NOT a pass." >&2
    exit 0
fi

if [ "${actual:-0}" -eq 0 ]; then
    echo "GATE: GREEN -- zero. The namespace is fully migrated; keep the declared"
    echo "  count at 0 and this becomes a permanent floor."
    exit 0
fi

echo "GATE: GREEN -- at the declared count of ${declared}, not above it."
echo "  This is a RATCHET, not an endorsement. ${actual} occurrences of an"
echo "  UNREGISTERED domain remain in customer-facing identifiers. Migration"
echo "  target: ${OURS}"
exit 0
