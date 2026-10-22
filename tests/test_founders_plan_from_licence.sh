#!/usr/bin/env bash
#
# tests/test_founders_plan_from_licence.sh
#
# FOUNDERS (Andy, 2026-10-23, option A): the included Pro window is read from
# the customer's LICENCE. Founder = 6 months, everyone else = 3, and nothing
# defaults to founder.
#
# WHAT WAS WRONG ON main BEFORE THIS TEST (measured, see the PR body):
#   - every install got a 30-day Hub window and "first 30 days" copy; the
#     superseded #3083 would have made it 180 days for EVERY install, because
#     nothing set OSTLER_INCLUDED_PLAN and its default was founding.
#   - the customer copy never said the included months auto-renew into paid
#     Pro, and said "first month free" / "after the trial".
#   - a licence carrying an offer code never reached the install end screen.
#
# THE SUBJECT OF EVERY LIMB IS A PERSON HOLDING A LICENCE:
#   A  the real install.sh gate, run on REAL SIGNED synthetic licences, reads
#      plan / offer_code / founder_number (and refuses to read them from an
#      unsigned edit).
#   B  the plan reader against hostile and degenerate licence bodies: a bad
#      plan, a code with shell/URL metacharacters, a bool founder number, a
#      malformed file: all land on STANDARD with no code.
#   C  the G2 activation block, extracted from install.sh, writes the 6 or 3
#      month Hub window; an unverified install is never founding.
#   D  the end screen: code + redeem link printed and persisted; "code follows"
#      when the pool was empty; nothing at all for an install whose licence
#      named no plan; a stale offer is cleared by a reinstall that names none.
#   E  the GUI's ProOffer parser, COMPILED from InstallCompleteView.swift,
#      accepts a good file and refuses a forged host / hostile code.
#   F  the customer copy: auto-renew disclosed, no "first month free" /
#      "30 days of Ostler Pro" left in any customer-facing source.
#
# SYNTHETIC DATA ONLY. Keys are generated inside this run from a fixed
# non-secret seed (the mint side is extracted from
# test_licence_tier_reaches_the_hub.sh, which pins it to RFC 8032 7.1). Offer
# codes below are obviously fake. No keychain, no TCC, no network.
#
# Exit 0 pass, 1 fail, 99 CANNOT-RUN. Bash 3.2 portable.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
GATE_SRC="${REPO_ROOT}/vendor/cm041/assistant_api/subscription_gate.py"
SWIFT_VIEW="${REPO_ROOT}/gui/OstlerInstaller/Views/InstallCompleteView.swift"
TIER_TEST="${HERE}/test_licence_tier_reaches_the_hub.sh"

PASS=0
FAIL=0
CANNOT=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
cannot_run() { echo "CANNOT-RUN: $1" >&2; echo "  NOTHING was checked. This is not a pass." >&2; exit 99; }

for f in "$INSTALL_SH" "$STRINGS" "$GATE_SRC" "$SWIFT_VIEW" "$TIER_TEST"; do
    [[ -f "$f" ]] || cannot_run "missing ${f}"
done
command -v python3 >/dev/null 2>&1 || cannot_run "no python3"

WORK="$(mktemp -d -t ostler-founders.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── Mint side: extracted, not copied ───────────────────────────────
sed -n "/<<'MINT_PY'/,/^MINT_PY\$/p" "$TIER_TEST" | sed '1d;$d' >"${WORK}/mint_base.py"
[[ -s "${WORK}/mint_base.py" ]] || cannot_run "could not extract the mint side from ${TIER_TEST}"
# Drop the trailing main() call, then add a mint that takes extra JSON fields.
sed '$d' "${WORK}/mint_base.py" >"${WORK}/mint_lib.py"
tail -1 "${WORK}/mint_base.py" | grep -qx 'main()' || cannot_run "mint side no longer ends in main()"
cat >"${WORK}/mint.py" <<'MINT2'
import base64, json, sys
exec(open(sys.argv[1]).read())
cmd = sys.argv[2]
if cmd == "pubkey":
    sys.stdout.write(binascii.hexlify(public_key(SEED)).decode())
else:
    out, extra = sys.argv[3], json.loads(sys.argv[4])
    doc = body("2099-01-01T00:00:00Z")
    doc.update(extra)
    doc["signature"] = base64.b64encode(sign(SEED, canonical(doc))).decode()
    if len(sys.argv) > 5 and sys.argv[5] == "TAMPER":
        doc["plan"] = "founding"   # edited AFTER signing
    with open(out, "w") as handle:
        json.dump(doc, handle, indent=2, sort_keys=True)
