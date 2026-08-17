#!/usr/bin/env bash
#
# test_enrichment_reaches_the_corpus.sh -- guards CM051 #746.
#
# WHAT HAPPENED, measured from ~/.ostler/logs/install.log on a real install,
# 2026-08-17, install window 15:01Z to 15:22Z:
#
#     enrich --all      62 of 7,773 preferences processed
#     book              10 processed   0 enriched   10 failed
#     movie             24 processed   0 enriched   24 failed   in 0.2s
#     music             28 processed   1 enriched   27 failed
#     total duration    1247.3s
#
# Three separate defects, and NONE of them was a missing writer. The writer
# exists at enricher.py `_store_enrichment` and works: the single success is
# in Oxigraph, and `enrich stats` counts it. What was wrong:
#
#   1. `--all` meant the three string literals "book", "movie", "music"
#      while CATEGORY_CLIENTS held 27 categories. bookmark (4,714 items),
#      interest (569), page (516), place (84), education (106) and food (13)
#      were never offered to enrichment at all.
#
#   2. Movies failed in 0.2 SECONDS because we ship no TMDB key. 24 items
#      dispatched to a client that cannot work, recorded as failures, and
#      retried on every future run forever.
#
#   3. THE ONE THAT IS NOT A DATA-QUALITY PROBLEM. One of the ten book
#      lookups sent openlibrary.org a 400-character LinkedIn recommendation
#      about a named individual, as a book title, because a classifier put
#      it in `book`. Personal text about a real person left the customer's
#      Mac as a third-party query. That lands against "nothing about you
#      ever leaves", so the guard belongs at the EGRESS boundary rather than
#      the classifier: it then holds for every future classifier error, not
#      just the ones we have seen.
#
# WHAT IS BEHAVIOURAL HERE AND WHAT IS STRUCTURAL, stated rather than left
# to be discovered: sections 1 and 2 import and RUN the predicate, including
# a red proof. Section 4 runs the category derivation only when the
# enrichment tree's dependencies are importable, and PRINTS A SKIP NAMING
# WHAT WENT UNCOVERED when they are not. Section 3 and section 5 are
# structural, because reaching them behaviourally needs the whole client
# tree constructed.
#
# EXIT: 0 all assertions hold. 1 one or more failed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/vendor/cm019_preferences/services/enrich/src"
PY="${PYTHON_BIN:-python3}"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1));
        [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; }
skip(){ printf '  \033[0;33mSKIP\033[0m %s\n' "$1"; }

echo "CM051 #746: enrichment reaches the corpus, and only sends what it should"
echo

[ -d "$SRC" ] || { echo "CANNOT-RUN: no enrichment tree at $SRC" >&2; exit 2; }
[ -f "$SRC/eligibility.py" ] || { bad "eligibility.py is missing"; exit 1; }

# SYNTHETIC, and the shape is what is load-bearing: over the word ceiling,
# sentence-ending punctuation, third-person and first-person narrative. The
# strings that reached OpenLibrary were a real testimonial about a named
# individual and a real narrative naming a person, an agency and a regulator.
# This repo is PUBLIC, so they are not reproduced here. Truncating a
# testimonial is not anonymising it. If either of these now PASSES the guard
# that is a finding about the guard, not about the fixture.
PROSE='Marta is an exceptionally customer-focussed operator, and she knows how to handle a difficult account. She defuses situations that could easily escalate, and she does it without ever raising her voice or losing the thread.'
NARRATIVE='I first met Devesh when Northwind pitched for the Fenwick Trust account, and he was outstanding from the first meeting through to the handover.'

# ── 1. BEHAVIOURAL. The predicate refuses prose and allows real titles.
#
#    Both halves matter. A gate that refuses everything would pass the
#    refusal assertions alone while silently ending enrichment, so the
#    allow-list here is a positive control, not decoration.
elig_out="$("$PY" - "$SRC" "$PROSE" "$NARRATIVE" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import eligibility as e
prose, narrative = sys.argv[2], sys.argv[3]

