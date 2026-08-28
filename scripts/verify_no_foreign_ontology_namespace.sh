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
#
# THE THIRD WIDENING, 2026-08-20, AND IT IS THE SAME MISS TWICE OVER.
# The note above records widening this regex once, from pwg.dev alone to both
# domains, because a domain-only pattern could not see pwg.local. It stopped
# there. Measured today, the trees also carried 365 occurrences of `urn:pwg:`
# -- preference, person, todo, conversation, user, hygiene and named-graph
# identifiers -- and a pattern built around a DOTTED HOST cannot match a URN,
# because a URN has no host and no dot. So the gate read 294 while the real
# figure across the shipping trees was 1,011, and it would have gone green on
# a migration that left a third of the problem in place.
#
# A URN is the worst of the three to leave behind. The other two are wrong
# because of who does or does not own a domain, which a purchase could in
# principle fix. `urn:pwg:` is non-dereferenceable by construction and is
# simply the old internal project name, permanently, in the customer's own
# primary keys. Nothing can rescue it later; it has to not ship.
FOREIGN_RE='pwg\.(dev|local)|urn:pwg:'

# Ours, for the message. Any replacement must land on a domain we control.
#
# This said `https://ostler.ai/ontology#` until 2026-08-20 and that was the
# gate author's suggestion, not the decision. Andy's ruling, recorded in
# GROUNDING and independently in docs/EGRESS_INVENTORY.md, is
# schema.ostler.ai with no purchase of the old domain. A gate that recommends
# a different target from the one the migration is executing would have split
# the namespace in two, which is strictly worse than either choice alone.
OURS='https://schema.ostler.ai/ontology#'

[ -f "$COUNT_FILE" ] || {
    echo "CANNOT-RUN: no declared count at '$COUNT_FILE'." >&2
    echo "  Without it this gate has nothing to compare against and would pass" >&2
    echo "  any tree, including one that had just doubled." >&2
    exit 2
}
# THE SIGN MATTERS AND `tr -dc '0-9'` EATS IT. Read the declaration as a
# whole token and validate it, rather than scraping digits out of whatever is
# there. The old form deleted every non-digit, so a declaration of -50 was
# read as 50: a nonsense input became a plausible number and the gate then
# reported a confident verdict about a question nobody had asked. The
# companion test's 7b arm produced exactly that value by arithmetic and the
# resulting failure looked like a broken gate rather than a mis-parsed input.
declared="$(grep -vE '^[[:space:]]*#' "$COUNT_FILE" | tr -d '[:space:]')"
[ -n "$declared" ] || { echo "CANNOT-RUN: '$COUNT_FILE' declares no number." >&2; exit 2; }
case "$declared" in
    ''|*[!0-9]*)
        echo "CANNOT-RUN: '$COUNT_FILE' declares '${declared}', which is not a" >&2
        echo "  non-negative integer. A count cannot be negative and cannot be" >&2
        echo "  text; refusing rather than coercing it into something plausible." >&2
        exit 2 ;;
esac

