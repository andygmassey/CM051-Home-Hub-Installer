#!/usr/bin/env bash
# The Article 9 and third-party-data legal notes follow the Mac's REGION, not
# its language, and the consent record pins the region and note version it
# showed (CM051 row L7, the same pattern as the spoken-capture note, #3154).
# Before this, both notes quoted UK/EU GDPR articles to every region.
#
# Runs install.sh's OWN functions (extracted, none re-implemented):
#   A. per locale row in tests/fixtures/legal_region_basic_contract.tsv, both
#      notes name the right law (GB: UK GDPR, EU/EEA: GDPR, HK: PDPO Cap. 486
#      and no GDPR article, everything else: neutral core, no statute at all);
#   B. the GUI's ViewCopy.json keys compose the same note as install.sh;
#   C. the REAL vendored consent_cli records region, variant, note, sha256 and
#      "<version>+<variant>" for both tickboxes, and `check` still passes;
#   D. self-test mutants must each go red: pick-by-language, install.sh drops
#      the pin, consent_cli drops the variant from the version.
# Every region line is a best-effort draft pending local professional sign-off.
# Exit 0 pass, 1 fail, 2 CANNOT-RUN.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PY="$(command -v python3)"
FIX="${REPO}/tests/fixtures/legal_region_basic_contract.tsv"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
[[ -f "${FIX}" && -n "${PY}" ]] || { echo "CANNOT-RUN: fixture or python3 missing"; exit 2; }

extract() { # $1 install.sh, $2 out dir
    awk '/^_ostler_legal_apple_locale\(\) \{/{f=1} f{print} /^_ostler_legal_region_now\(\) \{/{g=1} g&&/^\}/{exit}' "$1" > "$2/fns.sh"
    awk '$0=="    _consent_cli_record() {"{f=1} f{print} f&&$0=="    }"{exit}' "$1" > "$2/recorder_fn.sh"
    awk '$0=="        _art9_legal_args=()"{f=1} f{print} f&&$0=="        unset _art9_legal_args _art9_legal_file"{exit}' "$1" > "$2/art9_call.sh"
    awk '$0=="        _tp_legal_args=()"{f=1} f{print} f&&$0=="        unset _tp_legal_args _tp_legal_file"{exit}' "$1" > "$2/tp_call.sh"
    local n
    for n in fns recorder_fn art9_call tp_call; do
        [[ -s "$2/${n}.sh" ]] || { echo "CANNOT-RUN: could not extract ${n} from $1"; return 2; }
    done
}

# note_for <extract dir> <fn> <locale or UNSET>: the note install.sh shows.
note_for() {
    local ex="$1" fn="$2" loc="$3"
    if [[ "${loc}" == UNSET ]]; then
        env -u OSTLER_APPLE_LOCALE bash -c 'source "$1" >/dev/null 2>&1; source "$2"; defaults() { return 1; }; "$3" "$(_ostler_legal_region_now)"' _ "${REPO}/install.sh.strings.en-GB.sh" "${ex}/fns.sh" "${fn}"
    else
        OSTLER_APPLE_LOCALE="${loc}" bash -c 'source "$1" >/dev/null 2>&1; source "$2"; "$3" "$(_ostler_legal_region_now)"' _ "${REPO}/install.sh.strings.en-GB.sh" "${ex}/fns.sh" "${fn}"
    fi
}

