#!/usr/bin/env bash
#
# tests/test_install_daily_briefs.sh
#
# Locks the daily-briefs OoTB install plumbing in install.sh.
#
# Why this test exists:
#
#   The verify report at /tmp/DAILY_BRIEFS_OOTB_VERIFY_2026-05-09.md
#   flagged four launch-blocking gaps in the customer-shipping
#   installer that prevented the morning brief (09:00) and evening
#   wrap (18:00) from working OoTB:
#
#     1. install.sh emitted no [[cron.jobs]] blocks (no schedule
#        for the brief). [Item 1]
#     2. install.sh installed no WhatsApp keepalive LaunchAgent
#        (socket idled out before 09:00 fires). [Item 2]
#     3. install.sh never captured the customer's phone number
#        (no recipient for the brief). [Item 4]
#     4. [channels.whatsapp].allowed_numbers was empty
#        (deny-all default). [Item 6]
#
#   This test pins the wiring so a regression in any of the four
#   surfaces immediately, and so the test plan in PR #1 has a
#   concrete green/red signal.
#
# Sister tests:
#   - test_whatsapp_channel_block.sh  -- locks the consent + base
#                                        [channels.whatsapp] block
#   - test_consent_a7_a8.sh           -- locks the A7 WhatsApp
#                                        consent ceremony

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
KEEPALIVE_PLIST="${REPO_ROOT}/assistant-agent/launchd/com.creativemachines.ostler.whatsapp-keepalive.plist"
ASSISTANT_SNIPPET="${REPO_ROOT}/assistant-agent/INSTALL_SNIPPET.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ────────────────────────────────────────────────────────────────
# Item 4 — phone-number capture
# ────────────────────────────────────────────────────────────────

# CHANNEL_WHATSAPP_RECIPIENT variable is initialised.
if ! grep -q '^CHANNEL_WHATSAPP_RECIPIENT=""' "$INSTALL_SCRIPT"; then
    echo "FAIL [recipient-init]: install.sh does not initialise CHANNEL_WHATSAPP_RECIPIENT=\"\"" >&2
    exit 1
fi
echo "PASS: install.sh initialises CHANNEL_WHATSAPP_RECIPIENT"

# Wizard prompts for the phone number when WhatsApp is enabled.
# The prompt is gated on CHANNEL_WHATSAPP_ENABLED == true so a
# customer who didn't pick the WhatsApp channel doesn't get an
# orphaned phone-number question.
if ! awk '
    /if \[\[ "\$CHANNEL_WHATSAPP_ENABLED" == true \]\]; then/ { in_block = 1; depth = 1; next }
    in_block && /^if /                                       { depth++ }
    in_block && /^fi$/                                       { depth--; if (depth == 0) in_block = 0 }
    in_block && /Your WhatsApp phone number/                 { found = 1 }
    END                                                      { exit !found }
' "$INSTALL_SCRIPT"; then
    echo "FAIL [recipient-prompt]: install.sh does not prompt 'Your WhatsApp phone number' inside a CHANNEL_WHATSAPP_ENABLED guard" >&2
    exit 1
fi
echo "PASS: install.sh prompts for WhatsApp phone number when channel enabled"

# Validation: must start with +. Without this guard a typo
# (44... instead of +44...) silently flows through to TOML.
if ! grep -q '"${CHANNEL_WHATSAPP_RECIPIENT:0:1}" != "+"' "$INSTALL_SCRIPT"; then
    echo "FAIL [recipient-validation]: install.sh does not enforce leading + on the phone number" >&2
    exit 1
fi
echo "PASS: install.sh enforces leading + on WhatsApp recipient"

# ────────────────────────────────────────────────────────────────
# Items 1 + 6 — TOML emitter (cron jobs + allowed_numbers seed)
# ────────────────────────────────────────────────────────────────

# Static-pattern checks: the TOML emitter writes [[cron.jobs]]
# blocks and the morning + evening cron expressions.
if ! grep -q '\[\[cron\.jobs\]\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [cron-header]: install.sh does not emit [[cron.jobs]] header" >&2
    exit 1
fi
echo "PASS: install.sh emits [[cron.jobs]] header"

if ! grep -q '0 9 \* \* \*' "$INSTALL_SCRIPT"; then
    echo "FAIL [morning-brief-expr]: install.sh does not emit '0 9 * * *' (morning brief)" >&2
    exit 1
fi
echo "PASS: install.sh emits morning brief cron expression (0 9 * * *)"

