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

echo
echo "  $PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
echo "ALL ENRICHMENT IDENTITY + DISCLOSURE CONTROLS PASSED"