MINT2
PUBKEY="$(python3 "${WORK}/mint.py" "${WORK}/mint_lib.py" pubkey)"
[[ "${#PUBKEY}" -eq 64 ]] || cannot_run "synthetic public key is not 64 hex chars"
mint() { python3 "${WORK}/mint.py" "${WORK}/mint_lib.py" mint "$@"; }

# ── Limb A. The real gate, real signed licences ────────────────────
run_gate() {
    local licence="$1" sandbox rc=0
    sandbox="$(mktemp -d "${WORK}/home.XXXXXX")"
    mkdir -p "${sandbox}/.ostler/license"
    cp "$licence" "${sandbox}/.ostler/license/license.json"
    env -i PATH="$PATH" HOME="$sandbox" TERM="dumb" OSTLER_GUI=1 \
        OSTLER_TEST_STOP_AFTER_LICENCE_GATE=1 \
        OSTLER_LICENSE_PUBKEY_OVERRIDE="$PUBKEY" \
        /bin/bash "$INSTALL_SH" >"${WORK}/gate.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}
gate_line() { grep '^OSTLER_TEST: included_plan=' "${WORK}/gate.out" || true; }

a_case() {
    local label="$1" extra="$2" want="$3" lic="${WORK}/a.json" rc got
    mint "$lic" "$extra"
    rc="$(run_gate "$lic")"
    got="$(gate_line)"
    if [[ "$rc" != "0" ]]; then
        bad "${label}: the gate refused a valid licence (exit ${rc})"; return
    fi
    if [[ "$got" == "OSTLER_TEST: ${want}" ]]; then
        ok "${label}"
    else
        bad "${label}: wanted '${want}', got '${got}'"
    fi
}

a_case "A1 a founder licence is a founder, with number and code" \
    '{"plan":"founding","offer_code":"FNDRTEST0001","founder_number":7}' \
    "included_plan=founding source=licence offer_code=FNDRTEST0001 founder_number=7"
a_case "A2 a standard licence (null code and number) is standard" \
    '{"plan":"standard","offer_code":null,"founder_number":null}' \
    "included_plan=standard source=licence offer_code= founder_number="
a_case "A3 a standard licence with a code keeps the code, no founder number" \
    '{"plan":"standard","offer_code":"STDRTEST0002","founder_number":null}' \
    "included_plan=standard source=licence offer_code=STDRTEST0002 founder_number="
a_case "A4 a LEGACY licence (no plan field) is standard, source=default, never founding" \
    '{}' \
    "included_plan=standard source=default offer_code= founder_number="
a_case "A5 an unrecognised plan is standard" \
    '{"plan":"platinum","offer_code":null,"founder_number":null}' \
    "included_plan=standard source=licence offer_code= founder_number="
a_case "A6 a hostile offer code is dropped, the plan survives" \
    '{"plan":"founding","offer_code":"X;touch /tmp/pwn","founder_number":3}' \
    "included_plan=founding source=licence offer_code= founder_number=3"

# A7. The negative control for the limb: a licence edited to founding AFTER
# signing is refused by the gate, so the plan cannot be forged by hand.
mint "${WORK}/a7.json" '{"plan":"standard","offer_code":null,"founder_number":null}' TAMPER
rc7="$(run_gate "${WORK}/a7.json")"
if [[ "$rc7" != "0" && -z "$(gate_line)" ]]; then
    ok "A7 a licence hand-edited to founding after signing is refused and reads no plan"
else
    bad "A7 a tampered licence was accepted (rc=${rc7}) or still reported a plan"
fi

# ── Extract install.sh functions once ──────────────────────────────
extract_fn() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) \\{" { on = 1 }
        on { print }
        on && /^}$/ { exit }' "$INSTALL_SH"
}
for fn in _ostler_licence_plan_read _ostler_licence_plan_apply _ostler_pro_offer_report; do
    extract_fn "$fn" >"${WORK}/${fn}.sh"
    if [[ ! -s "${WORK}/${fn}.sh" ]]; then
        # A missing function is a FAILURE of the product (the plan is never
        # read / the offer never shown), not a reason to skip the limb.
        bad "W0 ${fn} does not exist in install.sh"
        printf '%s() { echo "MISSING %s"; return 1; }\n' "$fn" "$fn" >"${WORK}/${fn}.sh"
    fi