if ! grep -q '0 18 \* \* \*' "$INSTALL_SCRIPT"; then
    echo "FAIL [evening-wrap-expr]: install.sh does not emit '0 18 * * *' (evening wrap)" >&2
    exit 1
fi
echo "PASS: install.sh emits evening wrap cron expression (0 18 * * *)"

if ! grep -q 'id = \\"morning-brief\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [morning-brief-id]: install.sh does not emit id = \"morning-brief\"" >&2
    echo "       CronJobDecl::id is required by the daemon's serde derive." >&2
    exit 1
fi
echo "PASS: install.sh ids morning-brief job"

if ! grep -q 'id = \\"evening-wrap\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [evening-wrap-id]: install.sh does not emit id = \"evening-wrap\"" >&2
    echo "       CronJobDecl::id is required by the daemon's serde derive." >&2
    exit 1
fi
echo "PASS: install.sh ids evening-wrap job"

# Schedule discriminator must be `kind`, not `type`. The daemon's
# CronScheduleDecl carries #[serde(tag = "kind", rename_all = "lowercase")]
# so `type = "cron"` lands on the unknown-variant error path and the
# whole cron section silently fails to load.
if ! grep -q 'kind = \\"cron\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [schedule-kind]: install.sh does not emit kind = \"cron\" on cron jobs" >&2
    echo "       (the schema uses serde tag = \"kind\", not \"type\")" >&2
    exit 1
fi
if grep -q 'schedule = { type = \\"cron\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [schedule-type-drift]: install.sh still emits the legacy type = \"cron\" form" >&2
    exit 1
fi
echo "PASS: install.sh uses kind = \"cron\" (matches schema tag)"

# Brief jobs are agent-prompt driven, not shell-command. The runtime
# has no `brief generate` shell subcommand on the published binary.
if ! grep -q 'job_type = \\"agent\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [job-type]: install.sh does not emit job_type = \"agent\" on cron jobs" >&2
    exit 1
fi
echo "PASS: install.sh sets job_type = \"agent\" on brief jobs"

# [providers] block. Agent jobs need a fallback provider, otherwise
# the agent runtime errors with "no provider configured" at fire
# time. Emitted unconditionally because Ollama is installed
# unconditionally during install (Phase 1.5b).
if ! grep -qE '"\[providers\]"' "$INSTALL_SCRIPT"; then
    echo "FAIL [providers-header]: install.sh does not emit a [providers] section in the assistant-config block" >&2
    exit 1
fi
echo "PASS: install.sh emits [providers] section"

if ! grep -q 'fallback = \\"ollama\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [providers-fallback]: install.sh does not set providers.fallback = \"ollama\"" >&2
    exit 1
fi
echo "PASS: install.sh sets providers.fallback = \"ollama\""

if ! grep -qE '"\[providers\.models\.ollama\]"' "$INSTALL_SCRIPT"; then
    echo "FAIL [providers-ollama-entry]: install.sh does not emit [providers.models.ollama]" >&2
    exit 1
fi
echo "PASS: install.sh emits [providers.models.ollama] entry"

# best_effort = false (NOT true). The whole point of switching is
# fail-loud delivery so regressions surface.
if grep -E 'cron\.jobs.*best_effort = true|best_effort = true.*morning|best_effort = true.*evening' "$INSTALL_SCRIPT" >/dev/null; then
    echo "FAIL [best-effort-true]: install.sh emits best_effort = true on a cron job (should be false)" >&2
    exit 1
fi
# Stronger check: the best_effort field is emitted as false.
if ! grep -q 'best_effort = false' "$INSTALL_SCRIPT"; then
    echo "FAIL [best-effort-missing]: install.sh does not emit 'best_effort = false' on cron jobs" >&2
    exit 1
fi
echo "PASS: install.sh emits best_effort = false (fail-loud on cron delivery)"

# Timezone is threaded through. Without this, the cron defaults
# to UTC and the brief lands at random local times.
if ! grep -q 'tz = \\"\${_user_tz_esc}\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [tz-thread]: install.sh does not thread USER_TZ into cron jobs" >&2
    exit 1
fi
echo "PASS: install.sh threads USER_TZ into cron job tz field"

# allowed_numbers seed. The static check is keyed on the
# CHANNEL_WHATSAPP_RECIPIENT variable being interpolated into the
# allowed_numbers array.
if ! grep -q 'allowed_numbers = \[\\"\${_wa_recipient_esc}\\"\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [allowed-numbers-seed]: install.sh does not seed allowed_numbers from CHANNEL_WHATSAPP_RECIPIENT" >&2
    exit 1
