#!/usr/bin/env bash
# The spoken-capture legal note follows the Mac's REGION, not its language
# (Andy, 2026-10-24). Launch markets: GB, EU, HK, US; anything else gets the
# neutral core only. Every region line is a best-effort draft that needs
# local professional sign-off; this test pins WHICH lines show, not that the
# law in them is right.
#
# Runs the REAL functions out of install.sh (extracted, not re-implemented)
# against tests/fixtures/legal_region_contract.tsv, the same fixture the GUI's
# LegalRegionContractTests read, then checks:
#   - per row: region ISO, jurisdiction, and that the composed note carries
#     the core, the responsibility sentence, exactly the expected region
#     line(s) and none of the others;
#   - the no-seam path reads `defaults read -g AppleLocale` (stubbed on PATH,
#     never the real one) and an absent AppleLocale gives the core only;
#   - the GUI copy (ViewCopy.json legal_*) equals the bash strings;
#   - the TTY echo and the GUI help both carry the composed note, and no
#     region-blind DE/FR example is left in the always-shown copy;
#   - new keys carry CONSENT, so the l10n legal gate treats them as legal.
# Self-test first: a language-not-region picker and a region-blind picker
# must both go red.
set -uo pipefail
cd "$(dirname "$0")/.."
FIX=tests/fixtures/legal_region_contract.tsv
STRINGS=install.sh.strings.en-GB.sh
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

funcs="$(awk '/^_ostler_legal_apple_locale\(\) \{/{f=1} f{print} /^_ostler_spoken_capture_legal_note\(\) \{/{g=1} g&&/^\}/{exit}' install.sh)"
for fn in _ostler_legal_apple_locale _ostler_legal_country_from_locale _ostler_legal_jurisdiction _ostler_spoken_capture_legal_variant _ostler_spoken_capture_legal_note_for _ostler_spoken_capture_legal_note; do
    grep -q "^${fn}() {" <<< "${funcs}" || { echo "CANNOT-RUN: ${fn} not found in install.sh"; exit 2; }
done

stub="$(mktemp -d)"
trap 'rm -rf "${stub}"' EXIT
# `defaults` stub: prints STUB_APPLE_LOCALE, or exits 1 like a Mac with no Region.
cat > "${stub}/defaults" <<'STUB'
#!/bin/sh
[ "$1 $2 $3" = "read -g AppleLocale" ] || { echo "stub: unexpected defaults $*" >&2; exit 64; }
if [ -n "${STUB_APPLE_LOCALE:-}" ]; then printf '%s\n' "$STUB_APPLE_LOCALE"; exit 0; fi
echo "The domain/default pair of (kCFPreferencesAnyApplication, AppleLocale) does not exist" >&2
exit 1
STUB
chmod +x "${stub}/defaults"

# run_rows FUNCS -> prints one FAIL line per mismatch, nothing when all match.
run_rows() {
    local f="$1"
    PATH="${stub}:${PATH}" bash -c '
        source "$1" >/dev/null 2>&1
        eval "$2"
        all="GB EU DE FR HK US"
        while IFS=$'"'"'\t'"'"' read -r loc iso juris keys; do
            case "$loc" in ""|"#"*|apple_locale) continue ;; esac
            if [[ "$loc" == "<unset>" ]]; then unset OSTLER_APPLE_LOCALE; else export OSTLER_APPLE_LOCALE="$loc"; fi
            [[ "$iso" == "-" ]] && iso=""
            got_iso="$(_ostler_legal_country_from_locale "$(_ostler_legal_apple_locale)")"
            got_j="$(_ostler_legal_jurisdiction "$got_iso")"
            note="$(_ostler_spoken_capture_legal_note)"
            [[ "$got_iso" == "$iso" ]] || echo "FAIL $loc: iso [$got_iso] want [$iso]"
            [[ "$got_j" == "$juris" ]] || echo "FAIL $loc: jurisdiction [$got_j] want [$juris]"
            [[ "$note" == "$MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_PREFIX $MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_CORE $MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_LOCAL"* ]] || echo "FAIL $loc: note does not open with prefix + core + local"
            [[ "$note" == *" $MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_RESPONSIBILITY" ]] || echo "FAIL $loc: note does not end with the responsibility sentence"
            want=" ${keys//,/ } "
            for k in $all; do
                v="MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_$k"
                lk="$(printf %s "$k" | tr "[:upper:]" "[:lower:]")"
                if [[ "$want" == *" $lk "* ]]; then
                    [[ "$note" == *"${!v}"* ]] || echo "FAIL $loc: missing region line $k"
                else
                    [[ "$note" != *"${!v}"* ]] || echo "FAIL $loc: shows region line $k it should not"
                fi
            done
        done < "$3"
    ' _ "${STRINGS}" "$f" "${FIX}"
}

