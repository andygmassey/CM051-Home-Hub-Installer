#!/usr/bin/env bash
# The spoken-capture consent record pins EXACTLY the legal note the customer
# was shown (Archie, 2026-10-24). The note is chosen by the Mac's region, so a
# record that only says "spoken_capture_recording_consent v1.1, accepted"
# cannot say which note was agreed to.
#
# Drives install.sh's OWN recorder text (the legal-note functions, the
# _consent_cli_record wrapper and the spoken-capture recorder block, all
# extracted, none re-implemented) into the REAL vendored consent_cli and
# consent registry, once per region, and reads the consent.json it wrote:
#   - legal_note_region / legal_note_variant are the region and its variant;
#   - wording_version is "<base version>+<variant>", so regions differ;
#   - legal_note_text is the note install.sh renders AND the note the GUI
#     renders from ViewCopy.json for that region, and legal_note_sha256 is
#     its hash;
#   - wording_hash is unchanged, so `consent_cli check` still passes;
#   - a reuse run whose stored answers predate the region (empty) writes the
#     old record shape, and an old-shape record stays readable and current.
# Self-test first: three mutants must each go red (install.sh drops the pin,
# consent_cli drops the variant from the version, consent.py drops the
# region field from the record).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PY="$(command -v python3)"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

extract() { # $1 install.sh, $2 out dir
    awk '/^_ostler_legal_apple_locale\(\) \{/{f=1} f{print} /^_ostler_spoken_capture_legal_note\(\) \{/{g=1} g&&/^\}/{exit}' "$1" > "$2/legal_fns.sh"
    awk '$0=="    _consent_cli_record() {"{f=1} f{print} f&&$0=="    }"{exit}' "$1" > "$2/recorder_fn.sh"
    awk '$0=="    _spoken_legal_args=()"{f=1} f{print} f&&$0=="    unset _spoken_legal_args _spoken_legal_file"{exit}' "$1" > "$2/recorder_call.sh"
}

# record_one <vendor dir> <extract dir> <decision> <legal region or ""> <out>
# Runs the recorder with a fresh OSTLER_HOME; writes <out>.json (the registry,
# or empty) and <out>.check (consent_cli check exit code).
record_one() {
    local vendor="$1" ex="$2" decision="$3" region="$4" out="$5" home
    home="$(mktemp -d "${WORK}/home.XXXX")"
    printf '#!/bin/sh\nPYTHONDONTWRITEBYTECODE=1 PYTHONPATH="%s" exec "%s" "$@"\n' "${vendor}" "${PY}" > "${home}/py"
    chmod +x "${home}/py"
    {
        echo 'set -uo pipefail'
        echo 'warn() { echo "WARN:$1" >&2; }'
        echo 'MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="[stderr]"'
        echo "source '${REPO}/install.sh.strings.en-GB.sh' >/dev/null 2>&1"
        echo "OSTLER_DIR='${home}'; OSTLER_PYTHON='${home}/py'; OSTLER_REGION=row; USER_ID=synthetic-user"
        echo "OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION='${decision}'"
        echo "OSTLER_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION='${region}'"
        cat "${ex}/legal_fns.sh" "${ex}/recorder_fn.sh" "${ex}/recorder_call.sh"
    } > "${out}.drive.sh"
    env -u PYTHONPATH bash "${out}.drive.sh" > "${out}.log" 2>&1
    if [[ -f "${home}/posture/consent.json" ]]; then cp "${home}/posture/consent.json" "${out}.json"; else : > "${out}.json"; fi
    env -u PYTHONPATH OSTLER_HOME="${home}" "${home}/py" -m ostler_security.consent_cli check \
        --tickbox spoken_capture_recording_consent >/dev/null 2>&1
    echo "$?" > "${out}.check"
}