fi
echo "PASS: install.sh seeds [channels.whatsapp].allowed_numbers from CHANNEL_WHATSAPP_RECIPIENT"

# ────────────────────────────────────────────────────────────────
# Item 2 — WhatsApp keepalive LaunchAgent
# ────────────────────────────────────────────────────────────────

if [[ ! -f "$KEEPALIVE_PLIST" ]]; then
    echo "FAIL [keepalive-plist-missing]: $KEEPALIVE_PLIST does not exist" >&2
    exit 1
fi
echo "PASS: WhatsApp keepalive plist file exists"

# The plist is a valid plist (plutil parses it).
if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$KEEPALIVE_PLIST" >/dev/null 2>&1; then
        echo "FAIL [keepalive-plist-invalid]: plutil -lint failed on keepalive plist" >&2
        plutil -lint "$KEEPALIVE_PLIST" >&2 || true
        exit 1
    fi
    echo "PASS: keepalive plist passes plutil -lint"
else
    echo "INFO: plutil not available; skipping plist lint (CI environment)"
fi

# Label is the canonical creativemachines.ostler one.
if ! grep -q 'com.creativemachines.ostler.whatsapp-keepalive' "$KEEPALIVE_PLIST"; then
    echo "FAIL [keepalive-label]: keepalive plist does not contain canonical label" >&2
    exit 1
fi
echo "PASS: keepalive plist uses com.creativemachines.ostler.whatsapp-keepalive label"

# ProgramArguments invokes `channel doctor`. Anything else (e.g.
# a synthetic "ping" subcommand that doesn't exist on the binary)
# would silently fail every fire.
if ! grep -q '<string>channel</string>' "$KEEPALIVE_PLIST"; then
    echo "FAIL [keepalive-program]: keepalive plist does not invoke channel subcommand" >&2
    exit 1
fi
if ! grep -q '<string>doctor</string>' "$KEEPALIVE_PLIST"; then
    echo "FAIL [keepalive-program]: keepalive plist does not invoke channel doctor" >&2
    exit 1
fi
echo "PASS: keepalive plist invokes 'channel doctor'"

# StartCalendarInterval has both 08:50 + 17:50 entries.
if ! awk '
    /<key>StartCalendarInterval<\/key>/ { in_block = 1; next }
    in_block && /<\/array>/             { in_block = 0 }
    in_block && /<integer>8<\/integer>/ { saw_h_8 = 1 }
    in_block && /<integer>17<\/integer>/{ saw_h_17 = 1 }
    in_block && /<integer>50<\/integer>/{ saw_m_50 = 1 }
    END                                 { exit !(saw_h_8 && saw_h_17 && saw_m_50) }
' "$KEEPALIVE_PLIST"; then
    echo "FAIL [keepalive-schedule]: keepalive plist missing 08:50 + 17:50 entries" >&2
    exit 1
fi
echo "PASS: keepalive plist scheduled at 08:50 + 17:50"

# RunAtLoad must be false so we don't spam reconnects on login.
if ! awk '
    /<key>RunAtLoad<\/key>/ { found = NR; next }
    found && NR == found+1 && /<false\/>/ { ok = 1 }
    END { exit !ok }
' "$KEEPALIVE_PLIST"; then
    echo "FAIL [keepalive-runatload]: keepalive plist RunAtLoad is not false" >&2
    exit 1
fi
echo "PASS: keepalive plist RunAtLoad = false"

# INSTALL_SNIPPET wires up the keepalive when INSTALL_WHATSAPP_KEEPALIVE=true.
if ! grep -q 'INSTALL_WHATSAPP_KEEPALIVE' "$ASSISTANT_SNIPPET"; then
    echo "FAIL [snippet-no-keepalive]: assistant-agent INSTALL_SNIPPET.sh does not honour INSTALL_WHATSAPP_KEEPALIVE" >&2
    exit 1
fi
echo "PASS: assistant-agent INSTALL_SNIPPET honours INSTALL_WHATSAPP_KEEPALIVE"

# install.sh sets INSTALL_WHATSAPP_KEEPALIVE based on CHANNEL_WHATSAPP_ENABLED.
if ! grep -q 'INSTALL_WHATSAPP_KEEPALIVE="$ASSISTANT_INSTALL_KEEPALIVE"' "$INSTALL_SCRIPT"; then
    echo "FAIL [installer-no-keepalive-wire]: install.sh does not pass INSTALL_WHATSAPP_KEEPALIVE through to the snippet" >&2
    exit 1