# verify_region <extract dir>: FAIL lines and one EXAMINED line.
verify_region() {
    local ex="$1" n=0 loc variant law fn note
    while IFS=$'\t' read -r loc variant law; do
        [[ -z "${loc}" || "${loc}" == \#* ]] && continue
        for fn in _ostler_article_9_legal_note_for _ostler_third_party_legal_note_for; do
            note="$(note_for "${ex}" "${fn}" "${loc}")"
            n=$((n + 1))
            [[ "${note}" == "Legal note:"* ]] || echo "FAIL ${fn} ${loc}: no Legal note lead-in"
            case "${law}" in
                ukgdpr) [[ "${note}" == *"UK GDPR Article 4(7)"* && "${note}" != *"Cap. 486"* ]] || echo "FAIL ${fn} ${loc}: want the UK GDPR line" ;;
                gdpr) [[ "${note}" == *"GDPR Article 4(7)"* && "${note}" != *"UK GDPR"* && "${note}" != *"Cap. 486"* ]] || echo "FAIL ${fn} ${loc}: want the GDPR line, not UK" ;;
                pdpo) [[ "${note}" == *"Cap. 486"* && "${note}" != *"GDPR"* && "${note}" != *"Article"* ]] || echo "FAIL ${fn} ${loc}: want the PDPO line and no GDPR article" ;;
                none) [[ "${note}" != *"GDPR"* && "${note}" != *"Cap. 486"* && "${note}" != *"Article"* ]] || echo "FAIL ${fn} ${loc}: neutral core must name no statute" ;;
            esac
        done
    done < "${FIX}"
    # A missing AppleLocale is region unknown: core only.
    for fn in _ostler_article_9_legal_note_for _ostler_third_party_legal_note_for; do
        note="$(note_for "${ex}" "${fn}" UNSET)"
        n=$((n + 1))
        [[ "${note}" != *"GDPR"* && "${note}" != *"Cap. 486"* ]] || echo "FAIL ${fn} unset locale: not core only"
    done
    echo "EXAMINED ${n} notes"
}

