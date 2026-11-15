#!/usr/bin/env bash
# tests/test_model_pull_uses_the_pinned_ollama.sh
#
# NEW-119. ORM diagnostic install on a clean macOS 27.2 Mac, 2026-10-29: step
# 12/44 (ai_models) ended DONE code=ERR-13-MODEL-PULL-NOMIC after 31s, and
# ollama.log held ZERO `POST /api/pull`. The pull wrapper ran a bare
# `ollama pull`, but since #2977 (bd9fe1a4) the engine is installed ONLY at
# ~/.ostler/runtime/ollama-<pin>/ollama and nothing puts it on PATH. On a Mac
# with no Ollama of its own that is rc 127, three times, then the abort. Walk
# boxes passed only because a system ollama happened to be on PATH.
#
# This runs the REAL _gui_ollama_pull / ollama_pull_with_retry and the REAL
# two `<engine> list | grep -q` presence checks lifted out of install.sh, with
# install.sh's OWN OLLAMA_PIN_* / OLLAMA_APP_BIN definitions, under
#
#     env -i PATH=/usr/bin:/bin HOME=<fresh tmp>
#
# so no `ollama` exists on PATH, and a fake engine sits at the pinned path
# recording its argv. Each call site must reach the fake.
#
# Arms:
#   A  pull, OSTLER_GUI=0       fake called with `pull nomic-embed-text`, rc 0
#   B  pull, OSTLER_GUI=1       fake called with `pull nomic-embed-text`, rc 0
#   C  list, nomic presence     fake called with `list`, condition true
#   D  list, chat presence      fake called with `list`, condition true
#   M  MUTANTS: each of the four sites put back to a bare `ollama`, one at a
#      time; every mutant must turn its arm RED. A mutant that did not apply
#      (no text changed) is CANNOT-RUN, not a pass.
#
# Precondition: `ollama` must NOT resolve on PATH=/usr/bin:/bin, or the test
# could pass by reaching the wrong binary. Checked, CANNOT-RUN if it does.
#
# INSTALL_SH=<path> runs it against another install.sh (e.g. origin/main's,
# which must go RED).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${INSTALL_SH:-}" ] && INSTALL_SH_OVERRIDDEN=1
INSTALL_SH="${INSTALL_SH:-$ROOT/install.sh}"
STRINGS="$ROOT/install.sh.strings.en-GB.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
pass(){ echo "ok    $*"; }
bad(){ echo "FAIL  $*"; fails=$((fails+1)); }

if env -i PATH=/usr/bin:/bin /bin/sh -c 'command -v ollama' >/dev/null 2>&1; then
    echo "CANNOT-RUN: an ollama resolves on PATH=/usr/bin:/bin; this test cannot tell the pinned engine from it"; exit 2
fi

# lift <install.sh> <outdir> -> writes fns.sh (pin defs + pull functions) and
# cond.txt (the two presence-check conditions, one per line). rc 2 on a failed lift.
lift() {
    local src="$1" out="$2"; mkdir -p "$out"
    {
        grep -E '^OLLAMA_PIN_VERSION=|^OLLAMA_PIN_DIR=|^OLLAMA_APP_BIN=' "$src"
        awk '/^_gui_ollama_pull\(\) \{/{f=1} f{print} f&&/^}$/{f=0}
             /^ollama_pull_with_retry\(\) \{/{g=1} g{print} g&&/^}$/{g=0}' "$src"
    } > "$out/fns.sh"
    grep -E '^[[:space:]]*if .*[[:space:]]list 2>/dev/null \| grep -q ' "$src" \
        | sed -E 's/^[[:space:]]*if (.*); then.*$/\1/' > "$out/cond.txt"
    [ "$(grep -c '^OLLAMA_APP_BIN=' "$out/fns.sh")" -eq 1 ] \
      && [ "$(grep -c '^_gui_ollama_pull() {' "$out/fns.sh")" -eq 1 ] \
      && [ "$(grep -c '^ollama_pull_with_retry() {' "$out/fns.sh")" -eq 1 ] \
      && [ "$(grep -c . "$out/cond.txt")" -eq 2 ] \
      && grep -q 'nomic-embed-text' "$out/cond.txt" && grep -q 'AI_MODEL' "$out/cond.txt"
}