# verify <vendor dir> <extract dir> <label>: prints FAIL lines and one EXAMINED
# line. No EXAMINED line means the checker itself did not run: CANNOT-RUN,
# never a pass.
verify() {
    local vendor="$1" ex="$2" label="$3" d
    d="${WORK}/${label}"
    mkdir -p "${d}"
    local rows="GB:gb DE:eu.de FR:eu.fr IT:eu HK:hk US:us none:core"
    for rv in ${rows}; do
        record_one "${vendor}" "${ex}" accepted "${rv%%:*}" "${d}/${rv%%:*}"
    done
    record_one "${vendor}" "${ex}" declined DE "${d}/declined_DE"
    record_one "${vendor}" "${ex}" accepted "" "${d}/legacy"
    # Each region's expected note, from install.sh's own composer.
    for rv in ${rows}; do
        bash -c 'source "$1" >/dev/null 2>&1; source "$2"; _ostler_spoken_capture_legal_note_for "$3"' \
            _ "${REPO}/install.sh.strings.en-GB.sh" "${ex}/legal_fns.sh" "${rv%%:*}" > "${d}/${rv%%:*}.want"
    done
    "${PY}" -I -B - "${d}" "${rows}" "${REPO}/gui/OstlerInstaller/Resources/ViewCopy.json" "${REPO}/vendor" <<'PY'
import hashlib, json, os, sys
d, rows, vc, vendor = sys.argv[1], sys.argv[2].split(), sys.argv[3], sys.argv[4]
sys.path.insert(0, vendor)
from legal import SPOKEN_CAPTURE_RECORDING_CONSENT as CS
gui = json.load(open(vc, encoding="utf-8"))["consent_spoken_capture"]
gui_regions = {"core": [], "gb": ["gb"], "eu": ["eu"], "eu.de": ["eu", "de"], "eu.fr": ["eu", "fr"], "hk": ["hk"], "us": ["us"]}
def rec(name):
    p = os.path.join(d, name + ".json")
    if not os.path.getsize(p):
        return None
    return json.load(open(p))["records"].get("spoken_capture_recording_consent")
def check(name):
    return open(os.path.join(d, name + ".check")).read().strip()
versions = {}
for rv in rows:
    region, variant = rv.split(":")
    r = rec(region)
    if r is None:
        print(f"FAIL {region}: no record written (log: {open(os.path.join(d, region + '.log')).read()[:300]!r})"); continue
    want = open(os.path.join(d, region + ".want"), encoding="utf-8").read()
    g = " ".join([gui["legal_prefix"], gui["legal_core"], gui["legal_local"]] + [gui["legal_region_" + k] for k in gui_regions[variant]] + [gui["legal_responsibility"]])
    if r.get("legal_note_region") != region: print(f"FAIL {region}: legal_note_region {r.get('legal_note_region')!r}")
    if r.get("legal_note_variant") != variant: print(f"FAIL {region}: legal_note_variant {r.get('legal_note_variant')!r}")
    if r.get("wording_version") != f"{CS.version}+{variant}": print(f"FAIL {region}: wording_version {r.get('wording_version')!r}")
    if r.get("legal_note_text") != want: print(f"FAIL {region}: legal_note_text is not install.sh's note")
    if r.get("legal_note_text") != g: print(f"FAIL {region}: legal_note_text is not the GUI's note")
    if r.get("legal_note_sha256") != hashlib.sha256(want.encode()).hexdigest(): print(f"FAIL {region}: legal_note_sha256 does not hash the shown note")
    if r.get("wording_hash") != CS.sha256(): print(f"FAIL {region}: wording_hash moved, every gate keyed on it would re-prompt")
    if check(region) != "0": print(f"FAIL {region}: consent_cli check exit {check(region)}, want 0")
    versions[region] = (r.get("wording_version"), r.get("legal_note_sha256"))
if len({v for v in versions.values()}) != len(versions):
    print(f"FAIL two regions recorded the same version + note: {versions}")
r = rec("declined_DE")
if r is None or r.get("decision") != "declined" or r.get("legal_note_variant") != "eu.de":
    print("FAIL a decline does not pin the note it declined")
r = rec("legacy")
if r is None:
    print("FAIL legacy reuse wrote no record")
else:
    if any(k.startswith("legal_note") for k in r): print("FAIL legacy reuse pinned a note it never showed")
    if r.get("wording_version") != CS.version: print(f"FAIL legacy wording_version {r.get('wording_version')!r}")
    if check("legacy") != "0": print("FAIL an old-shape record is no longer current")
print(f"EXAMINED {len(versions)} region records + decline + legacy")
PY
}