done
# Strings the functions print through.
STRINGS_FOR_FN="${WORK}/strings.sh"
{
    grep '^MSG_INFO_PRO_OFFER_' "$STRINGS"
    grep '^MSG_INFO_SUBSCRIPTION_PRICING_HINT=' "$STRINGS"
} >"$STRINGS_FOR_FN"
[[ "$(grep -c '^MSG_INFO_PRO_OFFER_' "$STRINGS_FOR_FN")" -ge 5 ]] \
    || bad "W0 MSG_INFO_PRO_OFFER_* strings missing from the catalogue"

# Run a snippet in a clean bash with the extracted functions and stubs.
fn_env() { # fn_env <home> <snippet>
    env -i PATH="$PATH" HOME="$1" /bin/bash -c '
        set -u
        info() { printf "INFO %s\n" "$*"; }
        warn() { printf "WARN %s\n" "$*"; }
        OSTLER_INCLUDED_PLAN="standard"; OSTLER_INCLUDED_PLAN_SOURCE="default"
        OSTLER_OFFER_CODE=""; OSTLER_FOUNDER_NUMBER=""
        . "'"${STRINGS_FOR_FN}"'"
        . "'"${WORK}/_ostler_licence_plan_read.sh"'"
        . "'"${WORK}/_ostler_licence_plan_apply.sh"'"
        OSTLER_OFFER_REDEEM_URL_TEMPLATE="https://apps.apple.com/redeem?ctx=offercodes&id=6767103373&code="
        . "'"${WORK}/_ostler_pro_offer_report.sh"'"
        '"$2"'
    ' 2>&1
}

# ── Limb B. The reader against degenerate bodies ───────────────────
b_case() {
    local label="$1" body="$2" want="$3" f="${WORK}/b.json" got
    printf '%s' "$body" >"$f"
    got="$(fn_env "$WORK" '_ostler_licence_plan_apply python3 "'"$f"'"; echo "plan=$OSTLER_INCLUDED_PLAN src=$OSTLER_INCLUDED_PLAN_SOURCE code=$OSTLER_OFFER_CODE num=$OSTLER_FOUNDER_NUMBER"')"
    if [[ "$got" == "$want" ]]; then ok "$label"; else bad "${label}: wanted '${want}', got '${got}'"; fi
}
b_case "B1 plan as a number is standard"          '{"plan":1}'                                   "plan=standard src=default code= num="
b_case "B2 plan in capitals is still founding"    '{"plan":"FOUNDING"}'                          "plan=founding src=licence code= num="
b_case "B3 founder_number true is not a number"   '{"plan":"founding","founder_number":true}'    "plan=founding src=licence code= num="
b_case "B4 founder_number 0 and -4 are refused"   '{"plan":"founding","founder_number":-4}'      "plan=founding src=licence code= num="
b_case "B5 founder_number as a string is refused" '{"plan":"founding","founder_number":"7"}'     "plan=founding src=licence code= num="
b_case "B6 a code with a space is refused"        '{"plan":"standard","offer_code":"AB CD1234"}' "plan=standard src=licence code= num="
b_case "B7 a code with a newline is refused"      '{"plan":"standard","offer_code":"ABCD1234\n&x=1"}' "plan=standard src=licence code= num="
b_case "B8 a 3-char code is refused"              '{"plan":"standard","offer_code":"AB1"}'       "plan=standard src=licence code= num="
b_case "B9 malformed JSON is standard, no code"   '{"plan":'                                     "plan=standard src=default code= num="
b_case "B10 a JSON array is standard"             '[1,2]'                                        "plan=standard src=default code= num="
got="$(fn_env "$WORK" '_ostler_licence_plan_apply python3 "'"${WORK}/does-not-exist.json"'"; echo "plan=$OSTLER_INCLUDED_PLAN src=$OSTLER_INCLUDED_PLAN_SOURCE"')"
if [[ "$got" == "plan=standard src=default" ]]; then ok "B11 a missing licence file is standard"; else bad "B11 missing file: '${got}'"; fi
got="$(fn_env "$WORK" '_ostler_licence_plan_apply /nonexistent/python3 /dev/null; echo "plan=$OSTLER_INCLUDED_PLAN"')"
if grep -q 'WARN Could not read the Pro plan' <<<"$got" && grep -q 'plan=standard' <<<"$got"; then
    ok "B12 an interpreter that cannot run warns and stays standard (not silent, not founding)"