# measure <outdir> -> prints four lines "A|B|C|D <argv-or-MISS> <rc-or-hit>"
measure() {
    local d="$1" arm
    for arm in A B C D; do
        local h="$d/home_$arm"; mkdir -p "$h"
        env -i PATH=/usr/bin:/bin HOME="$h" ARM="$arm" FNS="$d/fns.sh" COND="$d/cond.txt" \
            STRINGS="$STRINGS" REC="$d/argv_$arm" /bin/bash -c '
            set -Eeuo pipefail
            . "$STRINGS"
            gui_emit(){ :; }; gui_log(){ :; }; warn(){ :; }; info(){ :; }; sleep(){ :; }
            if [ "$(uname -s)" = Linux ]; then   # BSD `mktemp -t prefix` meaning on a GNU runner
                mktemp(){ if [ "${1:-}" = "-t" ]; then command mktemp "${TMPDIR:-/tmp}/${2:-tmp}.XXXXXX"; else command mktemp "$@"; fi; }
            fi
            . "$FNS"
            # The fake pinned engine, at the path install.sh itself computes.
            mkdir -p "$(dirname "$OLLAMA_APP_BIN")"
            printf "%s\n" "#!/bin/sh" "echo \"\$*\" >> \"$REC\"" \
                "case \"\$1\" in list) printf \"NAME ID SIZE MODIFIED\nnomic-embed-text:latest 0a1 274MB now\nqwen3.5:9b 648 6.6GB now\n\";; pull) printf \"pulling abc: 100%%\n\";; esac" \
                "exit 0" > "$OLLAMA_APP_BIN"
            chmod +x "$OLLAMA_APP_BIN"
            case "$OLLAMA_APP_BIN" in "$HOME"/.ostler/runtime/ollama-*/ollama) ;; *) echo "BADPIN $OLLAMA_APP_BIN"; exit 0;; esac
            AI_MODEL=qwen3.5:9b
            case "$ARM" in
              A) OSTLER_GUI=0; rc=0; ollama_pull_with_retry nomic-embed-text || rc=$?; echo "RC $rc" ;;
              B) OSTLER_GUI=1; rc=0; ollama_pull_with_retry nomic-embed-text || rc=$?; echo "RC $rc" ;;
              C) c="$(grep nomic-embed-text "$COND")"; if eval "$c"; then echo "RC hit"; else echo "RC miss"; fi ;;
              D) c="$(grep AI_MODEL "$COND")";        if eval "$c"; then echo "RC hit"; else echo "RC miss"; fi ;;
            esac' > "$d/out_$arm" 2>"$d/err_$arm"
        printf '%s %s|%s\n' "$arm" "$(head -1 "$d/argv_$arm" 2>/dev/null || echo MISS)" "$(sed -En 's/^(RC|BADPIN) //p' "$d/out_$arm" | head -1)"
    done
}

# expected <arm> -> the line a correct install.sh produces
expected() {
    case "$1" in
      A|B) echo "$1 pull nomic-embed-text|0" ;;
      C|D) echo "$1 list|hit" ;;
    esac
}

lift "$INSTALL_SH" "$W/real" || { echo "CANNOT-RUN: could not lift the pin definitions, pull wrapper and two list checks out of $INSTALL_SH"; exit 2; }
measure "$W/real" > "$W/real/result"
for arm in A B C D; do
    got="$(grep "^$arm " "$W/real/result")"
    want="$(expected "$arm")"
    label=""
    case "$arm" in A) label="pull (TTY path)";; B) label="pull (GUI path)";; C) label="nomic presence list";; D) label="chat-model presence list";; esac
    if [ "$got" = "$want" ]; then pass "$arm $label reaches the PINNED engine with no ollama on PATH: [$got]"
    else bad "$arm $label: got [$got] want [$want]  stderr: $(tr '\n' ' ' < "$W/real/err_$arm" | cut -c1-200)"; fi
done