must_allow = [
    ("openlibrary", "Animal Farm"),
    ("openlibrary", "1984 - George Orwell"),
    ("openlibrary", "Hitchhiker's Guide To The Galaxy"),
    ("openlibrary", "Business Model You: A One-Page Method For Reinventing Your Career"),
    ("musicbrainz", "Radiohead"),
    ("wikidata",    "behavioural economics"),
    ("google_places", "Fuel Espresso"),
]
must_refuse = [
    ("openlibrary", prose),
    ("musicbrainz", narrative),
    ("wikidata",    "x" * 400),
    ("musicbrainz", "line one\nline two"),
    ("openlibrary", "   "),
]
# Not gated: these clients do not put the subject in a query.
must_ignore = [("url_fetcher", prose), ("youtube", prose)]

bad = []
for c, s in must_allow:
    good, why = e.is_eligible(c, s)
    if not good:
        bad.append("REFUSED a real title via %s: %s" % (c, why))
for c, s in must_refuse:
    good, why = e.is_eligible(c, s)
    if good:
        bad.append("ALLOWED something it must refuse via %s" % c)
for c, s in must_ignore:
    good, _ = e.is_eligible(c, s)
    if not good:
        bad.append("gated %s, which does not send the subject anywhere" % c)

# The reason must never quote the subject back: it is the thing we just
# decided was too sensitive to pass around.
_, why = e.is_eligible("openlibrary", prose)
if why and ("Simon" in why or "customer-focussed" in why):
    bad.append("the rejection reason quotes the subject it refused")

print("OK" if not bad else "\n".join(bad))
PYEOF
)"
if [ "$elig_out" = "OK" ]; then
    ok "prose and personal narrative are refused; 7 real titles and names are allowed"
else
    bad "the egress predicate does not behave" "$elig_out"
fi

# ── 2. PROVE RED, ONE AXIS AT A TIME.
#
#    The first version of this section neutered the length and word limits
#    together and required the real prose fixture to leak. It did not leak,
#    and the suite reported a broken red proof. That was correct: the real
#    fixture trips length AND word count AND the sentence-boundary check, so
#    disabling two of three proves nothing about any of them.
#
#    A control has to be varied along the axis the instrument actually
#    reads. So: three fixtures, each caught by exactly ONE check, and for
#    each one the matching check is disabled in a copy and the fixture is
#    required to get through. That is what makes each limit load-bearing
#    rather than merely present.
TMP="$(mktemp -d -t enrich746_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

red_axis() {   # <name> <sed-expr disabling one check> <fixture>
    local name="$1" disable="$2" fixture="$3"
    sed -e "$disable" "$SRC/eligibility.py" > "$TMP/eligibility.py"
    rm -rf "$TMP/__pycache__"
    local out
    out="$("$PY" - "$TMP" "$fixture" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import eligibility as e
allowed, _ = e.is_eligible("openlibrary", sys.argv[2])
print("LEAKED" if allowed else "STILL-REFUSED")
PYEOF
)"
    if [ "$out" = "LEAKED" ]; then
        ok "PROVED RED ($name): disabling this check alone lets its fixture reach the network"
    else
        bad "PROVED-RED FAILED ($name): the fixture is still refused with the check disabled, so the check is not what stops it"
    fi
    # Confirm the SAME fixture is refused by the unmodified module, or the
    # red proof above is measuring a fixture nothing ever caught.
    out="$("$PY" - "$SRC" "$fixture" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import eligibility as e
allowed, _ = e.is_eligible("openlibrary", sys.argv[2])
print("LEAKED" if allowed else "REFUSED")
PYEOF
)"
    [ "$out" = "REFUSED" ] && ok "  ...and the shipped module refuses that same fixture" \
                           || bad "  ...but the shipped module ALLOWS it: the check does not work at all"
}

# 400 characters, one word: only the length limit can catch this.
red_axis "length" 's/^MAX_CHARS = .*/MAX_CHARS = 100000/' "$(printf 'x%.0s' {1..400})"
# 20 short words, 39 chars, no sentence boundary: only the word ceiling.
red_axis "word count" 's/^MAX_WORDS = .*/MAX_WORDS = 100000/' "a b c d e f g h i j k l m n o p q r s t"
# Two short sentences, well inside both limits: only the boundary check.
red_axis "sentence boundary" \
    's/^_SENTENCE_JOIN = .*/_SENTENCE_JOIN = re.compile(r"ZZ_NEVER_MATCHES_ZZ")/' \
    "It was good. He said so."

