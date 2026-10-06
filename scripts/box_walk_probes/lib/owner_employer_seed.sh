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
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

owner_employer_seed_apply() {
    printf '%s\n' "--- OWNER EMPLOYER SEED: a synthetic LinkedIn Positions.csv through ostler-import ---"
    local out
    out="$(_oes_box "set -u
D=\$HOME/.ostler/walk-seed/owner-linkedin/Basic_LinkedInDataExport
mkdir -p \"\$D\" || { echo 'OES no-dir'; exit 2; }
printf 'Company Name,Title,Description,Location,Started On,Finished On\n%s,Staff engineer,,Riverside,Jan 2020,\n' '${OSTLER_OWNER_SEED_ORG}' > \"\$D/Positions.csv\"
[ -x \$HOME/.ostler/bin/ostler-import ] || { echo 'OES no-importer'; exit 2; }
\$HOME/.ostler/bin/ostler-import \"\$(dirname \"\$D\")\" >/tmp/ostler-walk-owner-seed.log 2>&1; echo \"OES import rc=\$?\"
C=\$HOME/.ostler/assistant-config/workspace/CONTEXT.md
before=\$(stat -f %m \"\$C\" 2>/dev/null || echo 0)
launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.context-refresh >/dev/null 2>&1; echo \"OES refresh rc=\$?\"
i=0; while [ \$i -lt 120 ]; do now=\$(stat -f %m \"\$C\" 2>/dev/null || echo 0); [ \"\$now\" -gt \"\$before\" ] && { echo 'OES digest rewritten'; exit 0; }; sleep 5; i=\$((i+1)); done
echo 'OES digest not rewritten in 600s'; exit 3" 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    if printf '%s' "$out" | grep -q '^OES import rc=0' && printf '%s' "$out" | grep -q '^OES digest rewritten'; then
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
_OES_TITLE="Staff engineer"
owner_employer_seed_forget() {
    [ "$OSTLER_OWNER_SEED_STATE" = "seeded" ] || [ "$OSTLER_OWNER_SEED_STATE" = "failed" ] || return 0
    if [ "${OSTLER_OWNER_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- OWNER EMPLOYER SEED: kept on the box (OSTLER_OWNER_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- OWNER EMPLOYER SEED: removing the synthetic position ---\n'
    local out
    out="$(_oes_box "set -u
K=\${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}
OXI=\${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}
P='PREFIX pwg: <https://schema.ostler.ai/ontology#> '
M='?f pwg:source \"linkedin_positions\" ; pwg:organization \"${OSTLER_OWNER_SEED_ORG}\" ; pwg:jobTitle \"${_OES_TITLE}\" .'
n() { /usr/bin/curl -sS --noproxy '*' -m 20 -K \"\$K\" -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary \"\${P}SELECT (COUNT(DISTINCT ?f) AS ?n) WHERE { \$M }\" \"\$OXI\" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])' 2>&1; }
echo \"OES before=\$(n)\"
/usr/bin/curl -sS --noproxy '*' -m 30 -K \"\$K\" -H 'Content-Type: application/sparql-update' --data-binary \"\${P}DELETE { ?f ?p ?o } WHERE { \$M ?f ?p ?o }\" \"\${OXI%/query}/update\"; echo \"OES delete rc=\$?\"
echo \"OES after=\$(n)\"
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