# ── H: hub power (MacBook-as-Hub) unloads models through the pinned engine ───
# The REAL vendor/hub_power library, DRY_RUN=1 (commands are logged, not run),
# no ollama on PATH, and a LaunchAgent plist whose ProgramArguments[0] is the
# fake pinned engine. hpa_ollama_stop must list loaded models with the pinned
# binary and log a stop through it. Before NEW-119 it asked `command -v
# ollama`, got nothing, and skipped the unload.
HP="$ROOT/vendor/hub_power/bin"
if [ -z "${INSTALL_SH_OVERRIDDEN:-}" ] && [ -f "$HP/hub-power-actions.sh" ]; then
    h="$W/hub"; mkdir -p "$h/hm/.ostler/runtime/ollama-x" "$h/hm/Library/LaunchAgents"
    fake="$h/hm/.ostler/runtime/ollama-x/ollama"
    printf '%s\n' '#!/bin/sh' "echo \"\$*\" >> \"$h/argv\"" \
        'case "$1" in ps) printf "NAME ID\nqwen3.5:9b abc\n";; esac' 'exit 0' > "$fake"; chmod +x "$fake"
    printf '<plist><dict><key>ProgramArguments</key><array>\n<string>%s</string>\n<string>serve</string>\n</array></dict></plist>\n' "$fake" \
        > "$h/hm/Library/LaunchAgents/com.ostler.ollama.plist"
    : > "$h/hm/.ostler/hub-power.log"
    env -i PATH=/usr/bin:/bin HOME="$h/hm" DRY_RUN=1 HP="$HP" /bin/bash -c \
        '. "$HP/hub-power-actions.sh"; hpa_ollama_stop' > "$h/out" 2>&1
    if grep -q "stub: ollama stop qwen3.5:9b :: $fake stop qwen3.5:9b" "$h/hm/.ostler/hub-power.log" \
       && grep -qx 'ps' "$h/argv" 2>/dev/null; then
        pass "H hub power unloads models through the pinned engine read from the LaunchAgent, with no ollama on PATH"
    else
        bad "H hub power: argv=[$(tr '\n' ' ' < "$h/argv" 2>/dev/null)] log=[$(tr '\n' ' ' < "$h/hm/.ostler/hub-power.log" | cut -c1-300)] out=[$(tr '\n' ' ' < "$h/out" | cut -c1-200)]"
    fi
fi

# ── M: mutants. Each puts ONE site back to a bare `ollama`. ──────────────────
# Only meaningful on a tree that passes; on a RED tree they prove nothing.
if [ "$fails" -eq 0 ]; then
    n=0
    for spec in \
        'A|s/^\([[:space:]]*\)"\$OLLAMA_APP_BIN" pull "\$model"  #/\1ollama pull "$model"  #/' \
        'B|s/_pull_rc=0; "\$OLLAMA_APP_BIN" pull "\$model"/_pull_rc=0; ollama pull "$model"/' \
        'C|s/^if "\$OLLAMA_APP_BIN" list 2>\/dev\/null | grep -q "nomic-embed-text"/if ollama list 2>\/dev\/null | grep -q "nomic-embed-text"/' \
        'D|s/^\([[:space:]]*\)if "\$OLLAMA_APP_BIN" list 2>\/dev\/null | grep -q "\${AI_MODEL}"/\1if ollama list 2>\/dev\/null | grep -q "${AI_MODEL}"/'
    do
        arm="${spec%%|*}"; expr="${spec#*|}"; n=$((n+1)); m="$W/mut$n"; mkdir -p "$m"
        sed "$expr" "$INSTALL_SH" > "$m/install.sh"
        if cmp -s "$INSTALL_SH" "$m/install.sh"; then
            bad "M$n mutant for arm $arm did not apply (no text changed): CANNOT-RUN, the site moved"; continue
        fi
        lift "$m/install.sh" "$m" || { bad "M$n mutant for arm $arm: lift failed"; continue; }
        measure "$m" > "$m/result"
        got="$(grep "^$arm " "$m/result")"
        if [ "$got" != "$(expected "$arm")" ]; then pass "M$n bare \`ollama\` put back at arm $arm is CAUGHT: [$got]"
        else bad "M$n bare \`ollama\` at arm $arm was NOT caught: [$got]"; fi
    done
fi

if [ "$fails" -gt 0 ]; then echo "RED: $fails failure(s)"; exit 1; fi
echo "GREEN: 4 install.sh call sites + hub power reach the pinned engine, 4 mutants caught"
