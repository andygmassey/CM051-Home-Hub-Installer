#!/usr/bin/env bash
#
# tests/test_end_of_install_confirmation.sh
#
# Guards the end-of-installation confirmation step (calendar owner/type +
# identity collapse/split). Two parts:
#
#   A. STATIC — the confirmation block is wired into install.sh correctly:
#      present, gated + skippable, inserted AFTER hydration and BEFORE the
#      "Summary" recap, references only defined MSG_* strings, and points at
#      the two helper scripts + the two output files (calendars.json,
#      duplicates.yaml).
#
#   B. BEHAVIOURAL — driving the SAME helper command sequence the install.sh
#      block runs (enumerate -> answers -> write ; propose -> record) against
#      synthetic fixtures produces a valid calendars.json and a valid
#      duplicates.yaml. This exercises the CLI contract the block depends on,
#      including the TAB-separated row parsing.
#
# All fixtures are SYNTHETIC. No real personal data.
#
# Exit 0 on clean, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
CAL_PY="$REPO_ROOT/lib/ostler-confirm-calendars.py"
ID_PY="$REPO_ROOT/lib/ostler-confirm-identity.py"

PY="$(command -v python3)"
fails=0
note() { printf '  %s\n' "$*"; }
check() {  # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok   %s\n' "$desc"
    else
        printf 'FAIL %s\n' "$desc" >&2
        fails=$((fails + 1))
    fi
}
grep_q() { grep -q "$@" "$INSTALL_SH"; }

echo "== A. static wiring =="

check "helper: calendars script exists" test -f "$CAL_PY"
check "helper: identity script exists" test -f "$ID_PY"
check "helper: calendars python is valid" "$PY" -m py_compile "$CAL_PY"
check "helper: identity python is valid" "$PY" -m py_compile "$ID_PY"

check "block present (header)" grep_q "End-of-install confirmation: whose calendars"
check "gated + skippable via OSTLER_SKIP_CONFIRMATION" \
    grep_q 'OSTLER_SKIP_CONFIRMATION:-0'
check "invokes calendars helper" grep_q "ostler-confirm-calendars.py"
check "invokes identity helper" grep_q "ostler-confirm-identity.py"
check "writes calendars.json" grep_q 'calendars.json'
check "records to duplicates.yaml consumer dir (WIKI_CORRECTIONS_DIR)" \
    grep_q 'WIKI_CORRECTIONS_DIR'
check "reads hydrated calendar_events.json" grep_q 'imports/fda/calendar_events.json'
check "queries Oxigraph for identity candidates" grep_q 'oxigraph-url'
check "uses merge (collapse) + distinct (namesake) actions" bash -c \
    "grep -q -- '--merge' '$INSTALL_SH' && grep -q -- '--distinct' '$INSTALL_SH'"

# Inserted AFTER hydration and BEFORE the Summary recap.
conf_line="$(grep -n 'End-of-install confirmation: whose calendars' "$INSTALL_SH" | head -1 | cut -d: -f1)"
summary_line="$(grep -n '^# ── Summary' "$INSTALL_SH" | head -1 | cut -d: -f1)"
wiki_line="$(grep -n 'MSG_HYDRATE_WIKI_RECOMPILE' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$conf_line" && -n "$summary_line" && -n "$wiki_line" \
      && "$wiki_line" -lt "$conf_line" && "$conf_line" -lt "$summary_line" ]]; then
    printf 'ok   inserted after wiki hydrate (%s) and before Summary (%s)\n' \
        "$wiki_line" "$summary_line"
else
    printf 'FAIL insertion order wrong (wiki=%s conf=%s summary=%s)\n' \
        "$wiki_line" "$conf_line" "$summary_line" >&2
    fails=$((fails + 1))
fi

# Every MSG_CONFIRM_* the block references must be defined in the catalogue.
CATALOGUE="$REPO_ROOT/install.sh.strings.en-GB.sh"
while read -r key; do
    if grep -q "^${key}=" "$CATALOGUE"; then
        printf 'ok   string defined: %s\n' "$key"
    else
        printf 'FAIL string missing: %s\n' "$key" >&2
        fails=$((fails + 1))
    fi
done < <(grep -oE 'MSG_CONFIRM_[A-Z0-9_]+' "$INSTALL_SH" | sort -u)

echo "== B. behavioural (same command sequence as the block) =="