# grep -c per file then sum: `git grep -c` prints per-file counts, and a plain
# line count would undercount two occurrences on one line.
# THE INSTRUMENT MUST NOT COUNT ITSELF.
#
# This script and its count file both NAME the namespaces, in prose, in
# order to explain what they are for. Without these exclusions the gate
# measures its own documentation: widening the regex made the number rise
# purely because the new comment mentioned the new domain. A guard whose
# reading moves when you edit its comments is measuring the wrong thing.
#
# THE PATHS BELOW ARE VERIFIED TO EXIST, by the companion test, because an
# exclusion pathspec that names a file which is not there is silently a
# no-op: `git grep` accepts it, excludes nothing, and the count quietly
# includes the very file the line was written to remove. The first draft of
# this list said `tests/test_...` when the test lives at `scripts/tests/`,
# so the gate went on counting its own test and nothing said a word.
#
# THE FOURTH ENTRY IS THE MIGRATION TOOL, AND THIS GATE ADDED IT BY FIRING.
# scripts/migrate_graph_namespace.py rewrites pwg-branded identifiers in a live
# store, so it must CARRY the patterns it rewrites FROM -- 15 occurrences, in
# its rules and in the docstring explaining why they are wrong. The gate
# counted them and went red on the very commit that finishes the migration.
# That is the instrument measuring itself, exactly as with the three files
# above, and the same category: a file whose job is to police or perform the
# thing has to be able to name it.
#
# It is the ONLY kind of file that earns a place here. Every exclusion is
# somewhere a real occurrence can hide later, which is why two documentation
# files that merely MENTIONED the namespaces were rewritten instead of listed.
SELF=(
  ":(exclude)scripts/verify_no_foreign_ontology_namespace.sh"
  ":(exclude)scripts/.foreign-ontology-namespace-count"
  ":(exclude)scripts/tests/test_no_foreign_ontology_namespace.sh"
  ":(exclude)scripts/migrate_graph_namespace.py"
  # ...and the migrator's own test, added 2026-08-21. Same category, and the
  # distinction from an earlier case is worth keeping. On #888 a sibling test
  # was NEUTRALISED rather than listed, correctly: those fixtures exercised
  # N-Quads ARITY and `_nquads_is_quad` never inspects a domain, so the
  # namespace was incidental and neutralising cost nothing.
  #
  # This file is the other kind. It drives the migrator against its REAL RULES:
  # `preview_graph_names({"urn:pwg:user/Andy": 20, ...}, M.RULES)` only means
  # anything because that graph name is one the rules actually map. Swap in a
  # neutral name and `new_graph_iri` returns nothing, the collision check has
  # no collision to find, and the test asserts an empty truth while staying
  # green. A test that cannot name the thing it polices is not a test.
  ":(exclude)scripts/test_migrate_graph_namespace.py"
)
# ── Diff files are read as diffs, NOT excluded ───────────────────────────
#
# A `.patch` under vendor/divergences/ is a DIFF, and a leading '-' means the
# line was REMOVED. Counting a deletion as an occurrence reads ABSENCE AS
# PRESENCE -- the gate fails the very commit that records the namespace being
# stripped out.
#
# Measured 2026-08-28 on CM051 #1219, which regenerated doctor.patch:
#     vendor/divergences/doctor.patch:5249:-    @prefix pwg: <https://pwg.dev/ontology#> .
#     vendor/divergences/doctor.patch:5258:-PWG_PREFIX_URL = "https://pwg.dev/ontology#"
#     vendor/divergences/doctor.patch:5267:-        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
# occurrences=3, declared=0, gate RED. All three are '-' lines, and the control
# is decisive: `git grep -c pwg.dev -- vendor/doctor/` returns ZERO files, with
# a must-be-present control (ServiceHealthInfo, 10 hits) proving the search
# works. The shipped tree is clean; the patch is the RECORD of it being cleaned.
#
# NOT an entry in SELF, deliberately. This file's own doctrine is that an
# exclusion is "somewhere a real occurrence can hide later", and that is right:
# a '+' line in a divergence patch is a line the VENDORED tree carries, and it
# still counts here. The patch is generated as `diff source@pinned_sha ->
# vendored tree` (scripts/regenerate_divergence_patch.sh:298), so the sign is
# not a convention, it is definitional. Read the sign; do not look away.
# NOTE the files counter below reads the WORKING TREE, the same bytes
# `git grep` reads with no ref. An earlier draft read `git show HEAD:` and
# reported occurrences=1 files=0 on an uncommitted addition -- a true count
# beside a false one, which is worse than either being wrong on its own.
PATCH_GLOB="vendor/divergences/*.patch"
_src_hits="$(git grep -ohE "$FOREIGN_RE" -- . "${SELF[@]}" ":(exclude)${PATCH_GLOB}" 2>/dev/null | grep -c . || true)"
_patch_hits="$(git grep -hE "$FOREIGN_RE" -- "${PATCH_GLOB}" 2>/dev/null \
                 | grep -E '^\+' | grep -ohE "$FOREIGN_RE" | grep -c . || true)"
actual=$(( _src_hits + _patch_hits ))
_src_files="$(git grep -lE "$FOREIGN_RE" -- . "${SELF[@]}" ":(exclude)${PATCH_GLOB}" 2>/dev/null | grep -c . || true)"
_patch_files="$(for _p in $(git grep -lE "$FOREIGN_RE" -- "${PATCH_GLOB}" 2>/dev/null); do
                  grep -qE "^\+.*${FOREIGN_RE}" "$_p" 2>/dev/null && echo "$_p"
                done | grep -c . || true)"
files=$(( _src_files + _patch_files ))

echo "foreign ontology namespace: occurrences=${actual} files=${files} declared=${declared}"

if [ "${actual:-0}" -gt "$declared" ]; then
    echo >&2
    echo "WARN: the count went UP, ${declared} -> ${actual}." >&2
    echo "  Something new is stamping a pwg-branded domain into customer data." >&2
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

# The breakdown is printed rather than a single total, because the two domains
# are wrong for different reasons and a reader who only sees "294" cannot tell
# which migration is outstanding. It also keeps the sentence TRUE: only the
# first of them is unregistered, and calling all 294 unregistered would be the
# same kind of small false statement this gate exists to stop.
n_dev="$(git grep -ohE 'pwg\.dev' -- . "${SELF[@]}" 2>/dev/null | grep -c . || true)"
n_local="$(git grep -ohE 'pwg\.local' -- . "${SELF[@]}" 2>/dev/null | grep -c . || true)"

echo "GATE: GREEN -- at the declared count of ${declared}, not above it."
echo "  This is a RATCHET, not an endorsement. ${actual} occurrences of a"
echo "  pwg-branded namespace remain in customer-facing identifiers:"
echo "    ${n_dev} on an UNREGISTERED domain, which anyone can buy"
echo "    ${n_local} on a domain reserved for mDNS, which nobody can own"
echo "  Migration target: ${OURS}"
exit 0