# ── self-test: the predicate must reject a language picker and a region-blind one
# Mutants are made with python (exact, counted replacements): bash 3.2 keeps
# the quotes of a quoted ${var//pat/rep} replacement, which breaks the mutant
# and would make a broken mutant read as a caught one.
mutate() { # $1 = funcs, then pairs of OLD NEW; exits 2 unless each OLD occurs exactly once
    python3 -I -c '
import sys
s = sys.argv[1]
for old, new in zip(sys.argv[2::2], sys.argv[3::2]):
    if s.count(old) != 1:
        sys.exit("mutant did not apply: " + old)
    s = s.replace(old, new)
sys.stdout.write(s)
' "$@"
}
# Language picker: take the part BEFORE the first - or _ (the language), and ignore rg=.
rg_mutant="$(mutate "${funcs}" 'cc="${base##*_}"' 'cc="${base%%[-_]*}"' 'rg="${rg:0:2}"' 'rg=""')" \
    || { echo "CANNOT-RUN self-test: the language mutant did not apply"; exit 2; }
blind_mutant="$(mutate "${funcs}" '    _ostler_spoken_capture_legal_note_for "${cc:-none}"' '    _ostler_spoken_capture_legal_note_for none')" \
    || { echo "CANNOT-RUN self-test: the region-blind mutant did not apply"; exit 2; }
out="$(run_rows "${rg_mutant}")"
if grep -q "FAIL zh-Hant_GB" <<< "${out}"; then
    pass "self-test: language-not-region picker rejected ($(grep -c FAIL <<< "${out}") mismatches, incl. zh-Hant_GB)"
else
    bad "self-test: language-not-region picker was accepted"
fi
out="$(run_rows "${blind_mutant}")"
if grep -q "FAIL en_GB" <<< "${out}"; then
    pass "self-test: region-blind picker rejected ($(grep -c FAIL <<< "${out}") mismatches)"
else
    bad "self-test: region-blind picker was accepted"
fi

# ── the real functions against the shared fixture
rows=$(grep -vcE '^(#|apple_locale|$)' "${FIX}")
out="$(run_rows "${funcs}")"
if [[ -z "${out}" ]]; then pass "all ${rows} fixture rows show the expected lines"; else echo "${out}"; fail=1; fi

# ── the no-seam path reads defaults (stubbed): region set, and region absent
nos() { PATH="${stub}:${PATH}" STUB_APPLE_LOCALE="$1" bash -c 'unset OSTLER_APPLE_LOCALE; source "$1" >/dev/null 2>&1; eval "$2"; _ostler_spoken_capture_legal_note' _ "${STRINGS}" "${funcs}"; }
gb_line="$(bash -c 'source "$1" >/dev/null 2>&1; printf %s "$MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_GB"' _ "${STRINGS}")"
[[ "$(nos zh-Hant_GB)" == *"${gb_line}"* ]] && pass "no seam: defaults zh-Hant_GB gives the GB line" || bad "no seam: defaults zh-Hant_GB did not give the GB line"
n="$(nos "")"
[[ -n "${n}" && "${n}" != *"GDPR"* && "${n}" != *"Hong Kong"* && "${n}" != *"US states"* ]] \
    && pass "no seam: no AppleLocale gives the neutral core only" || bad "no seam: no AppleLocale gave [${n}]"

# ── GUI copy equals the bash strings; GUI-only legal_local keeps the deletion claim
python3 -I - "${STRINGS}" gui/OstlerInstaller/Resources/ViewCopy.json <<'PY' || fail=1
import json, subprocess, sys
d = json.load(open(sys.argv[2], encoding="utf-8"))["consent_spoken_capture"]
keys = ["PREFIX", "CORE", "LOCAL", "REGION_GB", "REGION_EU", "REGION_DE", "REGION_FR", "REGION_HK", "REGION_US", "RESPONSIBILITY"]
script = 'source "$1" >/dev/null 2>&1; for k in ' + " ".join(keys) + '; do v="MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_$k"; printf "%s\\0" "${!v}"; done'
vals = subprocess.run(["bash", "-c", script, "_", sys.argv[1]], capture_output=True, text=True, check=True).stdout.split("\0")[:-1]
bad = 0
for k, v in zip(keys, vals):
    gk = "legal_" + k.lower()
    if not v or d.get(gk) != v:
        print(f"FAIL ViewCopy {gk} differs from MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_{k}"); bad = 1
if "legal_note" in d:
    print("FAIL ViewCopy still carries the region-blind legal_note"); bad = 1
if "—" in "".join(v for k, v in d.items() if k.startswith("legal_")):
    print("FAIL em dash in GUI legal copy"); bad = 1
if not bad:
    print(f"PASS ViewCopy legal_* equals all {len(keys)} bash strings")
sys.exit(bad)
PY

# ── GUI and install.sh render the SAME note for every fixture row (the
#    consent record pins install.sh's, so it must be the GUI's too)
gui_vs_bash="$(bash -c '
    source "$1" >/dev/null 2>&1; eval "$2"
    while IFS=$'"'"'\t'"'"' read -r loc iso juris keys; do
        case "$loc" in ""|"#"*|apple_locale) continue ;; esac
        [[ "$iso" == "-" ]] && iso=none
        printf "%s\t%s\t%s\n" "$keys" "$iso" "$(_ostler_spoken_capture_legal_note_for "$iso")"
    done < "$3"' _ "${STRINGS}" "${funcs}" "${FIX}" | python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["consent_spoken_capture"]
