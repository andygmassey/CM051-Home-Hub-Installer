#!/usr/bin/env bash
#
# test_v1010_ingest_reroute_plists.sh
#
# Table-driven assertion for the v1.0.10 ingest-reroute (Piece D). Every
# rerouted LaunchAgent plist MUST invoke the FDA-holding, signed daemon as
# EXACTLY:
#
#     ProgramArguments = [ <OstlerAssistant.app daemon>, "run-source", "<enum-value>" ]
#
# and nothing else. This guards the closed `run-source` enum (10 values,
# == src/main.rs Source + the INGEST_SOURCES loop in wrap-in-app-bundle.sh)
# against the failure shapes Archie flagged:
#
#   1. a typo / underscore slip in the enum value (e.g. `imessage_bridge`
#      instead of `imessage-bridge`) -- clap would hard-reject it and the
#      tick would silently no-op forever;
#   2. ProgramArguments[0] regressing to `zeroclaw` (the crate bin name --
#      BIN-NAME trip-wire, §3), or to `/bin/bash` / `/bin/sh` / python (an
#      interpreter resets TCC responsibility off the signed parent, so the
#      protected read is denied and ingest dies silently);
#   3. a missing `run-source` verb, extra trailing args, or a dropped
#      source (array length != 3).
#
# Sources covered:
#   - 6 vendored plist templates: ProgramArguments[0] is the render token
#     OSTLER_ASSISTANT_BINARY, which the installer's sed pass resolves to
#     the .app daemon path (proven below).
#   - 4 install.sh plist heredocs: ProgramArguments[0] is the literal
#     ${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant.
#
# Runnable standalone:  bash tests/test_v1010_ingest_reroute_plists.sh
# Exits non-zero on ANY mismatch.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
EMAIL_SNIPPET="$REPO_ROOT/vendor/email_ingest/INSTALL_SNIPPET.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing at $INSTALL_SH"
    echo "test_v1010_ingest_reroute_plists: FAILED" >&2
    exit 1
fi

# The signed daemon inside the .app bundle. ProgramArguments[0] must resolve
# to this (never zeroclaw, never an interpreter).
DAEMON_PATH_MARKER="OstlerAssistant.app/Contents/MacOS/ostler-assistant"
# Render token used by the vendored templates; the installer seds it to the
# path above (proven in the render-pass check below).
RENDER_TOKEN="OSTLER_ASSISTANT_BINARY"

# The closed run-source enum. Order-independent; keep in lock-step with
# src/main.rs Source + wrap-in-app-bundle.sh INGEST_SOURCES.
CANONICAL_ENUM=(imessage imessage-bridge email-ingest email-bundle whatsapp \
                fda-rerun contact-resync export-scan spoken aiconv)

# Table: "<enum-value>|<source-file relative to repo>|<plist Label>"
TABLE=(
    "imessage|vendor/imessage_source/launchd/com.creativemachines.ostler.imessage-bundle.plist|com.creativemachines.ostler.imessage-bundle"
    "imessage-bridge|vendor/imessage_bridge/launchd/com.ostler.imessage-bridge.plist|com.ostler.imessage-bridge"
    "email-ingest|vendor/email_ingest/launchd/com.creativemachines.ostler.email-ingest.plist|com.creativemachines.ostler.email-ingest"
    "email-bundle|vendor/email_source/launchd/com.creativemachines.ostler.email-bundle.plist|com.creativemachines.ostler.email-bundle"
    "whatsapp|vendor/whatsapp_source/launchd/com.creativemachines.ostler.whatsapp-bundle.plist|com.creativemachines.ostler.whatsapp-bundle"
    "fda-rerun|install.sh|com.ostler.fda-rerun"
    "contact-resync|install.sh|com.ostler.contact-resync"
    "export-scan|install.sh|com.ostler.export-scan"
    "spoken|vendor/spoken_source/launchd/com.creativemachines.ostler.spoken-bundle.plist|com.creativemachines.ostler.spoken-bundle"
    "aiconv|install.sh|com.ostler.aiconv-resume"
)

# extract_progargs <file> <plist-label>
# Prints the ProgramArguments <string> values (one per line) for the dict
# whose <key>Label</key> value == <plist-label>. Scopes correctly even when
# a file (install.sh) carries several plist heredocs.
extract_progargs() {
    awk -v want="$2" '
        /<key>Label<\/key>/ {
            if ((getline nxt) > 0 && index(nxt, "<string>" want "</string>")) inblk=1
            next
        }
        inblk && /<key>ProgramArguments<\/key>/ { inpa=1; next }
        inpa && /<array>/ { next }
        inpa && /<\/array>/ { exit }
        inpa {
            line=$0
            sub(/.*<string>/, "", line)
            sub(/<\/string>.*/, "", line)
            print line
        }
    ' "$1"
}

# render_bin <raw-element0> -> the resolved daemon path.
# Faithfully applies the installer's render: the token becomes the .app
# daemon path; a literal path passes through unchanged.
render_bin() {
    if [[ "$1" == "$RENDER_TOKEN" ]]; then
        printf '%s' '${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant'
    else
        printf '%s' "$1"
    fi
}

