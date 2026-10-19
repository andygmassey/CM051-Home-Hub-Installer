# shellcheck shell=bash
# lib/owner_employer_seed.sh -- the owner's employer, through the CUSTOMER's
# own import path (v1.0.107 #10, owner_digest_knows_the_owner).
#
# Writes a synthetic LinkedIn GDPR export holding one Positions.csv row
# (ExampleCo) into a scratch dir on the box and runs the shipped
# ~/.ostler/bin/ostler-import on it -- the same entry point the Downloads
# watcher and the install-time hydrate call, which fans it to CM041
# contact_syncer.import_all -> linkedin_career -> a PersonFact about the owner.
# Then it re-runs the context-refresh LaunchAgent and waits for CONTEXT.md to
# be rewritten, so the probe tests ingestion -> digest -> answer, end to end.
#
# A WRITER: the runner calls it only when the walk is not read-only (#2564).
# The PersonFact it leaves is synthetic and keyed by a content hash, so a
# re-run is a no-op; a walk box is reset between walks.
#
# Exports, for the probe:
#   OSTLER_OWNER_SEED_ORG    the organisation seeded (synthetic)
#   OSTLER_OWNER_SEED_STATE  seeded | failed | skipped-read-only | unrun
OSTLER_OWNER_SEED_ORG="${OSTLER_OWNER_SEED_ORG:-ExampleCo}"
OSTLER_OWNER_SEED_STATE="unrun"
export OSTLER_OWNER_SEED_ORG OSTLER_OWNER_SEED_STATE

_oes_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

# THE COUNT, shared by the apply and the forget so "seeded" and "removed" are
# read off the same predicate: PersonFacts carrying all three of source
# linkedin_positions, the seed organisation and the seed title, the triples
# linkedin_career.import_positions writes (vendor/cm041/contact_syncer/
# linkedin_career.py:232-240). Box-side text; curl and python are overridable
# only so a test can stand in for Oxigraph.
_OES_TITLE="Staff engineer"