INSTALL_SH="${REPO}/install.sh"
mkdir -p "${WORK}/ex"
extract "${INSTALL_SH}" "${WORK}/ex"
for f in legal_fns recorder_fn recorder_call; do
    [[ $(grep -c . "${WORK}/ex/${f}.sh") -ge 8 ]] || { echo "CANNOT-RUN: ${f} extracted short from install.sh"; exit 2; }
done

# ── mutants
mut() { # $1 file, $2 old, $3 new (exactly one occurrence)
    "${PY}" -I -c 'import sys; p,o,n=sys.argv[1:]; s=open(p).read(); assert s.count(o)==1, "mutant did not apply: "+o; open(p,"w").write(s.replace(o,n))' "$@"
}
# M1: install.sh records without the pin.
mkdir -p "${WORK}/m1"; cp "${WORK}/ex/"*.sh "${WORK}/m1/"
mut "${WORK}/m1/recorder_call.sh" '&& -n "${OSTLER_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION:-}"' '&& -z "pin-dropped"' || exit 2
# M2: consent_cli records the base version for every region.
mkdir -p "${WORK}/v2"; cp -R "${REPO}/vendor/legal" "${REPO}/vendor/ostler_security" "${WORK}/v2/"
mut "${WORK}/v2/ostler_security/consent_cli.py" 'wording_version = spoken_capture_recorded_version(args.legal_variant)' 'wording_version = cs.version' || exit 2
# M3: consent.py drops the region from the record.
mkdir -p "${WORK}/v3"; cp -R "${REPO}/vendor/legal" "${REPO}/vendor/ostler_security" "${WORK}/v3/"
mut "${WORK}/v3/ostler_security/consent.py" '        record["legal_note_region"] = legal_note["region"]' '        pass' || exit 2
find "${WORK}" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
for m in "M1 install.sh drops the pin:${REPO}/vendor:${WORK}/m1" "M2 consent_cli drops the variant from the version:${WORK}/v2:${WORK}/ex" "M3 consent.py drops the region field:${WORK}/v3:${WORK}/ex"; do
    IFS=: read -r name vend ex <<< "${m}"
    out="$(verify "${vend}" "${ex}" "mut$(printf %s "${name}" | cut -c2)")"
    if ! grep -q '^EXAMINED' <<< "${out}"; then
        bad "self-test: ${name}: the checker did not run"
    elif grep -q '^FAIL' <<< "${out}"; then
        pass "self-test: ${name} goes red ($(grep -c '^FAIL' <<< "${out}") failures)"
    else
        bad "self-test: ${name} was not caught"
    fi
done

# ── the real thing
out="$(verify "${REPO}/vendor" "${WORK}/ex" real)"
if ! grep -q '^EXAMINED 7 ' <<< "${out}"; then
    echo "${out}"; echo "CANNOT-RUN: the checker did not examine 7 region records"; exit 2
elif ! grep -q '^FAIL' <<< "${out}"; then
    pass "7 regions + a decline + a legacy reuse: each record pins its region, variant, version and the exact shown note; check stays 0"
    for r in GB DE HK US none; do
        "${PY}" -I -c 'import json,sys; x=json.load(open(sys.argv[1]))["records"]["spoken_capture_recording_consent"]; print("  %s: %s  sha256 %s" % (sys.argv[2], x["wording_version"], x["legal_note_sha256"][:12]))' "${WORK}/real/${r}.json" "${r}"
    done
else
    echo "${out}"; fail=1
fi
exit "${fail}"
