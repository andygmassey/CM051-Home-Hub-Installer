#!/usr/bin/env bash
#
# test_reuse_run_keeps_the_daily_briefs.sh -- #619
#
# =============================================================================
# THE DEFECT THIS FAILS ON  (#398: the test fails on the ORIGINAL defect first)
# =============================================================================
# install.sh writes two [[cron.jobs]] -- morning-brief and evening-wrap --
# behind a guard that needs a resolved delivery channel:
#
#     if   CHANNEL_IMESSAGE_ENABLED == true && -n CHANNEL_IMESSAGE_ALLOWED
#     elif CHANNEL_WHATSAPP_ENABLED == true && -n CHANNEL_WHATSAPP_RECIPIENT
#
# On the REUSE-SETTINGS re-run that guard is unsatisfiable, and the chain is:
#
#   1. reuse fires ONLY when config/.env exists AND carries USER_ID=,
#      i.e. only after a prior COMPLETE install;
#   2. it restores five values by sourcing .env -- which carries 21 keys and
#      NONE of them CHANNEL_* (control: the keys it DOES carry are found by
#      the same predicate);
#   3. SKIP_PHASE2=true, so the channel questions never run and
#      CHANNEL_IMESSAGE_ENABLED / _ALLOWED stay at false / "";
#   4. the `{ ... } > "$ASSISTANT_CONFIG"` block is NOT gated on SKIP_PHASE2,
#      so it truncates and regenerates config.toml anyway;
#   5. both guard arms are false -> ZERO [[cron.jobs]] written.
#
# The customer silently loses the morning brief and the evening wrap they
# already had -- after an installer prompt whose whole purpose is to tell them
# their previous answers, CHANNELS INCLUDED, are being reused.
#
# ARM A IS THAT EXACT STATE. Against pre-fix install.sh it goes RED.
#
# =============================================================================
# WHY THIS EXTRACTS RATHER THAN REIMPLEMENTS
# =============================================================================
# Arms A-E drive the SHIPPING resolver + emitter, lifted verbatim out of
# install.sh with sed and eval'd, plus the SHIPPING restore function extracted
# by name. A local reimplementation would be a fixture encoding the answer
# instead of the property: it would keep passing after a revert. Extraction
# means these arms go BLIND the moment the code stops existing, and a blind arm
# FAILS here rather than reporting clean (three outcomes, three branches).
#
# Arm F reads install.sh directly, because ordering is not visible from the
# functions alone: the restore MUST run before the truncating redirect. Once
# `{ ... } > "$cfg"` has opened the file it is empty and there is nothing left
# to read -- a correct function called one line too late restores nothing.
#
# ⚠️ FIXTURES ARE SYNTHETIC. No real contact data in a public repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${HERE}/install.sh"