bad = n = 0
for line in sys.stdin:
    keys, iso, bash_note = line.rstrip("\n").split("\t", 2)
    regs = [] if keys == "-" else keys.split(",")
    gui = " ".join([d["legal_prefix"], d["legal_core"], d["legal_local"]] + [d["legal_region_" + r] for r in regs] + [d["legal_responsibility"]])
    n += 1
    if gui != bash_note:
        bad += 1; print("FAIL " + iso + ": GUI note differs from install.sh note")
print(("PASS" if not bad else "FAIL") + f" GUI composition equals install.sh note on {n - bad} of {n} rows")
' gui/OstlerInstaller/Resources/ViewCopy.json)"
echo "${gui_vs_bash}"
grep -q '^FAIL' <<< "${gui_vs_bash}" && fail=1

# ── the surfaces the customer sees carry the composed note, and nothing region-blind
grep -qF 'echo -e "  ${DIM}${_OSTLER_SPOKEN_CAPTURE_LEGAL_NOTE}${NC}"' install.sh \
    && pass "TTY echoes the composed note" || bad "TTY does not echo the composed note"
grep -qF '"${MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP}"$'"'"'\n\n'"'"'"${_OSTLER_SPOKEN_CAPTURE_LEGAL_NOTE}" "" "consent_spoken_capture"' install.sh \
    && pass "GUI help appends the composed note" || bad "GUI help does not append the composed note"
grep -qF 'LegalRegion.spokenCaptureLegalNote(' gui/OstlerInstaller/Views/OnboardingQuestionView.swift \
    && pass "GUI view renders LegalRegion.spokenCaptureLegalNote" || bad "GUI view does not render the region note"
always="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n%s\n%s\n%s" "$MSG_CONSENT_SPOKEN_CAPTURE_LAW" "$MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP" "$MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_CORE" "$MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_RESPONSIBILITY"' _ "${STRINGS}")"
if grep -qiE 'German|France|French|226-1|section 201|GDPR' <<< "${always}"; then
    bad "always-shown copy still names a jurisdiction"
else
    pass "always-shown copy names no jurisdiction"
fi
newkeys="$(grep -oE '^MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_[A-Z_]+' "${STRINGS}")"
[[ $(wc -l <<< "${newkeys}") -eq 10 ]] && pass "10 legal keys, all named CONSENT (l10n legal gate)" || bad "expected 10 MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_* keys, got: ${newkeys}"
if grep -E '^MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_' "${STRINGS}" | grep -q $'\xe2\x80\x94'; then bad "em dash in a legal key"; else pass "no em dash in the legal keys"; fi

exit "${fail}"
