#!/usr/bin/env bash
# THREE SURFACES DESCRIBE THE UPGRADE PAYLOAD. THIS BINDS THEM TOGETHER.
#
# WHY THIS EXISTS. Measured on v1.0.37, mounted from the shipped DMG:
#
#   the cut produced   assistant-agent/bin/ostler-assistant     (bare binary)
#   upgrade-mode wants assistant-agent/OstlerAssistant.app      (signed bundle)
#   the test fixture   assistant-agent/OstlerAssistant.app      (signed bundle)
#
# install.sh's _upg_stage_daemon resolves _UPG_PAYLOAD_APP first and, finding
# only _UPG_PAYLOAD_BIN, logs "payload ships a bare binary ... refusing" and
# returns 20. So every DMG cut carried an upgrade payload its own upgrade path
# refuses, silently, on the customer's machine.
#
# IT WAS INVISIBLE BECAUSE THE ONLY TEST BUILT ITS OWN PAYLOAD.
# tests/test_upgrade_mode_invariants.sh is a good behavioural suite and it
# passes: it hand-builds a fixture in the CORRECT shape and proves upgrade-mode
# works against it. It has never once seen what stage-payload actually emits.
# A fixture nothing emits passes for ever while the real shape leaks past.
#
# So this test deliberately does NOT re-test upgrade-mode's behaviour. It tests
# the thing no single component could see: that the shape the CUT WRITES is the
# shape the INSTALLER READS is the shape the FIXTURE MODELS. Static, seconds
# long, and it fails on the exact defect that shipped 37 times.
#
# EVERY ASSERTION CARRIES A DENOMINATOR. An extraction that silently finds
# nothing would make every comparison vacuously true, which is the failure mode
# that produced the bug in the first place, so each parse must find a value or
# the test dies naming the file it could not read.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$ROOT/gui/Makefile"
INSTALL_SH="$ROOT/install.sh"
FIXTURE="$ROOT/tests/test_upgrade_mode_invariants.sh"

PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
die(){ printf '\nFATAL: %s\n' "$1" >&2; exit 2; }

for f in "$MAKEFILE" "$INSTALL_SH" "$FIXTURE"; do
    [[ -f "$f" ]] || die "cannot read $f -- this test cannot conclude anything"
done

# --- Surface 1: what does install.sh REQUIRE? -------------------------------
# _UPG_PAYLOAD_APP="${_UPG_PAYLOAD_AGENT}/OstlerAssistant.app"
WANT_APP="$(python3 - "$INSTALL_SH" <<'PY'
import re,sys
src=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'_UPG_PAYLOAD_APP="\$\{_UPG_PAYLOAD_AGENT\}/([^"]+)"',src)
print(m.group(1) if m else '')
PY
)"
[[ -n "$WANT_APP" ]] || die "could not extract _UPG_PAYLOAD_APP from install.sh (predicate is wrong, not the code)"
ok "install.sh names its required payload bundle: assistant-agent/$WANT_APP"

WANT_BIN="$(python3 - "$INSTALL_SH" <<'PY'
import re,sys
src=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'_UPG_PAYLOAD_BIN="\$\{_UPG_PAYLOAD_AGENT\}/([^"]+)"',src)
print(m.group(1) if m else '')
PY
)"
[[ -n "$WANT_BIN" ]] || die "could not extract _UPG_PAYLOAD_BIN from install.sh"
ok "install.sh names the REFUSED legacy shape: assistant-agent/$WANT_BIN"

# The whole test is meaningless if these two are the same string.
[[ "$WANT_APP" != "$WANT_BIN" ]] \
    && ok "the accepted and refused shapes are genuinely different paths" \
    || no "accepted and refused shapes parsed identical -- extraction is broken"

# install.sh must still REFUSE the bare shape. If someone makes upgrade-mode
# tolerant, this test's premise dies and it should say so rather than pass.
if grep -Fq 'payload ships a bare binary' "$INSTALL_SH"; then
    ok "install.sh still refuses a bare-binary payload (premise holds)"