else
    bad "B12 broken interpreter: '${got}'"
fi

# ── Limb C. The G2 activation block, extracted from install.sh ─────
awk '/^# ── First-month-free subscription activation \(G2\)/{on=1}
     on && /^if python3 -c "$/ {grab=1; next}
     grab && /^" 2>&1; then$/ {exit}
     grab {print}' "$INSTALL_SH" >"${WORK}/g2.py"
[[ -s "${WORK}/g2.py" ]] || cannot_run "could not extract the G2 python block from install.sh"
sed -i.bak "s|\${SCRIPT_DIR}|${REPO_ROOT}|g" "${WORK}/g2.py"

g2_months() { # g2_months <label> <want_months|none> <ENV=VAL>...
    local label="$1" want="$2"; shift 2
    local state="${WORK}/state.$RANDOM.json" rc=0 out
    out="$(env -i PATH="$PATH" HOME="$WORK" OSTLER_SUBSCRIPTION_STATE="$state" "$@" \
        python3 "${WORK}/g2.py" 2>&1)" || rc=$?
    if [[ "$rc" != "0" ]]; then bad "${label}: G2 block failed rc=${rc}: ${out}"; return; fi
    python3 - "$state" "$want" "$label" <<'PY' && ok "$label" || bad "$label"
import json, sys
from datetime import datetime, timezone
st = json.load(open(sys.argv[1]))
want = sys.argv[2]
exp = datetime.fromisoformat(st["expires_at"].replace("Z", "+00:00"))
days = (exp - datetime.now(timezone.utc)).days
lo, hi = {"6": (180, 184), "3": (88, 92)}[want]
if not (lo <= days <= hi):
    print("expected ~%s months (%d..%d days), got %d days; state=%s" % (want, lo, hi, days, st))
    sys.exit(1)
PY
}
g2_months "C1 a verified founding plan gets the 6 month Hub window" 6 \
    OSTLER_LICENCE_TIER=hub OSTLER_LICENCE_TIER_STATE=known OSTLER_INCLUDED_PLAN=founding
g2_months "C2 a verified standard plan gets the 3 month window" 3 \
    OSTLER_LICENCE_TIER=hub OSTLER_LICENCE_TIER_STATE=known OSTLER_INCLUDED_PLAN=standard
g2_months "C3 NO plan in the environment is 3 months, never 6 (the #3083 defect)" 3 \
    OSTLER_LICENCE_TIER=hub OSTLER_LICENCE_TIER_STATE=known
g2_months "C4 an UNVERIFIED install asking for founding is still 3 months" 3 \
    OSTLER_LICENCE_TIER_STATE=unverified OSTLER_INCLUDED_PLAN=founding
g2_months "C5 an unrecognised plan string in the environment is 3 months" 3 \
    OSTLER_LICENCE_TIER=hub OSTLER_LICENCE_TIER_STATE=known OSTLER_INCLUDED_PLAN=gold

# ── Limb D. The end screen ─────────────────────────────────────────
d_home() { mktemp -d "${WORK}/dhome.XXXXXX"; }
URL_BASE="https://apps.apple.com/redeem?ctx=offercodes&id=6767103373&code="

H="$(d_home)"
out="$(fn_env "$H" 'OSTLER_INCLUDED_PLAN=founding; OSTLER_INCLUDED_PLAN_SOURCE=licence; OSTLER_OFFER_CODE=FNDRTEST0001; OSTLER_FOUNDER_NUMBER=7; export OSTLER_INCLUDED_PLAN OSTLER_OFFER_CODE OSTLER_FOUNDER_NUMBER; _ostler_pro_offer_report')"
if grep -qF "Your Ostler Pro offer code: FNDRTEST0001" <<<"$out" \
   && grep -qF "Redeem it in one tap: ${URL_BASE}FNDRTEST0001" <<<"$out" \
   && grep -qF "founder number 7" <<<"$out"; then
    ok "D1 a founder's end screen shows the code and the one-tap redeem link"
else
    bad "D1 founder end screen: ${out}"