# ── Render-pass proof: the token really resolves to the .app daemon path ──
# (so accepting the token in a vendored template above is sound). Both
# active renderers must (a) sed the token and (b) target the .app daemon.
if ! grep -q "s/${RENDER_TOKEN}/" "$INSTALL_SH" || ! grep -q "$DAEMON_PATH_MARKER" "$INSTALL_SH"; then
    failure "install.sh renderer does not map ${RENDER_TOKEN} -> ${DAEMON_PATH_MARKER}"
fi
if [[ -f "$EMAIL_SNIPPET" ]]; then
    if ! grep -q "s/${RENDER_TOKEN}/" "$EMAIL_SNIPPET" || ! grep -q "$DAEMON_PATH_MARKER" "$EMAIL_SNIPPET"; then
        failure "email_ingest INSTALL_SNIPPET does not map ${RENDER_TOKEN} -> ${DAEMON_PATH_MARKER}"
    fi
fi

# ── Per-source table assertions ──
for row in "${TABLE[@]}"; do
    IFS='|' read -r enum relf label <<< "$row"
    f="$REPO_ROOT/$relf"
    if [[ ! -f "$f" ]]; then
        failure "[$enum] source file missing: $relf"
        continue
    fi

    args=()
    while IFS= read -r line; do args+=("$line"); done < <(extract_progargs "$f" "$label")

    n=${#args[@]}
    if [[ "$n" -ne 3 ]]; then
        failure "[$enum] ProgramArguments has $n element(s) (want exactly 3: <daemon> run-source $enum) in $relf -- got: ${args[*]:-<empty>}"
        continue
    fi

    a0="${args[0]}"; a1="${args[1]}"; a2="${args[2]}"
    r0="$(render_bin "$a0")"

    # Element 0: the signed .app daemon, never the crate bin nor an interpreter.
    if [[ "$r0" != *"$DAEMON_PATH_MARKER"* ]]; then
        failure "[$enum] ProgramArguments[0] resolves to '$r0' -- not the OstlerAssistant.app daemon ($DAEMON_PATH_MARKER)"
    fi
    case "$r0" in
        *zeroclaw*)
            failure "[$enum] ProgramArguments[0] '$r0' references crate bin 'zeroclaw' (BIN-NAME trip-wire, §3)" ;;
    esac
    case "$r0" in
        */bin/bash|*/bin/sh|*/bin/zsh|*python*)
            failure "[$enum] ProgramArguments[0] '$r0' is an interpreter, not the signed daemon (breaks TCC responsibility)" ;;
    esac

    # Element 1: the literal run-source verb.
    [[ "$a1" == "run-source" ]] || failure "[$enum] ProgramArguments[1] is '$a1', want 'run-source'"

    # Element 2: the EXACT canonical enum value (catches underscore slips etc).
    [[ "$a2" == "$enum" ]] || failure "[$enum] ProgramArguments[2] is '$a2', want '$enum'"
done

# ── Coverage: the table must span exactly the closed enum set ──
missing=""
for e in "${CANONICAL_ENUM[@]}"; do
    found=0
    for row in "${TABLE[@]}"; do [[ "${row%%|*}" == "$e" ]] && found=1; done
    [[ "$found" -eq 1 ]] || missing="$missing $e"
done
[[ -z "$missing" ]] || failure "table does not cover canonical enum value(s):$missing"
[[ "${#TABLE[@]}" -eq "${#CANONICAL_ENUM[@]}" ]] || \
    failure "table has ${#TABLE[@]} rows, canonical enum has ${#CANONICAL_ENUM[@]}"

# ── Belt: every run-source plist ANYWHERE in the tracked sources must carry
# a canonical enum value as arg2 -- catches a rogue/typo'd source added
# outside the table. arg2 is the <string> on the line following run-source.
all_arg2=()
collect_files=("$INSTALL_SH")
while IFS= read -r vf; do collect_files+=("$vf"); done < <(
    grep -rl '<string>run-source</string>' "$REPO_ROOT/vendor" 2>/dev/null
)
for cf in "${collect_files[@]}"; do
    while IFS= read -r v; do
        [[ -n "$v" ]] && all_arg2+=("$v")
    done < <(
        awk 'prev{sub(/.*<string>/,"");sub(/<\/string>.*/,"");print;prev=0}
             /<string>run-source<\/string>/{prev=1}' "$cf"
    )
done
for v in "${all_arg2[@]}"; do
    okv=0
    for e in "${CANONICAL_ENUM[@]}"; do [[ "$v" == "$e" ]] && okv=1; done
    [[ "$okv" -eq 1 ]] || failure "a run-source plist uses non-canonical enum value '$v' (typo / rogue source outside the closed set)"
done
if [[ "${#all_arg2[@]}" -ne "${#CANONICAL_ENUM[@]}" ]]; then
    failure "found ${#all_arg2[@]} run-source plist(s) across tracked sources; expected ${#CANONICAL_ENUM[@]} (one per canonical enum value) -- values: ${all_arg2[*]:-<none>}"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_v1010_ingest_reroute_plists: FAILED" >&2
    exit 1
fi
echo "test_v1010_ingest_reroute_plists: PASSED (${#CANONICAL_ENUM[@]} run-source plists verified)"
exit 0
