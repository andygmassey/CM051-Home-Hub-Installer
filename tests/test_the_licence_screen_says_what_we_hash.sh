#!/usr/bin/env bash
#
# test_the_licence_screen_says_what_we_hash.sh
#
# PROVED-RED-BY: this file, mutation 1 and mutation 2.
#
# THE HOLE THIS CLOSES. The personal-use licence acknowledgement exists twice:
#
#   what the customer READS   install.sh.strings.en-GB.sh, the
#                             MSG_TERMS_PERSONAL_USE_* constants the screen
#                             echoes one by one
#   what we HASH AND STORE    vendor/legal/consent_strings.py, the versioned
#                             ConsentString whose sha256 goes into the durable
#                             consent registry as the thing they agreed to
#
# test_the_licence_acknowledgement_reaches_the_customer.sh already proves the
# screen renders and that the stored hash is this build's bundled wording. It
# cannot prove the two texts SAY THE SAME THING, and it was never meant to: it
# stubs every MSG_* with a placeholder like [MSG_TERMS_PERSONAL_USE_BUSINESS],
# which is exactly right for asking "does the slot render" and says nothing
# about the words in it.
#
# So today they match, and NOTHING KEEPS THEM MATCHING. Edit the screen copy and
# the customer reads text A, presses OK, and the durable record says they agreed
# to text B. A consent record that names wording the person never saw is worse
# than no record: it looks like evidence.
#
# WHAT THIS ASSERTS, and the direction is deliberate. Every substantive sentence
# the SCREEN shows must appear verbatim inside the text we HASH. Not the reverse:
# the hashed text legitimately carries a tickbox line and headings the screen
# renders separately, so demanding set equality would fail on a difference that
# is not a drift. What must never happen is the person reading a sentence that is
# not in the record.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRINGS="$HERE/install.sh.strings.en-GB.sh"
CONSENT="$HERE/vendor/legal/consent_strings.py"
for f in "$STRINGS" "$CONSENT"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; }

# The eight substantive strings. HEADING and INTRO are excluded by name rather
# than by accident: they are the screen's own framing, not licence terms, and
# pinning the list here means a new term added to the screen and not to the
# hashed text fails this file rather than silently widening it.
TERM_VARS="MSG_TERMS_PERSONAL_USE_BUSINESS MSG_TERMS_PERSONAL_USE_RECORDER MSG_TERMS_PERSONAL_USE_ASK_HEADING MSG_TERMS_PERSONAL_USE_ASK_1 MSG_TERMS_PERSONAL_USE_ASK_2 MSG_TERMS_PERSONAL_USE_ASK_3 MSG_TERMS_PERSONAL_USE_LEGAL"

# $1 = strings file, $2 = consent file. Prints one line per mismatch.
compare() {
    python3 - "$1" "$2" "$TERM_VARS" <<'PY'
import re, sys
strings_path, consent_path, varlist = sys.argv[1], sys.argv[2], sys.argv[3].split()
src = open(strings_path, encoding="utf-8").read()

def value_of(name):
    m = re.search(r'^%s="((?:[^"\\]|\\.)*)"' % re.escape(name), src, re.M)
    return None if m is None else m.group(1).replace('\\"', '"').replace("\\\\", "\\")

cs = open(consent_path, encoding="utf-8").read()
i = cs.find('tickbox_id="personal_use_only"')
if i < 0:
    print("MISSING-CONSENT-STRING personal_use_only is not declared at all")
    raise SystemExit(0)
j = cs.find('text="""', i)
k = cs.find('"""', j + 8)
hashed = cs[j + 8:k]

# Normalise only whitespace. Wording differences are the subject; a line wrap
# is not, and a check that cried at a re-wrap would be turned off.
norm = lambda s: " ".join(s.split())
hashed_n = norm(hashed)

for name in varlist:
    v = value_of(name)
    if v is None:
        print(f"ABSENT {name} is not defined in the strings file")
        continue
    if not v.strip():
        print(f"EMPTY {name} renders nothing, so the screen shows a blank where a term should be")
        continue
    if norm(v) not in hashed_n:
        print(f"DRIFT {name}: the screen shows a sentence that is not in the text we hash")
PY
}

echo "test_the_licence_screen_says_what_we_hash"