else
    no "install.sh no longer refuses a bare binary -- re-derive this contract"
fi

# --- Surface 2: what does the CUT actually write? ---------------------------
# Read only the stage-payload recipe, not the whole Makefile: a mention of the
# path in some other target must not satisfy this.
RECIPE="$(python3 - "$MAKEFILE" <<'PY'
import re,sys
lines=open(sys.argv[1],encoding='utf-8',errors='replace').read().split('\n')
out=[];inr=False
for ln in lines:
    if re.match(r'^stage-payload:',ln): inr=True; continue
    if inr and re.match(r'^[A-Za-z0-9_.-]+:',ln): break
    if inr: out.append(ln)
print('\n'.join(out))
PY
)"
[[ -n "$RECIPE" ]] || die "could not isolate the stage-payload recipe in gui/Makefile"
RECIPE_LINES="$(printf '%s\n' "$RECIPE" | grep -c . || true)"
ok "isolated the stage-payload recipe ($RECIPE_LINES non-blank lines examined)"

if printf '%s\n' "$RECIPE" | grep -Fq "assistant-agent/$WANT_APP"; then
    ok "the cut WRITES the bundle install.sh requires"
else
    no "the cut does NOT write assistant-agent/$WANT_APP -- upgrade-mode will exit 20 on every DMG"
fi

# Must not WRITE the refused path. A mention is fine and expected: the recipe
# now names it in a guard that refuses it. Only a copy INTO it is the defect,
# so match write verbs targeting that path rather than the bare string.
if printf '%s\n' "$RECIPE" \
     | grep -E '(^|[[:space:]])(cp|ditto|install|mv)[[:space:]]' \
     | grep -Fq "assistant-agent/$WANT_BIN"; then
    no "the cut still WRITES the refused shape assistant-agent/$WANT_BIN into the payload"
else
    ok "no write verb targets the refused bare-binary path"
fi

# The bundle must be copied whole. Resolving the inner Mach-O out of the SOURCE
# bundle is the original defect wearing a right-looking path: it hands `cp` a
# lone binary and drops the _CodeSignature the runtime verify depends on.
# Scope to AGENT_SRC so the legitimate chmod on the COPIED bundle is not a hit.
if printf '%s\n' "$RECIPE" | grep -Fq "AGENT_SRC/$WANT_APP/Contents/MacOS"; then
    no "the recipe resolves the inner binary of the SOURCE bundle -- that discards the signature"
else
    ok "the recipe takes the source .app as a bundle, not as a path to its inner binary"
fi

# --- Surface 3: does the behavioural fixture model the shipped shape? -------
if grep -Fq "assistant-agent/$WANT_APP" "$FIXTURE"; then
    ok "the upgrade fixture models the same bundle shape the cut now writes"
else
    no "the upgrade fixture models a shape neither the cut nor install.sh uses"
fi

# --- Surface 4: the cut must verify what it embedded ------------------------
# Presence is not behaviour. The recipe has to run the same codesign check the
# runtime will run, or a correctly-shaped but unsigned bundle still ships.
if printf '%s\n' "$RECIPE" | grep -Fq 'codesign --verify --deep --strict'; then
    ok "the cut verifies the embedded bundle's signature before sealing"
else
    no "the cut embeds a bundle it never signature-verifies"
fi

TEAM="$(python3 - "$INSTALL_SH" <<'PY'
import re,sys
src=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'subject\.OU\]\s*=\s*"([A-Z0-9]+)"',src)
print(m.group(1) if m else '')
PY
)"
[[ -n "$TEAM" ]] || die "could not extract the Team pin from install.sh"
if printf '%s\n' "$RECIPE" | grep -Fq "$TEAM"; then
    ok "cut-time and runtime pin the SAME Team ($TEAM)"
else
    no "cut verifies against a different Team pin than the runtime requires"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]] || exit 1
echo "PAYLOAD SHAPE CONTRACT HOLDS ACROSS ALL THREE SURFACES"