# And the defence-in-depth claim, stated because it is why the first red
# proof failed: the REAL fixture is caught by more than one check, so no
# single regression re-opens it.
depth_out="$("$PY" - "$SRC" "$PROSE" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import eligibility as e
s = sys.argv[2].strip()
hits = 0
if len(s) > e.MAX_CHARS: hits += 1
if len(s.split()) > e.MAX_WORDS: hits += 1
if e._SENTENCE_JOIN.search(s): hits += 1
print(hits)
PYEOF
)"
[ "${depth_out:-0}" -ge 2 ] && ok "the real prose fixture trips $depth_out independent checks, not one" \
                            || bad "the real prose fixture is caught by only $depth_out check: one regression re-opens the leak"

# ── 3. STRUCTURAL. The gate is CALLED, on the path that sends the query.
#    A predicate nothing invokes is the same defect one layer down.
n_import="$(grep -c 'from .eligibility import is_eligible' "$SRC/enricher.py")"
[ "$n_import" -ge 1 ] && ok "enricher.py imports the egress predicate" \
                      || bad "enricher.py does not import is_eligible, so the module is dead code"

# Must sit inside enrich_batch, BEFORE enrich_preference dispatches.
batch_body="$(awk '/    async def enrich_batch/,/    async def enrich_all/' "$SRC/enricher.py")"
n_call="$(printf '%s' "$batch_body" | grep -c 'is_eligible(')"
[ "$n_call" -ge 1 ] && ok "enrich_batch consults the predicate before dispatching" \
                    || bad "enrich_batch never calls is_eligible: subjects still reach clients ungated"

n_before="$(printf '%s' "$batch_body" | grep -n 'is_eligible(\|await self.enrich_preference' | head -2 | grep -c 'is_eligible')"
[ "$n_before" -eq 1 ] && ok "the predicate runs BEFORE enrich_preference, not after the request" \
                      || bad "is_eligible is not the first of the two: a guard after the call has already spent the egress"

# ── 4. The sweep is derived from the dispatch table, not a literal list.
#
#    Structural half first: the three-string literal must be gone.
n_literal="$(grep -c '\["book", "movie", "music"\]' "$SRC/cli.py")"
[ "$n_literal" -eq 0 ] && ok "the hardcoded three-category list is gone from cli.py" \
                       || bad "cli.py still hardcodes [\"book\", \"movie\", \"music\"] for --all"

n_derive="$(grep -c 'enrichable_categories()' "$SRC/cli.py")"
[ "$n_derive" -ge 1 ] && ok "cli.py derives --all from the dispatch table" \
                      || bad "cli.py does not call enrichable_categories(), so --all is still a fixed list"

#    Behavioural half, when the tree's dependencies are importable.
# The precondition is the import ITSELF, not a hand-listed set of module
# names. Listing them by hand is how this first went wrong: I named
# pydantic_settings, the tree also needed httpx, and then aiolimiter, and
# each missing one turned an honest skip into a traceback. Attempting the
# real import cannot drift from what the real import needs.
cat_out="$("$PY" - "$REPO/vendor/cm019_preferences" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1])
os.environ.pop("TMDB_API_KEY", None)
try:
    from services.enrich.src.enricher import EnrichmentService as S
except ImportError as exc:
    print("SKIP:%s" % exc)
    raise SystemExit(0)

bad = []
cats = S.enrichable_categories()
if len(cats) <= 3:
    bad.append("only %d categories are enrichable; the defect was 3" % len(cats))
for expected in ("bookmark", "interest", "page", "book", "music"):
    if expected not in cats:
        bad.append("%s is dispatchable but not in the sweep" % expected)

