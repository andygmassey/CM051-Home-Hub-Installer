#!/usr/bin/env bash
#
# test_enrichment_identity_and_disclosure.sh
#
# WHAT THIS GUARDS, measured 2026-08-17 on main.
#
# install.sh:13217 runs `services.enrich.src.cli enrich --all`. Its clients
# reach Wikidata, MusicBrainz, OpenLibrary and -- through url_fetcher -- the
# customer's own bookmarked URLs. Every one of those third parties receives the
# customer's IP, the query, and a User-Agent WE choose. There were 23 of them
# and they said, variously:
#
#   PWG-Enrichment/0.1.0                      the retired internal project name
#   ... contact: github.com/andybrandt        an account that is not ours
#   ... https://github.com/pwg                does not exist
#   ... mailto:pwg@example.com                a placeholder, sent to Crossref's
#                                             polite pool, which is worse than
#                                             sending nothing
#   Mozilla/5.0 ... Chrome/120.0.0.0 Safari   asin.py impersonating a browser
#                                             to scrape Amazon
#
# The last one is a different kind of thing from the others. Sending a fake
# browser User-Agent is not a naming problem, it is misrepresenting what we are
# to a site whose terms forbid it -- the same class of exposure as the WhatsApp
# connector, which we gate behind a consent ceremony that names Meta.
#
# "PWG" is also the rule that keeps gamingrig and Andypedia out of the product,
# except this one reaches a THIRD PARTY'S logs and stays there.
#
# AND THE DISCLOSURE HALF. install.sh told the customer Ostler makes "narrow
# public-data queries (Wikidata for enrichment...)". Wikidata is one of the
# live set. Naming one of four is not disclosing four, and this paragraph
# exists so a customer can check it.
#
# PROVED-RED-BY: control 5, which reintroduces the browser User-Agent into a
# copy of the tree and requires the predicate to fire.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENRICH="$REPO_ROOT/vendor/cm019_preferences/services/enrich/src"
INSTALL_SH="$REPO_ROOT/install.sh"