pass=0
fail=0
ok()    { printf '  [PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
blind() { printf '  [CANNOT-RUN] %s -- this guard is blind, not clean\n' "$1"; fail=$((fail + 1)); }

if [ ! -f "$INSTALL_SH" ]; then
    blind "install.sh not found at ${INSTALL_SH}"
    printf 'reuse-run briefs: FAILED\n'; exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t619.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------- extraction ---
# The brief resolver + emitter, verbatim. Anchored on its own first line and
# on the section that follows it, so it survives line-number drift.
BRIEF_SRC="$(sed -n '/^    _brief_channel=""$/,/^    # Skills surface lockdown for v1.0/p' "$INSTALL_SH" \
             | sed '$d')"
if [ -z "$BRIEF_SRC" ]; then
    blind "the brief resolver/emitter block was not found in install.sh"
    printf 'reuse-run briefs: FAILED\n'; exit 1
fi
# ANTI-VACUITY (arm G): the extracted region must actually carry both jobs.
_g_morning="$(printf '%s' "$BRIEF_SRC" | grep -c 'morning-brief')"
_g_evening="$(printf '%s' "$BRIEF_SRC" | grep -c 'evening-wrap')"
if [ "$_g_morning" -gt 0 ] && [ "$_g_evening" -gt 0 ]; then
    ok "G the extracted block really is the brief emitter (morning + evening present)"
else
    bad "G extraction captured the wrong region (morning=${_g_morning} evening=${_g_evening})"
fi

# The three restore helpers, extracted BY NAME. Absent pre-fix -> arms A/E blind.
RESTORE_SRC=""
for _fn in _ostler_config_list_first _ostler_config_section_enabled _ostler_restore_channels_from_existing_config; do
    _src="$(sed -n "/^${_fn}() {\$/,/^}\$/p" "$INSTALL_SH")"
    RESTORE_SRC="${RESTORE_SRC}
${_src}"
done
HAVE_RESTORE=false
if printf '%s' "$RESTORE_SRC" | grep -q '_ostler_restore_channels_from_existing_config() {'; then
    HAVE_RESTORE=true
    eval "$RESTORE_SRC"
fi

# ---------------------------------------------------------------- fixtures ---
# SYNTHETIC ONLY.
FIX_IM="${TMP}/imessage.toml"
cat > "$FIX_IM" <<'EOF'
schema_version = 2

[channels]

[channels.imessage]
enabled = true
allowed_contacts = ["+15550000000", "someone@example.com"]

[gateway]
paired_tokens = ["tok"]
EOF

FIX_WA="${TMP}/whatsapp.toml"
cat > "$FIX_WA" <<'EOF'
schema_version = 2

[channels]

[channels.whatsapp]
enabled = true
mode = "personal"
allowed_numbers = ["+15550000001"]
EOF

FIX_NONE="${TMP}/nochannels.toml"
cat > "$FIX_NONE" <<'EOF'
schema_version = 2

[gateway]
paired_tokens = ["tok"]
EOF

# Drive one scenario. Echoes the emitted TOML on stdout.
# $1 = existing config path ("" for none). Remaining state via env.
run_case() {
    local _cfg="$1"
    (
        set +u
        USER_TZ="Europe/London"
        CHANNEL_IMESSAGE_ENABLED="${IN_IM_ENABLED}"
        CHANNEL_IMESSAGE_ALLOWED="${IN_IM_ALLOWED}"
        CHANNEL_WHATSAPP_ENABLED="${IN_WA_ENABLED}"
        CHANNEL_WHATSAPP_RECIPIENT="${IN_WA_RECIPIENT}"
        if [ "$HAVE_RESTORE" = true ] && [ -n "$_cfg" ]; then
            _ostler_restore_channels_from_existing_config "$_cfg"
        fi
        eval "$BRIEF_SRC"
    )
}

jobs_count() { printf '%s' "$1" | grep -c '^\[\[cron.jobs\]\]'; }
delivery_to() { printf '%s' "$1" | grep -oE 'to = "[^"]*"' | head -1 | sed 's/^to = "//; s/"$//'; }
delivery_ch() { printf '%s' "$1" | grep -oE 'channel = "[^"]*"' | head -1 | sed 's/^channel = "//; s/"$//'; }

printf '== ARM A: THE ORIGINAL FAILING INPUT -- reuse-run state, prior iMessage config ==\n'
IN_IM_ENABLED=false IN_IM_ALLOWED="" IN_WA_ENABLED=false IN_WA_RECIPIENT=""
A_OUT="$(run_case "$FIX_IM")"
A_N="$(jobs_count "$A_OUT")"
if [ "$A_N" -eq 2 ]; then
    ok "A a reuse re-run over an iMessage install still writes both briefs (2 cron jobs)"
else
    bad "A reuse re-run wrote ${A_N} [[cron.jobs]], expected 2 -- the customer lost their briefs"
fi
if [ "$(delivery_ch "$A_OUT")" = "imessage" ] && [ "$(delivery_to "$A_OUT")" = "+15550000000" ]; then
    ok "A delivery is restored to imessage / the first allowed contact"
else
    bad "A wrong delivery: channel='$(delivery_ch "$A_OUT")' to='$(delivery_to "$A_OUT")'"
fi

printf '== ARM B: the control that MUST be zero -- no channel anywhere ==\n'
IN_IM_ENABLED=false IN_IM_ALLOWED="" IN_WA_ENABLED=false IN_WA_RECIPIENT=""
B_OUT="$(run_case "$FIX_NONE")"
B_N="$(jobs_count "$B_OUT")"
if [ "$B_N" -eq 0 ]; then
    ok "B no channel resolved -> ZERO cron jobs (not manufacturing a daily delivery error)"
else
    bad "B expected 0 cron jobs with no channel, got ${B_N}"
fi

printf '== ARM C: no existing config file at all ==\n'
IN_IM_ENABLED=false IN_IM_ALLOWED="" IN_WA_ENABLED=false IN_WA_RECIPIENT=""
C_OUT="$(run_case "${TMP}/does-not-exist.toml")"
if [ "$(jobs_count "$C_OUT")" -eq 0 ]; then
    ok "C an absent config restores nothing and emits nothing (no crash, no invention)"
else
    bad "C an absent config produced cron jobs"
fi

printf '== ARM D: a FRESH walk must win -- restore is fill-only, never overwrite ==\n'
IN_IM_ENABLED=true IN_IM_ALLOWED="fresh@example.com" IN_WA_ENABLED=false IN_WA_RECIPIENT=""
D_OUT="$(run_case "$FIX_IM")"
if [ "$(delivery_to "$D_OUT")" = "fresh@example.com" ]; then
    ok "D a freshly-answered allowlist is NOT overwritten by the old config"
else
    bad "D restore clobbered a fresh answer: to='$(delivery_to "$D_OUT")'"
fi

printf '== ARM E: WhatsApp-only prior install ==\n'
IN_IM_ENABLED=false IN_IM_ALLOWED="" IN_WA_ENABLED=false IN_WA_RECIPIENT=""
E_OUT="$(run_case "$FIX_WA")"
if [ "$(delivery_ch "$E_OUT")" = "whatsapp" ] && [ "$(jobs_count "$E_OUT")" -eq 2 ]; then
    ok "E a WhatsApp-only reuse re-run keeps both briefs on whatsapp"
else
    bad "E whatsapp reuse: channel='$(delivery_ch "$E_OUT")' jobs=$(jobs_count "$E_OUT")"
fi

printf '== ARM F: ORDERING -- the restore must precede the truncating redirect ==\n'
F_CALL="$(grep -n '_ostler_restore_channels_from_existing_config "\$ASSISTANT_CONFIG"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
F_REDIR="$(grep -n '^} > "\$ASSISTANT_CONFIG"$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [ -z "$F_CALL" ] || [ -z "$F_REDIR" ]; then
    blind "F ordering anchors not found (call='${F_CALL}' redirect='${F_REDIR}')"
elif [ "$F_CALL" -lt "$F_REDIR" ]; then
    ok "F the restore runs before the redirect truncates the file it reads"
else
    bad "F the restore runs at/after the truncation (call=${F_CALL} redirect=${F_REDIR}) -- it reads an empty file"
fi

printf '\nreuse-run briefs: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'reuse-run briefs: FAILED\n'; exit 1; }
printf 'reuse-run briefs: clean (%s assertions, arm A is the original failing input)\n' "$pass"
exit 0