fi
if python3 - "${H}/.ostler/state/pro_offer.json" "${URL_BASE}FNDRTEST0001" <<'PY'
import json, os, stat, sys
p = sys.argv[1]
d = json.load(open(p))
assert d == {"plan": "founding", "months": 6, "offer_code": "FNDRTEST0001",
             "redeem_url": sys.argv[2], "founder_number": 7}, d
assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
PY
then ok "D2 the GUI file is written: 6 months, code, link, mode 600"; else bad "D2 pro_offer.json wrong"; fi

H="$(d_home)"
out="$(fn_env "$H" 'OSTLER_INCLUDED_PLAN=standard; OSTLER_INCLUDED_PLAN_SOURCE=licence; OSTLER_OFFER_CODE=""; export OSTLER_INCLUDED_PLAN OSTLER_OFFER_CODE; _ostler_pro_offer_report')"
if grep -qF "offer code will follow by email" <<<"$out" && ! grep -q "Redeem it in one tap" <<<"$out" \
   && ! grep -q "founder" <<<"$out"; then
    ok "D3 pool empty: a standard buyer is told the code follows, no link, no founder claim"
else
    bad "D3 code-follows screen: ${out}"
fi
python3 - "${H}/.ostler/state/pro_offer.json" <<'PY' && ok "D4 ...and the GUI file says months=3, no code" || bad "D4 pro_offer.json for a no-code standard buyer"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["months"] == 3 and d["offer_code"] is None and d["redeem_url"] is None, d
PY

H="$(d_home)"
mkdir -p "${H}/.ostler/state"; echo '{"stale":true}' >"${H}/.ostler/state/pro_offer.json"
out="$(fn_env "$H" '_ostler_pro_offer_report')"
if [[ -z "$out" && ! -e "${H}/.ostler/state/pro_offer.json" ]]; then
    ok "D5 an install whose licence named no plan prints nothing and clears a stale offer"
else
    bad "D5 no-plan install printed '${out}' or left a stale file"
fi

# ── Limb E. The GUI parser, compiled ───────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
    echo "  CANNOT-RUN  E (GUI ProOffer parser): no swiftc on this host"; CANNOT=$((CANNOT + 1))