fi
echo "PASS: install.sh wires INSTALL_WHATSAPP_KEEPALIVE through to the snippet"

# Uninstall path also booted-out the keepalive, matching the
# pattern for the other LaunchAgents.
if ! grep -q 'launchctl bootout.*whatsapp-keepalive' "$INSTALL_SCRIPT"; then
    echo "FAIL [uninstall-no-bootout]: install.sh uninstall path does not bootout the keepalive" >&2
    exit 1
fi
if ! grep -q 'rm -f.*whatsapp-keepalive\.plist' "$INSTALL_SCRIPT"; then
    echo "FAIL [uninstall-no-rm]: install.sh uninstall path does not rm the keepalive plist" >&2
    exit 1
fi
echo "PASS: install.sh uninstall path removes the keepalive LaunchAgent"

# ────────────────────────────────────────────────────────────────
# End-to-end: TOML emitter produces the expected blocks
# ────────────────────────────────────────────────────────────────

EMITTER="$(mktemp)"
trap 'rm -f "$EMITTER"' EXIT

awk '
    /^TOMLPREAMBLE$/                         { capture = 1; next }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "$INSTALL_SCRIPT" > "$EMITTER"

if [[ ! -s "$EMITTER" ]]; then
    echo "FAIL [emitter-empty]: could not extract TOML emitter body" >&2
    exit 1
fi

# Run with WhatsApp enabled + a synthetic recipient + a TZ. Assert
# the output has the cron blocks, the recipient threaded into both
# allowed_numbers and delivery.to, and best_effort = false.
TEST_PHONE="+447700900111"
TEST_TZ="Europe/London"

OUTPUT="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_RECIPIENT="$TEST_PHONE" \
    USER_TZ="$TEST_TZ" \
    CHAT_ADMIN_TOKEN="dummy-token" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