# gui_parity <extract dir>: ViewCopy.json composes the same note as bash.
gui_parity() {
    local ex="$1" loc variant law sec fn n=0
    while IFS=$'\t' read -r loc variant law; do
        [[ -z "${loc}" || "${loc}" == \#* ]] && continue
        for sec in consent_article_9:_ostler_article_9_legal_note_for consent_third_party:_ostler_third_party_legal_note_for; do
            fn="${sec#*:}"; sec="${sec%%:*}"
            note_for "${ex}" "${fn}" "${loc}" > "${WORK}/bash.note"
            "${PY}" -I - "${REPO}/gui/OstlerInstaller/Resources/ViewCopy.json" "${sec}" "${variant}" "${WORK}/bash.note" <<'PY'
import json, sys
vc, sec, variant, bash_note = sys.argv[1:5]
d = json.load(open(vc, encoding="utf-8"))[sec]
parts = [d["legal_prefix"], d["legal_core"]] + ([d["legal_region_" + variant]] if variant != "core" else [])
if " ".join(parts) != open(bash_note, encoding="utf-8").read():
    print(f"FAIL gui parity {sec} {variant}: ViewCopy.json note differs from install.sh")
PY
            n=$((n + 1))
        done
    done < "${FIX}"
    echo "EXAMINED ${n} gui pairs"
}

# record_one <vendor> <extract dir> <which: art9|tp> <region or ""> <out base>
record_one() {
    local vendor="$1" ex="$2" which="$3" region="$4" out="$5" home call tick
    home="$(mktemp -d "${WORK}/home.XXXX")"
    printf '#!/bin/sh\nPYTHONDONTWRITEBYTECODE=1 PYTHONPATH="%s" exec "%s" "$@"\n' "${vendor}" "${PY}" > "${home}/py"
    chmod +x "${home}/py"
    if [[ "${which}" == art9 ]]; then
        call="art9_call.sh"; tick=article_9_special_category_consent
    else
        call="tp_call.sh"; tick=third_party_data_personal_records
    fi
    {
        echo 'set -uo pipefail'
        echo 'warn() { echo "WARN:$1" >&2; }'
        echo 'MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="[stderr]"'
        echo "source '${REPO}/install.sh.strings.en-GB.sh' >/dev/null 2>&1"
        echo "OSTLER_DIR='${home}'; OSTLER_PYTHON='${home}/py'; OSTLER_REGION=row; USER_ID=synthetic-user"
        echo "OSTLER_CONSENT_ARTICLE_9_LEGAL_REGION='${region}'; OSTLER_CONSENT_THIRD_PARTY_LEGAL_REGION='${region}'"
        cat "${ex}/fns.sh" "${ex}/recorder_fn.sh"
        echo "_cli() { :; }"
        echo "OSTLER_CONSENT_DECISION_VALUE=accepted"
        sed 's/"\$OSTLER_CONSENT_ARTICLE_9_DECISION"/accepted/; s/"\$OSTLER_CONSENT_THIRD_PARTY_DECISION"/accepted/' "${ex}/${call}"
    } > "${out}.drive.sh"
    env -u PYTHONPATH bash "${out}.drive.sh" > "${out}.log" 2>&1
    if [[ -f "${home}/posture/consent.json" ]]; then cp "${home}/posture/consent.json" "${out}.json"; else : > "${out}.json"; fi
    env -u PYTHONPATH OSTLER_HOME="${home}" "${home}/py" -m ostler_security.consent_cli check --tickbox "${tick}" >/dev/null 2>&1
    echo "$?" > "${out}.check"
}

verify_pin() { # $1 vendor, $2 extract dir, $3 label
    local vendor="$1" ex="$2" d="${WORK}/$3" which r
    mkdir -p "${d}"
    local regions="GB DE IE HK US JP none"
    for which in art9 tp; do
        for r in ${regions}; do
            record_one "${vendor}" "${ex}" "${which}" "${r}" "${d}/${which}_${r}"
            bash -c 'source "$1" >/dev/null 2>&1; source "$2"; "$3" "$4"' _ "${REPO}/install.sh.strings.en-GB.sh" "${ex}/fns.sh" \
                "$([[ ${which} == art9 ]] && echo _ostler_article_9_legal_note_for || echo _ostler_third_party_legal_note_for)" "${r}" > "${d}/${which}_${r}.want"
        done
        record_one "${vendor}" "${ex}" "${which}" "" "${d}/${which}_legacy"
    done
    "${PY}" -I -B - "${d}" "${regions}" "${vendor}" <<'PY'
import hashlib, json, os, sys
d, regions, vendor = sys.argv[1], sys.argv[2].split(), sys.argv[3]
sys.path.insert(0, vendor)
from legal import ARTICLE_9_EU_CONSENT, THIRD_PARTY_DATA_NOTICE
variant_of = {"GB": "gb", "DE": "eu", "IE": "eu", "HK": "hk", "US": "core", "JP": "core", "none": "core"}
n = 0
for which, CS in (("art9", ARTICLE_9_EU_CONSENT), ("tp", THIRD_PARTY_DATA_NOTICE)):
    def rec(name):
        p = os.path.join(d, f"{which}_{name}.json")
        if not os.path.getsize(p):
            return None
        return json.load(open(p))["records"].get(CS.tickbox_id)
    def check(name):
        return open(os.path.join(d, f"{which}_{name}.check")).read().strip()
    versions = set()
    for r in regions:
        n += 1
        rc = rec(r)
        if rc is None:
            print(f"FAIL {which} {r}: no record written ({open(os.path.join(d, f'{which}_{r}.log')).read()[:300]!r})"); continue
        want = open(os.path.join(d, f"{which}_{r}.want"), encoding="utf-8").read()
        v = variant_of[r]
        if rc.get("legal_note_region") != r: print(f"FAIL {which} {r}: legal_note_region {rc.get('legal_note_region')!r}")
        if rc.get("legal_note_variant") != v: print(f"FAIL {which} {r}: legal_note_variant {rc.get('legal_note_variant')!r}")
        if rc.get("wording_version") != f"{CS.version}+{v}": print(f"FAIL {which} {r}: wording_version {rc.get('wording_version')!r}")
        if rc.get("legal_note_text") != want: print(f"FAIL {which} {r}: legal_note_text is not install.sh's note")
        if rc.get("legal_note_sha256") != hashlib.sha256(want.encode()).hexdigest(): print(f"FAIL {which} {r}: legal_note_sha256 does not hash the shown note")
        if rc.get("wording_hash") != CS.sha256(): print(f"FAIL {which} {r}: wording_hash moved, every gate keyed on it would re-prompt")
        if check(r) != "0": print(f"FAIL {which} {r}: consent_cli check exit {check(r)}, want 0")
        versions.add(rc.get("wording_version"))
    if len(versions) != 4: print(f"FAIL {which}: expected 4 distinct wording_versions (core gb eu hk), got {sorted(versions)}")
    lg = rec("legacy")
    n += 1
    if lg is None: print(f"FAIL {which} legacy: no record written")
    else:
        if "legal_note_region" in lg: print(f"FAIL {which} legacy: pinned a note nobody was shown")
        if lg.get("wording_version") != CS.version: print(f"FAIL {which} legacy: wording_version {lg.get('wording_version')!r}")
        if check("legacy") != "0": print(f"FAIL {which} legacy: check exit {check('legacy')}")
print(f"EXAMINED {n} records")
PY
}

run_all() { # $1 install.sh $2 vendor dir $3 label -> prints FAIL lines
    local ex="${WORK}/ex_$3"
    mkdir -p "${ex}"
    extract "$1" "${ex}" || { echo "CANNOT-RUN extract"; return; }
    verify_region "${ex}"
    gui_parity "${ex}"
    verify_pin "$2" "${ex}" "$3"
}

# --- real run -----------------------------------------------------------------
out="$(run_all "${REPO}/install.sh" "${REPO}/vendor" real)"
echo "${out}"
fails="$(grep -c '^FAIL\|^CANNOT-RUN' <<< "${out}")"
examined="$(grep -c '^EXAMINED' <<< "${out}")"
[[ "${examined}" -eq 3 ]] || { echo "CANNOT-RUN: expected 3 EXAMINED lines, got ${examined}"; exit 2; }
[[ "${fails}" -eq 0 ]] || { echo "FAIL real run: ${fails} problems"; exit 1; }

# --- self-test: every mutant must go red ---------------------------------------
mut_fail=0
red() { # $1 label, $2 count of FAIL lines in the mutant run
    if [[ "$2" -gt 0 ]]; then echo "PASS mutant ${1} went red (${2} FAIL lines)"; else echo "FAIL mutant ${1} stayed green"; mut_fail=1; fi
}
M="${WORK}/mut"; mkdir -p "${M}/vendor"; cp -R "${REPO}/vendor/." "${M}/vendor/"

# 1. pick by LANGUAGE instead of region
cp "${REPO}/install.sh" "${M}/lang.sh"
"${PY}" -I - "${M}/lang.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '''    cc="$(_ostler_legal_country_from_locale "$(_ostler_legal_apple_locale)")"
    printf '%s' "${cc:-none}"
}'''
new = '''    local loc; loc="$(_ostler_legal_apple_locale)"
    cc="$(printf '%s' "${loc%%[_-]*}" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${cc:-none}"
}'''
assert s.count(old) == 1
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
red "pick-by-language" "$(run_all "${M}/lang.sh" "${REPO}/vendor" lang | grep -c '^FAIL')"

# 2. install.sh stops pinning the Article 9 note
cp "${REPO}/install.sh" "${M}/nopin.sh"
"${PY}" -I - "${M}/nopin.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '                --legal-note-file "${_art9_legal_file}"\n'
assert s.count(old) == 1
open(p, "w", encoding="utf-8").write(s.replace(old, ""))
PY
red "install.sh drops the Article 9 pin flag" "$(run_all "${M}/nopin.sh" "${REPO}/vendor" nopin | grep -c '^FAIL\|^CANNOT-RUN')"

# 3. region-blind: the HK line is shown to everyone as the GB one
cp "${REPO}/install.sh" "${M}/blind.sh"
"${PY}" -I - "${M}/blind.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "        hk) printf 'hk' ;;\n        *) printf 'core' ;;\n    esac\n}\n\n_ostler_article_9"
assert s.count(old) == 1
open(p, "w", encoding="utf-8").write(s.replace(old, "        hk) printf 'hk' ;;\n        *) printf 'gb' ;;\n    esac\n}\n\n_ostler_article_9"))
PY
red "region-blind (everyone gets the GB line)" "$(run_all "${M}/blind.sh" "${REPO}/vendor" blind | grep -c '^FAIL')"

# 4. consent_cli drops the variant from the recorded version
"${PY}" -I - "${M}/vendor/legal/consent_strings.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '    return f"{consent.version}+{variant}"'
assert s.count(old) == 1
open(p, "w", encoding="utf-8").write(s.replace(old, "    return consent.version"))
PY
red "consent_cli drops the variant from wording_version" "$(run_all "${REPO}/install.sh" "${M}/vendor" nover | grep -c '^FAIL')"

[[ "${mut_fail}" -eq 0 ]] || exit 1
echo "ALL ARTICLE 9 / THIRD-PARTY REGION NOTE TESTS PASSED"