# THE SEED PERSON ALSO NEEDS AN INTERACTION (walk #31, v1.0.108). The owner
# digest ranks "People you interact with most" (and, from those people, "Key
# organisations") by the signals the customer's ingest writes: a per-channel
# last-contact date (iMessage, WhatsApp, email) and calendar attendance, plus
# the organisation from their Contacts card. The grounding seed asserts facts
# about its synthetic person and nothing else, so on a synthetic box both
# sections were empty for want of data and the probe could never go green.
# So the seed person gets what a real contact the owner texts carries, in the
# writers' own shapes (pwg_ingest._update_last_contact: "YYYY-MM-DD"^^xsd:date;
# contact_syncer: pwg:organization), each paired with a walkSeed marker so the
# forget removes exactly what was added and nothing that was already there.
# ONLY for a person the grounding seed declared synthetic.
# THE ORGANISATION IS THE SEED PERSON'S OWN EMPLOYER, NOT A SECOND ONE (walk #32,
# v1.0.111). This defaulted to "Acme Corp" while the grounding seed says the same
# person "Works as a submarine cable engineer at example.com" (OS003
# gates/seed/seed_fixture.json, predicate employer). pwg_people renders the
# Organisation line first and the daemon tells the model to state it exactly,
# so assistant_grounds_the_opening_turn went from 10/10 (walk #31) to 1/10:
# nine replies said "at Acme Corp", faithfully, and dropped example.com. The
# fixture contradicted itself; the model did not. Keep this equal to the seed
# fixture's employer value.
OSTLER_OWNER_SEED_CONTACT_ORG="${OSTLER_OWNER_SEED_CONTACT_ORG:-example.com}"
_oes_lit() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
_oes_b64() { printf '%s' "$1" | /usr/bin/python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())'; }
_oes_interaction_apply_sparql() { # $1 person name  $2 organisation  $3 UTC date
    local n o d; n="$(_oes_lit "$1")"; o="$(_oes_lit "$2")"; d="$(_oes_lit "$3")"
    printf '%s\n' "PREFIX pwg: <https://schema.ostler.ai/ontology#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
INSERT { ?p pwg:lastContactIMessage ${d}^^xsd:date ; pwg:walkSeedLastContact ${d} }
WHERE { ?p a pwg:Person ; pwg:displayName ${n} . FILTER NOT EXISTS { ?p pwg:mergedInto ?x }
        FILTER NOT EXISTS { ?p pwg:lastContactIMessage ${d}^^xsd:date } } ;
INSERT { ?p pwg:organization ${o} ; pwg:walkSeedOrg ${o} }
WHERE { ?p a pwg:Person ; pwg:displayName ${n} . FILTER NOT EXISTS { ?p pwg:mergedInto ?x }
        FILTER NOT EXISTS { ?p pwg:organization ?any } }"
}
_oes_interaction_forget_sparql() {
    printf '%s\n' "PREFIX pwg: <https://schema.ostler.ai/ontology#>
DELETE { ?p pwg:lastContactIMessage ?d ; pwg:walkSeedLastContact ?s }
WHERE { ?p pwg:walkSeedLastContact ?s ; pwg:lastContactIMessage ?d . FILTER(STR(?d) = STR(?s)) } ;
DELETE { ?p pwg:organization ?o ; pwg:walkSeedOrg ?o }
WHERE { ?p pwg:walkSeedOrg ?o ; pwg:organization ?o }"
}
# Runs on the box after _oes_count_sh: posts base64 $1 as a SPARQL update, then
# prints how many seed-marked last-contacts the graph holds.
_oes_update_sh() {
    printf '%s\n' "\"\$OES_PY\" -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode())' '$1' | \"\$OES_CURL\" -sS --noproxy '*' -m 30 -K \"\$K\" -H 'Content-Type: application/sparql-update' --data-binary @- \"\${OXI%/query}/update\"; echo \"OES interaction update rc=\$?\"
echo \"OES interaction marked=\$(\"\$OES_CURL\" -sS --noproxy '*' -m 20 -K \"\$K\" -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary 'PREFIX pwg: <https://schema.ostler.ai/ontology#> SELECT (COUNT(*) AS ?n) WHERE { ?p pwg:walkSeedLastContact ?s }' \"\$OXI\" | \"\$OES_PY\" -c 'import json,sys; print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])' 2>&1)\""
}
_oes_count_sh() {
    printf '%s\n' "K=\${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}
OXI=\${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}
OES_CURL=\${OSTLER_OES_CURL:-/usr/bin/curl}
OES_PY=\${OSTLER_OES_PY:-/usr/bin/python3}
P='PREFIX pwg: <https://schema.ostler.ai/ontology#> '
M='?f pwg:source \"linkedin_positions\" ; pwg:organization \"${OSTLER_OWNER_SEED_ORG}\" ; pwg:jobTitle \"${_OES_TITLE}\" .'
n() { \"\$OES_CURL\" -sS --noproxy '*' -m 20 -K \"\$K\" -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary \"\${P}SELECT (COUNT(DISTINCT ?f) AS ?n) WHERE { \$M }\" \"\$OXI\" | \"\$OES_PY\" -c 'import json,sys; print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])' 2>&1; }"
}

owner_employer_seed_apply() {
    printf '%s\n' "--- OWNER EMPLOYER SEED: a synthetic LinkedIn Positions.csv through ostler-import ---"
    local out interaction=""
    if [ "${OSTLER_SEED_PERSON_IS_SYNTHETIC:-0}" = "1" ] && [ -n "${OSTLER_GATE_KNOWN_PERSON:-}" ]; then
        interaction="$(_oes_update_sh "$(_oes_b64 "$(_oes_interaction_apply_sparql "$OSTLER_GATE_KNOWN_PERSON" "$OSTLER_OWNER_SEED_CONTACT_ORG" "$(date -u +%Y-%m-%d)")")")"
    else
        interaction="echo 'OES interaction skipped: no synthetic seed person (OSTLER_SEED_PERSON_IS_SYNTHETIC / OSTLER_GATE_KNOWN_PERSON unset)'"
    fi
    out="$(_oes_box "set -u
D=\$HOME/.ostler/walk-seed/owner-linkedin/Basic_LinkedInDataExport
mkdir -p \"\$D\" || { echo 'OES no-dir'; exit 2; }
printf 'Company Name,Title,Description,Location,Started On,Finished On\n%s,Staff engineer,,Riverside,Jan 2020,\n' '${OSTLER_OWNER_SEED_ORG}' > \"\$D/Positions.csv\"
[ -x \$HOME/.ostler/bin/ostler-import ] || { echo 'OES no-importer'; exit 2; }
$(_oes_count_sh)
$interaction
echo \"OES count before=\$(n)\"
L=\$HOME/.ostler/walk-seed/owner-seed.log
\$HOME/.ostler/bin/ostler-import \"\$(dirname \"\$D\")\" >\"\$L\" 2>&1; echo \"OES import rc=\$?\"
echo \"OES importer log, last 15 lines (\$L):\"
tail -n 15 \"\$L\" 2>&1 | sed 's/^/OES log | /'
c=\$(n); echo \"OES count=\$c\"
case \"\$c\" in ''|*[!0-9]*|0) echo 'OES no career fact in the graph; not waiting on the digest'; exit 4 ;; esac
C=\$HOME/.ostler/assistant-config/workspace/CONTEXT.md
before=\$(stat -f %m \"\$C\" 2>/dev/null || echo 0)
launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.context-refresh >/dev/null 2>&1; echo \"OES refresh rc=\$?\"
i=0; while [ \$i -lt 120 ]; do now=\$(stat -f %m \"\$C\" 2>/dev/null || echo 0); [ \"\$now\" -gt \"\$before\" ] && { echo 'OES digest rewritten'; exit 0; }; sleep 5; i=\$((i+1)); done
echo 'OES digest not rewritten in 600s'; exit 3" 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    # SEEDED IS A COUNT, NOT AN EXIT CODE. ostler-import's code was the last
    # step's (the universal importer's 3 "unknown format" on walk #13), and it
    # says nothing about whether the fact landed. The graph does.
    local cnt
    cnt="$(printf '%s\n' "$out" | sed -n 's/^OES count=\([0-9][0-9]*\)$/\1/p' | tail -1)"
    if [ -n "$cnt" ] && [ "$cnt" -gt 0 ] && printf '%s' "$out" | grep -q '^OES digest rewritten'; then
        OSTLER_OWNER_SEED_STATE="seeded"
    else
        OSTLER_OWNER_SEED_STATE="failed"
    fi
    export OSTLER_OWNER_SEED_STATE
    printf '  owner employer seed: %s (organisation %s)\n\n' "$OSTLER_OWNER_SEED_STATE" "$OSTLER_OWNER_SEED_ORG"
    [ "$OSTLER_OWNER_SEED_STATE" = "seeded" ]
}

# owner_employer_seed_forget -- remove the synthetic position again.
# Every measurement was taken before this runs, so it changes no verdict. It
# deletes ONLY a PersonFact carrying all three of source linkedin_positions,
# the seed organisation and the seed title, and prints the count before and
# after so a delete that matched nothing is visible, not silent.
owner_employer_seed_forget() {
    [ "$OSTLER_OWNER_SEED_STATE" = "seeded" ] || [ "$OSTLER_OWNER_SEED_STATE" = "failed" ] || return 0
    if [ "${OSTLER_OWNER_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- OWNER EMPLOYER SEED: kept on the box (OSTLER_OWNER_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- OWNER EMPLOYER SEED: removing the synthetic position ---\n'
    local out
    out="$(_oes_box "set -u
$(_oes_count_sh)
echo \"OES before=\$(n)\"
\"\$OES_CURL\" -sS --noproxy '*' -m 30 -K \"\$K\" -H 'Content-Type: application/sparql-update' --data-binary \"\${P}DELETE { ?f ?p ?o } WHERE { \$M ?f ?p ?o }\" \"\${OXI%/query}/update\"; echo \"OES delete rc=\$?\"
echo \"OES after=\$(n)\"
$(_oes_update_sh "$(_oes_b64 "$(_oes_interaction_forget_sparql)")")
rm -rf \$HOME/.ostler/walk-seed/owner-linkedin
launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.context-refresh >/dev/null 2>&1; echo \"OES refresh rc=\$?\"" 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    if ! printf '%s' "$out" | grep -q '^OES after=0$'; then
        printf '  Left on the box: the synthetic position may still be in the graph.\n'
        printf '  No verdict changes; remove it by hand on any box that is not a throwaway.\n'
    fi
    printf '\n'
    return 0
}