# allowed_numbers contains the captured phone.
if ! echo "$OUTPUT" | grep -q "allowed_numbers = \[\"$TEST_PHONE\"\]"; then
    echo "FAIL [emitter-allowed-numbers]: emitter did not seed allowed_numbers with the captured recipient" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter writes allowed_numbers = [\"$TEST_PHONE\"]"

# Cron jobs land with the captured TZ + recipient.
if ! echo "$OUTPUT" | grep -q 'id = "morning-brief"'; then
    echo "FAIL [emitter-morning-id]: emitter did not write id = \"morning-brief\"" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter writes morning-brief job id"

if ! echo "$OUTPUT" | grep -q 'id = "evening-wrap"'; then
    echo "FAIL [emitter-evening-id]: emitter did not write id = \"evening-wrap\"" >&2
    exit 1
fi
echo "PASS: emitter writes evening-wrap job id"

# Schema discriminator must be kind (not type) on the schedule
# variant, otherwise the daemon's serde rejects the job at load.
if ! echo "$OUTPUT" | grep -q 'kind = "cron"'; then
    echo "FAIL [emitter-schedule-kind]: emitter did not write kind = \"cron\"" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
if echo "$OUTPUT" | grep -q 'schedule = { type = "cron"'; then
    echo "FAIL [emitter-schedule-type-drift]: emitter wrote legacy type = \"cron\"" >&2
    exit 1
fi
echo "PASS: emitter writes kind = \"cron\" (matches schema tag)"

if ! echo "$OUTPUT" | grep -q 'job_type = "agent"'; then
    echo "FAIL [emitter-job-type]: emitter did not write job_type = \"agent\"" >&2
    exit 1
fi
echo "PASS: emitter writes job_type = \"agent\" on brief jobs"

if ! echo "$OUTPUT" | grep -qE '^prompt = "[^"]+"'; then
    echo "FAIL [emitter-prompt]: emitter did not write a non-empty prompt field" >&2
    exit 1
fi
echo "PASS: emitter writes a non-empty prompt on brief jobs"

if ! echo "$OUTPUT" | grep -q "tz = \"$TEST_TZ\""; then
    echo "FAIL [emitter-tz]: emitter did not thread USER_TZ ($TEST_TZ) into cron jobs" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter threads USER_TZ ($TEST_TZ) into cron jobs"

if ! echo "$OUTPUT" | grep -q "to = \"$TEST_PHONE\""; then
    echo "FAIL [emitter-delivery-to]: emitter did not thread recipient into delivery.to" >&2
    exit 1
fi
echo "PASS: emitter threads recipient into delivery.to"

if ! echo "$OUTPUT" | grep -q 'best_effort = false'; then
    echo "FAIL [emitter-best-effort]: emitter did not write best_effort = false" >&2
    exit 1
fi
echo "PASS: emitter writes best_effort = false on cron jobs"

# [providers] block lands in the rendered TOML with the canonical
# Ollama fallback. Without this, agent-type cron jobs fail at fire
# time with "no provider configured".
if ! echo "$OUTPUT" | grep -q '^\[providers\]$'; then
    echo "FAIL [emitter-providers-header]: emitter did not write [providers] section" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
if ! echo "$OUTPUT" | grep -q '^fallback = "ollama"$'; then
    echo "FAIL [emitter-providers-fallback]: emitter did not write fallback = \"ollama\"" >&2
    exit 1
fi
if ! echo "$OUTPUT" | grep -q '^\[providers\.models\.ollama\]$'; then
    echo "FAIL [emitter-providers-ollama]: emitter did not write [providers.models.ollama] entry" >&2
    exit 1
fi
if ! echo "$OUTPUT" | grep -q '^base_url = "http://localhost:11434"$'; then
    echo "FAIL [emitter-providers-base-url]: emitter did not write Ollama base_url" >&2
    exit 1
fi
if ! echo "$OUTPUT" | grep -qE '^model = "[^"]+"$'; then
    echo "FAIL [emitter-providers-model]: emitter did not write a non-empty Ollama model" >&2
    exit 1
fi
echo "PASS: emitter writes Ollama provider fallback block"

# Negative case 1: WhatsApp disabled => no cron jobs at all.
OUTPUT_OFF="$(
    CHANNEL_IMESSAGE_ENABLED=true \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_WHATSAPP_RECIPIENT="" \
    USER_TZ="$TEST_TZ" \
    CHAT_ADMIN_TOKEN="dummy-token" \
    CHANNEL_IMESSAGE_ALLOWED="user@example.com" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if echo "$OUTPUT_OFF" | grep -q '\[\[cron\.jobs\]\]'; then
    echo "FAIL [emitter-suppress-cron]: emitter wrote cron jobs when CHANNEL_WHATSAPP_ENABLED=false" >&2
    echo "Output was:" >&2
    echo "$OUTPUT_OFF" >&2
    exit 1
fi
echo "PASS: emitter suppresses cron jobs when WhatsApp disabled"

# Negative case 2: WhatsApp enabled but no recipient => suppress
# both allowed_numbers AND cron jobs (defensive: the wizard guard
# enforces a recipient, but the emitter shouldn't trust that).
OUTPUT_NO_PHONE="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=false \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_RECIPIENT="" \
    USER_TZ="$TEST_TZ" \
    CHAT_ADMIN_TOKEN="dummy-token" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if echo "$OUTPUT_NO_PHONE" | grep -q 'allowed_numbers'; then
    echo "FAIL [emitter-suppress-allowed]: emitter wrote allowed_numbers with no recipient" >&2
    exit 1
fi
echo "PASS: emitter suppresses allowed_numbers when no recipient captured"

if echo "$OUTPUT_NO_PHONE" | grep -q '\[\[cron\.jobs\]\]'; then
    echo "FAIL [emitter-suppress-cron-no-recipient]: emitter wrote cron jobs with no recipient" >&2
    exit 1
fi
echo "PASS: emitter suppresses cron jobs when no recipient captured"

# ────────────────────────────────────────────────────────────────
# Structural deserialise check -- catches schema-shape drift that
# string-grep cannot. Pipes the WhatsApp-enabled emitter output
# through Python's tomllib (3.11+) and asserts the daemon-required
# field set on each [[cron.jobs]] entry. Without this, an emit
# change that silently breaks the CronJobDecl shape (missing id,
# wrong discriminator tag, missing job_type, no command/prompt)
# can still pass every string assertion above.
# ────────────────────────────────────────────────────────────────

if python3 -c 'import tomllib' >/dev/null 2>&1; then
    TOML_CHECK_OUT="$(
        TOML_BODY="$OUTPUT" python3 - <<'PYEOF'
import os, sys, tomllib

try:
    data = tomllib.loads(os.environ["TOML_BODY"])
except tomllib.TOMLDecodeError as exc:
    print(f"FAIL [toml-parse]: emitter output is not valid TOML: {exc}", file=sys.stderr)
    sys.exit(1)

providers = data.get("providers", {})
fallback = providers.get("fallback")
if fallback != "ollama":
    print(f"FAIL [toml-providers-fallback]: expected providers.fallback = 'ollama', got {fallback!r}", file=sys.stderr)
    sys.exit(1)
models = providers.get("models", {})
ollama_entry = models.get("ollama")
if not isinstance(ollama_entry, dict):
    print("FAIL [toml-providers-ollama-entry]: providers.models.ollama missing or not a table", file=sys.stderr)
    sys.exit(1)
if ollama_entry.get("base_url") != "http://localhost:11434":
    print(f"FAIL [toml-providers-ollama-base-url]: expected base_url = 'http://localhost:11434', got {ollama_entry.get('base_url')!r}", file=sys.stderr)
    sys.exit(1)
model_value = ollama_entry.get("model")
if not isinstance(model_value, str) or not model_value.strip():
    print("FAIL [toml-providers-ollama-model]: providers.models.ollama.model missing or empty", file=sys.stderr)
    sys.exit(1)

cron = data.get("cron", {})
jobs = cron.get("jobs", [])
if len(jobs) != 2:
    print(f"FAIL [toml-job-count]: expected 2 cron jobs, got {len(jobs)}", file=sys.stderr)
    sys.exit(1)

ids = [j.get("id") for j in jobs]
if sorted(ids) != ["evening-wrap", "morning-brief"]:
    print(f"FAIL [toml-job-ids]: expected ids morning-brief + evening-wrap, got {ids}", file=sys.stderr)
    sys.exit(1)

for job in jobs:
    job_id = job.get("id") or "<missing>"
    if "id" not in job:
        print(f"FAIL [toml-missing-id]: a cron job is missing the required id field", file=sys.stderr)
        sys.exit(1)
    if job.get("job_type") != "agent":
        print(f"FAIL [toml-job-type] {job_id}: expected job_type = 'agent', got {job.get('job_type')!r}", file=sys.stderr)
        sys.exit(1)
    prompt = job.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        print(f"FAIL [toml-prompt] {job_id}: prompt field missing or empty", file=sys.stderr)
        sys.exit(1)
    schedule = job.get("schedule")
    if not isinstance(schedule, dict):
        print(f"FAIL [toml-schedule] {job_id}: schedule is not an inline table", file=sys.stderr)
        sys.exit(1)
    if schedule.get("kind") != "cron":
        print(f"FAIL [toml-schedule-kind] {job_id}: expected schedule.kind = 'cron', got {schedule.get('kind')!r}", file=sys.stderr)
        sys.exit(1)
    if "type" in schedule:
        print(f"FAIL [toml-schedule-type-drift] {job_id}: schedule still carries legacy 'type' key", file=sys.stderr)
        sys.exit(1)
    if not schedule.get("expr"):
        print(f"FAIL [toml-schedule-expr] {job_id}: schedule.expr missing", file=sys.stderr)
        sys.exit(1)
    if not schedule.get("tz"):
        print(f"FAIL [toml-schedule-tz] {job_id}: schedule.tz missing", file=sys.stderr)
        sys.exit(1)
    delivery = job.get("delivery")
    if not isinstance(delivery, dict):
        print(f"FAIL [toml-delivery] {job_id}: delivery is not an inline table", file=sys.stderr)
        sys.exit(1)
    if delivery.get("mode") != "announce":
        print(f"FAIL [toml-delivery-mode] {job_id}: expected delivery.mode = 'announce'", file=sys.stderr)
        sys.exit(1)
    if delivery.get("channel") != "whatsapp":
        print(f"FAIL [toml-delivery-channel] {job_id}: expected delivery.channel = 'whatsapp'", file=sys.stderr)
        sys.exit(1)
    if not delivery.get("to"):
        print(f"FAIL [toml-delivery-to] {job_id}: delivery.to missing", file=sys.stderr)
        sys.exit(1)
    if delivery.get("best_effort") is not False:
        print(f"FAIL [toml-delivery-best-effort] {job_id}: expected delivery.best_effort = false", file=sys.stderr)
        sys.exit(1)

print("PASS: tomllib structural deserialise + per-job field discipline")
PYEOF
    )"
    TOML_CHECK_RC=$?
    if [[ $TOML_CHECK_RC -ne 0 ]]; then
        echo "$TOML_CHECK_OUT" >&2
        exit 1
    fi
    echo "$TOML_CHECK_OUT"
else
    echo "INFO: python3 tomllib unavailable (needs Python 3.11+); skipping structural deserialise check"
fi

echo ""
echo "ALL DAILY-BRIEFS OoTB TESTS PASSED"