# ── 0. CONTROL: the comparator can find something. A predicate that finds
#       nothing in either direction would print a clean zero for a file it
#       never read.
probe="$(python3 - "$CONSENT" <<'PY'
import sys
cs = open(sys.argv[1], encoding="utf-8").read()
i = cs.find('tickbox_id="personal_use_only"')
j = cs.find('text="""', i); k = cs.find('"""', j + 8)
print(len(cs[j+8:k]))
PY
)"
if [ "${probe:-0}" -gt 500 ]; then
    ok "(0) CONTROL: the hashed licence text was read and is ${probe} characters, so an empty finding below is a real one"
else
    bad "(0) CONTROL FAILED: the hashed licence text read as ${probe:-unreadable} characters; every assertion below would pass vacuously"
fi

# ── 1. THE REAL COMPARISON ──
out="$(compare "$STRINGS" "$CONSENT")"
if [ -z "$out" ]; then
    ok "(1) every sentence the licence screen shows appears verbatim in the text whose hash we store"
else
    bad "(1) the screen and the hashed record have drifted apart" "$out"
fi

# ── 2. AND THE COUNT IS PINNED, so a term deleted from the screen is caught by
#       something. Assertion 1 alone passes trivially if the screen shows nothing.
n_found=0
for v in $TERM_VARS; do
    /usr/bin/grep -qE "^${v}=" "$STRINGS" && n_found=$((n_found+1))
done
if [ "$n_found" -eq 7 ]; then
    ok "(2) all 7 substantive licence terms are still defined, so assertion (1) has a denominator"
else
    bad "(2) only ${n_found} of 7 licence terms are defined; a term was removed from the screen"
fi

# ===========================================================================
# MUTATION. A comparison that agrees with itself today proves nothing about
# tomorrow. Both directions of drift must go RED.
# ===========================================================================
echo
echo "  -- mutation --"
TMP="$(mktemp -d -t licwording_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

# MUTATION 1: the screen copy drifts. One word changed in a term the customer
# reads. This is the realistic accident: someone improves the wording in the
# strings file and never touches the legal package.
sed 's/^MSG_TERMS_PERSONAL_USE_RECORDER="You are the one recording\./MSG_TERMS_PERSONAL_USE_RECORDER="You are not the one recording./' \
    "$STRINGS" > "$TMP/strings-mutant.sh"
if cmp -s "$STRINGS" "$TMP/strings-mutant.sh"; then
    bad "(M1) the mutant could not be built, so nothing was mutation-tested" "re-point the sed at MSG_TERMS_PERSONAL_USE_RECORDER"
else
    m1="$(compare "$TMP/strings-mutant.sh" "$CONSENT")"
    if printf '%s' "$m1" | /usr/bin/grep -q 'DRIFT MSG_TERMS_PERSONAL_USE_RECORDER'; then
        ok "(M1) RED ON DRIFT: changing one sentence of the screen copy is caught, so assertion (1) is load-bearing"
    else
        bad "(M1) MUTANT SURVIVED: the screen said something the hashed text does not and the comparison stayed silent" "$m1"
    fi
fi

# MUTATION 2: the hashed text drifts instead. Same defect from the other end --
# the legal package is revised and the screen is left behind. The customer then
# reads the OLD terms and the record names the NEW ones.
python3 - "$CONSENT" "$TMP/consent-mutant.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = "You are the one recording. Ostler is the tool."
if needle not in src:
    sys.stderr.write("MUTATION 2 DID NOT APPLY: the sentence this test mutates is not in the consent text\n")
    raise SystemExit(3)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(needle, "The recorder is somebody else entirely.", 1))
PY
m2_built=$?
if [ "$m2_built" != 0 ]; then
    bad "(M2) the mutant could not be built, so the other direction was not tested" "re-point this test at the consent wording"
else
    m2="$(compare "$STRINGS" "$TMP/consent-mutant.py")"
    if printf '%s' "$m2" | /usr/bin/grep -q 'DRIFT MSG_TERMS_PERSONAL_USE_RECORDER'; then
        ok "(M2) RED ON THE OTHER DIRECTION: revising the hashed text without the screen is caught too"
    else
        bad "(M2) MUTANT SURVIVED: the hashed record was revised, the screen still showed the old words, and nothing noticed" "$m2"
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