# Films and places are now KEYLESS, routed to Wikidata rather than to
# TMDB and Google Places, so they must be SWEPT rather than excluded.
for expected in ("movie", "movie_tv", "tv", "place", "venue", "education", "food"):
    if expected not in cats:
        bad.append("%s is not swept; it should route to a keyless client" % expected)
for cat, client in (("movie", "wikidata_film"), ("tv", "wikidata_film"),
                    ("place", "wikidata_place"), ("venue", "wikidata_place"),
                    ("education", "wikidata"), ("food", "wikidata")):
    if S.CATEGORY_CLIENTS.get(cat) != client:
        bad.append("%s routes to %r, expected %r" % (cat, S.CATEGORY_CLIENTS.get(cat), client))

# Andy excluded `professional` explicitly. Asserted so that adding it back
# is a decision someone has to make against a failing test, not a drift.
if "professional" in S.CATEGORY_CLIENTS:
    bad.append("professional has a client; Andy excluded it on 2026-08-17")

# No credential -> excluded, and NAMED as excluded rather than silently
# gone. `video` still needs a YouTube key, so it carries this control now
# that films no longer do.
os.environ.pop("YOUTUBE_API_KEY", None)
missing = S.categories_missing_credentials()
if "video" in S.enrichable_categories():
    bad.append("video is swept with no YouTube key, so it can only fail")
if "video" not in missing:
    bad.append("video is skipped but not reported as needing a credential")

# The discriminating control: with a key present, video comes back. Without
# this, "video is excluded" could be a predicate that excludes everything.
os.environ["YOUTUBE_API_KEY"] = "test-key-not-a-real-credential"
if "video" not in S.enrichable_categories():
    bad.append("video stays excluded even WITH a key: the check is not reading the credential")

print("OK" if not bad else "\n".join(bad))
PYEOF
)"
case "$cat_out" in
    OK)
        ok "the sweep covers every dispatchable category, and key-gated ones are excluded AND named" ;;
    SKIP:*)
        skip "category derivation not run behaviourally: ${cat_out#SKIP:}"
        skip "     NOT COVERED: enrichable_categories() breadth, credential exclusion, credential control."
        skip "     Fix by installing vendor/cm019_preferences/requirements.txt, as CI does." ;;
    *)
        bad "category derivation does not behave" "$cat_out" ;;
esac

# ── 5. STRUCTURAL. The wall-clock allowance exists and is threaded.
#
#    A budget that is not passed down is not a budget. Assert it reaches
#    all three levels, and that a spent allowance is never called COMPLETE.
n_thread="$(grep -c 'deadline=deadline' "$SRC/enricher.py")"
[ "$n_thread" -ge 2 ] && ok "the allowance is threaded from the sweep down to the batch ($n_thread sites)" \
                      || bad "deadline is accepted but not passed down ($n_thread call sites)"

n_cli="$(grep -c 'deadline=deadline' "$SRC/cli.py")"
[ "$n_cli" -ge 2 ] && ok "the CLI passes its allowance to both single- and multi-category paths" \
                   || bad "the CLI computes a deadline it does not hand over ($n_cli sites)"

n_pause="$(grep -c 'budget_exhausted' "$SRC/cli.py")"
[ "$n_pause" -ge 1 ] && ok "a pass that spends its allowance is not reported as COMPLETE" \
                     || bad "cli.py prints COMPLETE regardless: an unfinished corpus reads as a finished one"

n_flag="$(grep -c 'stats.budget_exhausted = True' "$SRC/enricher.py")"
[ "$n_flag" -ge 2 ] && ok "the exhausted flag is set at both the item and category boundary" \
                    || bad "budget_exhausted is set in $n_flag place(s); it needs the item loop AND the category loop"

# ── 6. The installer must not print one number under the other's name.
#
#    "Imported and enriched %s preferences" was formatted with the Qdrant
#    points_count. On 2026-08-17 that read 2,963 while enrichment's own
#    successful count for the same run was 1.
STRINGS="$REPO/install.sh.strings.en-GB.sh"
n_conflated="$(grep -c 'MSG_HYDRATE_PREFERENCES_DONE="Imported and enriched' "$STRINGS")"
[ "$n_conflated" -eq 0 ] && ok "the ingest count is no longer labelled as an enrichment count" \
                         || bad "install.sh still prints the INGEST count under the words 'and enriched'"