PASS=0; FAILED=0
ok()      { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
failure() { printf '  FAIL  %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /' >&2; FAILED=$((FAILED+1)); }

echo "test_enrichment_identity_and_disclosure"
echo

[ -d "$ENRICH" ] || { echo "CANNOT-RUN: no enrichment tree at $ENRICH" >&2; exit 2; }
[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh" >&2; exit 2; }

# count_in <needle> <dir> -- literal, case-insensitive, -c per file then summed.
# grep -q under pipefail is a SIGPIPE race, so this counts rather than tests.
count_in() { grep -rci --include="*.py" --exclude-dir=__pycache__ -e "$1" "$2" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}'; }

# ── 1. POSITIVE CONTROL. Without this, every zero below is uninterpretable:
#       an empty or missing tree would report "no bad strings found".
n_ua="$(count_in 'user-agent' "$ENRICH")"
n_ours="$(count_in 'Ostler/1.0' "$ENRICH")"
if [ "$n_ua" -lt 15 ]; then
    failure "only $n_ua User-Agent sites found in the enrichment tree -- expected 15+. The scan is not reaching the code, so its clean result means nothing."
elif [ "$n_ours" -lt 15 ]; then
    failure "only $n_ours sites carry the Ostler User-Agent, out of $n_ua -- the replacement did not land everywhere"
else
    ok "$n_ua User-Agent sites, $n_ours carrying the Ostler identity (positive control)"
fi

# ── 2. THE ONE THAT IS NOT A NAMING PROBLEM. No browser impersonation.
for needle in 'Mozilla/5.0' 'AppleWebKit' 'Chrome/1' 'Safari/537'; do
    n="$(count_in "$needle" "$ENRICH")"
    if [ "$n" -gt 0 ]; then
        failure "$n occurrence(s) of '$needle' -- a shipped client is impersonating a browser to a third party" \
                "$(grep -rn --include="*.py" --exclude-dir=__pycache__ -e "$needle" "$ENRICH" | head -5)"
    else
        ok "no '$needle' in any shipped enrichment client"
    fi
done

# ── 3. The retired internal name must not reach a third party's logs.
n="$(count_in 'PWG-' "$ENRICH")"
[ "$n" -eq 0 ] && ok "no 'PWG-' identity string reaches a third party" \
               || failure "$n occurrence(s) of the retired 'PWG-' name in outbound identity" "$(grep -rn --include="*.py" --exclude-dir=__pycache__ -e 'PWG-' "$ENRICH" | head -5)"

# ── 4. No contact pointing at an account that is not ours, and no placeholder
#       address sent to a real API.
for needle in 'andybrandt' 'github.com/pwg' 'pwg@example.com'; do
    n="$(count_in "$needle" "$ENRICH")"
    [ "$n" -eq 0 ] && ok "no '$needle' in outbound identity" \
                   || failure "$n occurrence(s) of '$needle' in a string we send to third parties" "$(grep -rn --include="*.py" --exclude-dir=__pycache__ -e "$needle" "$ENRICH" | head -5)"
done

# ── 4b. THE ONE THAT IS NOT A LITERAL, AND SO SURVIVED THE FIRST SWEEP.
#
#       22 clients carry their User-Agent as a string, so replacing the
#       strings fixed them. MusicBrainz composes its one from settings:
#       config.py builds "<name>/<version> ( <contact> )". Editing strings
#       could not reach it, and it was still on version 0.1.0 with an EMPTY
#       contact, which MusicBrainz's own policy asks for by name.
#
#       Caught only by computing the composed value rather than grepping
#       for the identity literal. Every control above would stay green with
#       this wrong, which is exactly why it needs its own.
CONF="$ENRICH/config.py"
mb_name="$(grep -A1 'musicbrainz_app_name' "$CONF" | grep -o 'default="[^"]*"' | head -1)"
mb_vers="$(grep -A1 'musicbrainz_app_version' "$CONF" | grep -o 'default="[^"]*"' | head -1)"
mb_cont="$(grep -A1 'musicbrainz_contact' "$CONF" | grep -o 'default="[^"]*"' | head -1)"

[ "$mb_name" = 'default="Ostler"' ] && ok "MusicBrainz identity name is Ostler" \
                                    || failure "MusicBrainz app name default is $mb_name, not Ostler"
[ "$mb_vers" = 'default="1.0"' ] && ok "MusicBrainz identity version matches the other 22 clients (1.0)" \
                                 || failure "MusicBrainz version default is $mb_vers; every other client sends 1.0"
[ -n "$mb_cont" ] && [ "$mb_cont" != 'default=""' ] \
    && ok "MusicBrainz identity carries a contact, which their policy requires" \
    || failure "MusicBrainz contact default is empty, so we send no way to reach us, against their stated policy"

# ── 5. PROVE RED. Reintroduce the browser User-Agent in a scratch copy and
#       require control 2's predicate to fire. Without this the greens above
#       could be measuring an empty set.
TMP="$(mktemp -d -t enrichid_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
printf 'HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh) Chrome/120.0.0.0 Safari/537.36"}\n' > "$TMP/src/planted.py"
n_planted="$(count_in 'Mozilla/5.0' "$TMP/src")"
[ "$n_planted" -eq 1 ] && ok "PROVED RED: a planted browser User-Agent is detected by the same predicate" \
                       || failure "the planted browser User-Agent was NOT detected (got $n_planted) -- control 2 cannot fail, so its green is worthless"

# ── 6. THE DISCLOSURE HALF. The installer must name the live reference set,
#       not one member of it. Asserts the SET, so adding a source without
#       updating the copy fails here.
for src in 'Wikidata' 'MusicBrainz' 'OpenLibrary'; do
    n="$(grep -c -- "$src" "$INSTALL_SH")"
    [ "$n" -gt 0 ] && ok "installer disclosure names $src" \
                   || failure "the installer never names $src, which enrichment contacts on a stock install"
done
n="$(grep -c 'bookmarked' "$INSTALL_SH")"
[ "$n" -gt 0 ] && ok "installer discloses that bookmarked links are followed" \
               || failure "url_fetcher follows the customer's bookmarked URLs and the installer does not say so"

# ── 7. THE CONSENT COPY MAY NOT PROMISE A CONTROL WE DO NOT SHIP.
#
#      A draft of section 6's paragraph said "You can turn them off in
#      Settings". Measured 2026-08-17 on this tree, there is no such control:
#      every OSTLER_ENRICH_* knob is a THROTTLE (budget, concurrency,
#      interval, namespace, user), no installer question offers an opt-out,
#      and no settings surface mentions enrichment at all.
#
#      That is a worse defect than the thin list section 6 replaced. The old
#      copy was incomplete; an invented off switch is UNTRUE, on a consent
#      screen, about the one subject where we are asking to be believed.
#
#      So this control COUPLES THE CLAIM TO THE MECHANISM rather than banning
#      a phrase. It fails only when the copy promises an off switch and the
#      tree does not have one. Build the switch and this goes green with the
#      promise in place; write the promise alone and it goes red. Either half
#      can move without the other rotting silently.
#      THE INSTRUMENT MUST NOT COUNT ITS OWN DOCUMENTATION. The first draft of
#      this control grepped install.sh whole and reported 1 promise against a
#      tree that makes none: the single match was the COMMENT above the fixed
#      copy, quoting the false sentence in order to explain why it was removed.
#      A guard whose reading moves when you edit a comment is measuring the
#      wrong thing, so only real emitted lines are counted. Same trap as the
#      SELF exclusions in verify_no_foreign_ontology_namespace.sh.
promises_off="$(grep -vE '^[[:space:]]*#' "$INSTALL_SH" \
                | grep -cE 'turn (them|it|enrichment) off|disable (them|it|these lookups)|opt out of (them|these)')"

# The mechanism, if it exists, is a SWITCH and not a throttle. A budget of
# zero means "no limit" in this codebase, so a knob is not an answer here.
has_switch="$(git -C "$REPO_ROOT" grep -lE 'OSTLER_ENRICH(MENT)?_(ENABLED|DISABLED)|ENRICHMENT_OPT_OUT|--no-enrich' \
                  -- . ':(exclude)tests/*' 2>/dev/null | grep -c . || true)"

if [ "$promises_off" -gt 0 ] && [ "$has_switch" -eq 0 ]; then
    failure "the consent copy promises an enrichment off switch and the tree ships none ($promises_off claim(s), 0 mechanisms)"
elif [ "$promises_off" -eq 0 ] && [ "$has_switch" -eq 0 ]; then
    ok "the consent copy claims no off switch, and correctly so: this tree ships none"
    ok "     NOT COVERED, and it is a product gap not a test gap: a customer who reads"
    ok "     the disclosure has no supported way to decline it. Filed as its own row."
elif [ "$promises_off" -gt 0 ]; then
    ok "an enrichment off switch exists and the consent copy tells the customer about it"
else
    failure "an enrichment off switch now exists ($has_switch site(s)) and the consent copy never mentions it"
fi

echo
echo "  $PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
echo "ALL ENRICHMENT IDENTITY + DISCLOSURE CONTROLS PASSED"