else
    {
        echo "import Foundation"
        echo "enum InstallCompleteView {"
        awk '/^    struct ProOffer: Equatable \{/{on=1} on{print} on && /^    \}$/{exit}' "$SWIFT_VIEW"
        echo "}"
        cat <<'SWIFT'
func load(_ json: String) -> InstallCompleteView.ProOffer? {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("po-\(UUID().uuidString).json")
    try! json.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return InstallCompleteView.ProOffer.load(from: url)
}
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   \(what)" : "FAIL \(what)"); if !ok { failures += 1 } }
let good = load(#"{"plan":"founding","months":6,"offer_code":"FNDRTEST0001","redeem_url":"https://apps.apple.com/redeem?ctx=offercodes&id=6767103373&code=FNDRTEST0001","founder_number":7}"#)
check(good?.isFounding == true && good?.months == 6 && good?.offerCode == "FNDRTEST0001" && good?.redeemURL != nil, "good founder file parses")
let std = load(#"{"plan":"standard","months":3,"offer_code":null,"redeem_url":null,"founder_number":null}"#)
check(std != nil && std?.isFounding == false && std?.offerCode == nil && std?.redeemURL == nil, "standard, no code: parses, no link")
let evil = load(#"{"plan":"founding","months":6,"offer_code":"FNDRTEST0001","redeem_url":"https://evil.example.com/redeem?code=FNDRTEST0001"}"#)
check(evil?.offerCode == "FNDRTEST0001" && evil?.redeemURL == nil, "a redeem link on another host is dropped")
let badcode = load(#"{"plan":"founding","months":6,"offer_code":"AB CD&x=1","redeem_url":"https://apps.apple.com/redeem?code=x"}"#)
check(badcode?.offerCode == nil && badcode?.redeemURL == nil, "a hostile code drops code and link")
let odd = load(#"{"plan":"platinum","months":3}"#)
check(odd != nil && odd?.isFounding == false, "an unknown plan renders as standard, never founding")
check(load("{") == nil, "malformed file is no offer")
check(load(#"{"plan":"founding","months":0}"#) == nil, "zero months is no offer")
exit(failures == 0 ? 0 : 1)
SWIFT
    } >"${WORK}/probe.swift"
    # -parse-as-library off: top-level code in main.swift is needed, so name it.
    mkdir -p "${WORK}/swift" && cp "${WORK}/probe.swift" "${WORK}/swift/main.swift"
    if swiftc -o "${WORK}/swift/probe" "${WORK}/swift/main.swift" >"${WORK}/swiftc.out" 2>&1; then
        if "${WORK}/swift/probe" >"${WORK}/probe.out" 2>&1; then
            ok "E1 GUI ProOffer parser: $(grep -c '^ok' "${WORK}/probe.out") checks pass, compiled from InstallCompleteView.swift"
        else
            bad "E1 GUI ProOffer parser"; sed 's/^/        /' "${WORK}/probe.out"
        fi
    else
        bad "E1 could not compile the extracted ProOffer"; sed 's/^/        /' "${WORK}/swiftc.out" | head -15
    fi
fi

# ── Limb F. Customer copy ──────────────────────────────────────────
VIEWCOPY="${REPO_ROOT}/gui/OstlerInstaller/Resources/ViewCopy.json"
HINTCOPY="${REPO_ROOT}/gui/OstlerInstaller/Resources/HintCopy.json"
bad_copy="$(grep -niE 'first month free|first 30 days|30 days of ostler pro|30-day free|free for 30 days|after the trial|active for 30 days' \
    "$STRINGS" "$VIEWCOPY" "$HINTCOPY" "${REPO_ROOT}/vendor/VENDOR_ONLY.tsv" || true)"
if [[ -z "$bad_copy" ]]; then ok "F1 no 'first month free' / '30 days of Pro' / 'after the trial' in customer copy"; else bad "F1 stale copy: ${bad_copy}"; fi

# Same grep must find them on the OLD wording (control: the predicate can fail).
if printf '%s\n' 'MSG_X="Activating your first 30 days of Ostler Pro..."' \
    | grep -qiE 'first month free|first 30 days|30 days of ostler pro'; then
    ok "F2 control: the stale-copy pattern does match the old wording"
else
    bad "F2 control: the stale-copy pattern cannot match the old wording"
fi

# shellcheck disable=SC1090
hint="$(. "$STRINGS_FOR_FN"; printf "$MSG_INFO_SUBSCRIPTION_PRICING_HINT" 6)"
if [[ "$hint" == 'Free for 6 months, then $9.99/month. Cancel anytime in Settings. Save with yearly: $79.' ]]; then
    ok "F3 the pricing line is the disclosed auto-renew wording"
else
    bad "F3 pricing line: '${hint}'"
fi
if grep -nE 'Subscribe in the Ostler app on your iPhone to extend|if you want it' "$STRINGS" >/dev/null; then
    bad "F4 opt-in phrasing about the included months is still in the strings"
else
    ok "F4 no opt-in phrasing about the included months"
fi
if LC_ALL=C grep -q $'\xe2\x80\x94' "$STRINGS_FOR_FN" "$VIEWCOPY"; then bad "F5 em dash in founders copy"; else ok "F5 no em dash"; fi

# ── Wiring: nothing defaults to founding in the sources ────────────
if grep -nE 'OSTLER_INCLUDED_PLAN:-founding|OSTLER_INCLUDED_PLAN="founding"|default.*founding|PLAN_DEFAULT *= *PLAN_FOUNDING' \
    "$INSTALL_SH" "$GATE_SRC" | grep -v '^\S*:\s*#' | grep -vE '^[^:]*:[0-9]+:\s*#' >/dev/null; then
    bad "W1 something defaults to founding"
else
    ok "W1 nothing in install.sh or the gate defaults to founding"
fi
call_line="$(awk '/case "\$_lic_rc" in/{on=1} on && /_ostler_licence_plan_apply "\$_lic_python"/{print NR; exit}' "$INSTALL_SH")"
refuse_line="$(awk '/case "\$_lic_rc" in/{on=1} on && /^        10\)/{print NR; exit}' "$INSTALL_SH")"
if [[ -n "$call_line" && -n "$refuse_line" && "$call_line" -lt "$refuse_line" ]]; then
    ok "W2 the plan is read only in the verifier's PASS branch (line ${call_line} < refuse arm ${refuse_line})"
else
    bad "W2 plan read is not inside the PASS branch (call=${call_line:-none} refuse=${refuse_line:-none})"
fi

echo ""
echo "founders plan from licence: ${PASS} passed, ${FAIL} failed, ${CANNOT} could not run"
[[ "$FAIL" -eq 0 ]]