n_enr_str="$(grep -c '^MSG_HYDRATE_PREFERENCES_ENRICHED=' "$STRINGS")"
[ "$n_enr_str" -eq 1 ] && ok "a separate string exists for the enriched count" \
                       || bad "no MSG_HYDRATE_PREFERENCES_ENRICHED: there is nowhere to state the real number"

# It has to be read from where enrichment WRITES, not from Qdrant again.
n_pred="$(grep -c 'pwg:enrichedAt' "$REPO/install.sh")"
[ "$n_pred" -ge 1 ] && ok "the enriched count is read from pwg:enrichedAt, the predicate enrichment writes" \
                    || bad "install.sh never queries pwg:enrichedAt, so the second number has no source"

n_used="$(grep -c 'MSG_HYDRATE_PREFERENCES_ENRICHED' "$REPO/install.sh")"
[ "$n_used" -ge 1 ] && ok "the enriched string is actually printed" \
                    || bad "MSG_HYDRATE_PREFERENCES_ENRICHED is defined and never used"


# ── 7. ENRICHED PEOPLE ARE NOT THE CUSTOMER'S PEOPLE.
#
#    Andy asked, on seeing Bryan Cranston and Vince Gilligan come back as
#    entities: do these get merged into People, or into the customer's
#    contacts? They must not. An actor is a fact ABOUT a film someone
#    watched, not someone they know, and a graph that confuses the two
#    produces a contact list full of strangers.
#
#    Measured: they cannot, for TWO independent reasons.
#
#      a) DIFFERENT CLASS. Enrichment writes `a pwg:Entity`. The wiki's
#         People pages are built from `?uri a pwg:Person`.
#      b) DIFFERENT NAMESPACE. Enrichment writes into
#         http://pwg.local/ontology#, the people/meetings graph uses
#         https://pwg.dev/ontology#. The same short name `pwg:` expands to
#         two different IRIs, so even the class names cannot collide.
#
#    (b) IS NOT SOMETHING TO PIN, AND MY FIRST VERSION OF THIS TEST GOT
#    THAT WRONG. It asserted that enrichment writes http://pwg.local/... ,
#    which would make this suite fight #743, the migration that exists
#    BECAUSE pwg.dev is unregistered and pwg-branded namespaces should not
#    be stamped into a customer's graph at all. A guard that pins the thing
#    we are removing is worse than no guard.
#
#    So what is asserted is the RELATIONSHIP, not the literal: the two
#    namespaces must DIFFER, whatever they are. That survives any migration,
#    and if some future tidy-up unifies them this goes red and somebody has
#    to decide on purpose rather than by accident.
#
#    (Separately: pwg.local is a THIRD pwg-branded namespace and the #802
#    ratchet's regex is `pwg\.dev` only, so it does not see it. Widening
#    that ratchet is the real fix and is not this file's job.)
PEOPLE_NS='pwg.dev/ontology'
ENRICH_NS="$(grep -ohE 'https?://[a-z0-9./-]+/ontology#' "$SRC/enricher.py" | sort -u | head -1)"
[ -n "$ENRICH_NS" ] && ok "enrichment declares an ontology namespace ($ENRICH_NS) (positive control)" \
                    || bad "no ontology namespace found in enricher.py; this check is measuring nothing"

case "$ENRICH_NS" in
    *"$PEOPLE_NS"*)
        bad "enrichment now writes into the SAME namespace as people/meetings ($PEOPLE_NS); the accidental separation between an actor and a contact is gone" ;;
    *)
        ok "enrichment's namespace differs from the people/meetings namespace, whatever each is" ;;
esac

n_entity="$(grep -c 'a pwg:Entity' "$SRC/models/enrichment.py")"
[ "$n_entity" -ge 1 ] && ok "enriched actors and directors are typed pwg:Entity, a class the People query does not select" \
                      || bad "entities are no longer typed pwg:Entity; whatever they are now may be selected as people"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL #746 CONTROLS PASSED"