TMP="$(mktemp -d -t ostler-eoi.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- calendar leg: enumerate -> answers.tsv -> write ---
cat > "$TMP/calendar_events.json" <<'JSON'
[
  {"calendar_name": "Work", "title": "Standup"},
  {"calendar_name": "Work", "title": "1:1"},
  {"calendar_name": "Robin Carter", "title": "Flight to Tokyo"},
  {"calendar_name": "Home", "title": "Dentist"}
]
JSON

rows="$("$PY" "$CAL_PY" enumerate --events "$TMP/calendar_events.json" --owner-name "Jane Doe")"
# Simulate the operator hitting enter at every prompt: keep the pre-fills.
: > "$TMP/answers.tsv"
while IFS=$'\t' read -r match owner ctype count samples; do
    [[ -z "$match" ]] && continue
    printf '%s\t%s\t%s\n' "$match" "$owner" "$ctype" >> "$TMP/answers.tsv"
done <<< "$rows"
"$PY" "$CAL_PY" write --answers "$TMP/answers.tsv" --out "$TMP/calendars.json" >/dev/null

check "calendars.json is valid JSON with a calendars list" \
    "$PY" -c "import json;d=json.load(open('$TMP/calendars.json'));assert isinstance(d['calendars'],list) and d['calendars']"
check "Robin Carter calendar attributed to Robin (not the operator)" \
    "$PY" -c "import json;d=json.load(open('$TMP/calendars.json'));e=[c for c in d['calendars'] if c['match']=='Robin Carter'][0];assert e['owner']=='Robin Carter' and e['type']=='family'"

# --- identity leg: propose (from fixture) -> record ---
cat > "$TMP/id_fixture.json" <<'JSON'
{"rows": [
  {"person": "https://pwg.dev/ontology#user_5", "name": "Jane Doe", "isOwner": "true", "idType": "email", "idValue": "jane@own.com"},
  {"person": "https://pwg.dev/ontology#user_5", "name": "Jane Doe", "idType": "linkedin_url", "idValue": "https://linkedin.com/in/janedoe"},
  {"person": "https://pwg.dev/ontology#person_bbbb", "name": "Jane Doe", "idType": "email", "idValue": "j.doe@own.com"},
  {"person": "https://pwg.dev/ontology#person_bbb2", "name": "Jane Doe", "idType": "email", "idValue": "jane.doe@own.com"},
  {"person": "https://pwg.dev/ontology#person_cccc", "name": "Jane Doe", "idType": "linkedin_url", "idValue": "https://linkedin.com/in/jane-pilot"}
]}
JSON

props="$("$PY" "$ID_PY" propose --user-id 5 --from-json "$TMP/id_fixture.json")"
merge_args=()
distinct_args=()
while IFS=$'\t' read -r kind ids evidence; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
        COLLAPSE) merge_args+=("--merge" "$ids") ;;      # operator says "yes"
        NAMESAKE) distinct_args+=("--distinct" "$ids") ;;  # operator says "different"
    esac
done <<< "$props"
mkdir -p "$TMP/corrections"
"$PY" "$ID_PY" record --corrections-dir "$TMP/corrections" \
    ${merge_args[@]+"${merge_args[@]}"} ${distinct_args[@]+"${distinct_args[@]}"} >/dev/null

check "duplicates.yaml written" test -f "$TMP/corrections/duplicates.yaml"
check "duplicates.yaml has a merge (collapse) decision" \
    grep -q 'merge' "$TMP/corrections/duplicates.yaml"
check "duplicates.yaml has a distinct (namesake veto) decision" \
    grep -q 'distinct' "$TMP/corrections/duplicates.yaml"
# Consumer-shape sanity: parseable + short-ids present.
check "duplicates.yaml is valid YAML the resolver can parse" \
    "$PY" -c "import yaml;d=yaml.safe_load(open('$TMP/corrections/duplicates.yaml'));assert isinstance(d['decisions'],list) and d['decisions']"

# Skip path: with no proposals + no events, nothing is required to be written.
check "empty enumerate is safe (no rows -> no crash)" bash -c \
    "echo '[]' > '$TMP/empty.json'; '$PY' '$CAL_PY' enumerate --events '$TMP/empty.json'"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "PASS: end-of-install confirmation wiring + behaviour verified"
    exit 0
fi
echo "FAIL: $fails check(s) failed" >&2
exit 1
