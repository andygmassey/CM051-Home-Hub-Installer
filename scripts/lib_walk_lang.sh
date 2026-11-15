#!/usr/bin/env bash
# scripts/lib_walk_lang.sh -- ttywalk.sh --lang <code>: a non-English walk leg.
#
# WHY. walk_drive.py answers install.sh's prompts by ENGLISH substring. Under
# OSTLER_LANG=ja the prompts are Japanese and nothing matches, so the install
# stalls at the first question. The GUI sets OSTLER_LANG in install.sh's
# environment (InstallerCoordinator.swift:1666), so an ssh walk that sets the
# same variable walks the SHIPPED path. The answers come from the driver's own
# override file (~/.walk-answers.tsv, read before the built-in table), generated
# on the box by box_walk_probes/lib/gen_walk_answers_lang.py from the staged
# install.sh.strings.<lang>.sh. Pairs that cannot be mapped (the consent and
# autologin prompts are English in every language by design) keep matching the
# built-in English table.
#
# Unset --lang leaves every byte of today's walk unchanged.
#
# Functions read the caller's SSH array and take everything else as arguments.

# The installer's locale list: one install.sh.strings.<code>.sh per entry once
# l10n lands (CM051 #3156). tests/test_ttywalk_lang_leg.sh fails if a strings
# file exists in the repo without an entry here.
WALK_LANGS="ar de en-GB en-US es fr it ja ko nl pt-BR pt-PT zh-HK zh-Hans zh-Hant"

walk_lang_valid() {
    local c l
    c="${1:-}"
    [[ -n "$c" ]] || return 1
    for l in $WALK_LANGS; do [[ "$l" == "$c" ]] && return 0; done
    return 1
}

# There is deliberately NO launcher here. scripts/ttywalk.sh holds the ONE
# walk_drive.py launch line (the walk-record-gate refuses a second launcher) and
# adds OSTLER_LANG to it when --lang is set.

# Stage the generated answers on the box. Returns 0 staged, 2 CANNOT-RUN
# (message on stderr). Sets nothing the caller must read; the caller arms
# walk_lang_cleanup BEFORE calling this.
#   walk_lang_stage <remote_dir> <lang> <generator.py>
walk_lang_stage() {
    local rd="$1" lang="$2" gen="$3" out rc
    # install.sh falls back to en-GB when the strings file is missing: a
    # "ja walk" of a tree without it would be an English walk wearing a label.
    "${SSH[@]}" "test -s '${rd}/install.sh.strings.${lang}.sh' && test -s '${rd}/install.sh.strings.en-GB.sh' && test -s '${rd}/scripts/walk_drive.py'" \
        || { echo "CANNOT-RUN: --lang ${lang}: the staged tree has no install.sh.strings.${lang}.sh (or en-GB, or walk_drive.py). install.sh would fall back to en-GB silently." >&2; return 2; }
    LANG_STAGED=1   # from here on the host holds our files; the exit trap cleans them
    "${SSH[@]}" "cat > '${rd}/scripts/gen_walk_answers_lang.py'" < "$gen" \
        || { echo "CANNOT-RUN: --lang ${lang}: could not ship the answers generator to the host." >&2; return 2; }
    # A hand-made override file of the operator's is set aside, not destroyed.
    # The sentinel is written in the same step, so cleanup only ever touches
    # ~/.walk-answers.tsv when this function got as far as replacing it.
    out="$("${SSH[@]}" "cd '${rd}' && { [ ! -f ~/.walk-answers.tsv ] || mv -f ~/.walk-answers.tsv ~/.walk-answers.tsv.pre-lang; } && : > ~/.walk-answers.tsv.lang-staged && \
        python3 -I scripts/gen_walk_answers_lang.py scripts/walk_drive.py install.sh.strings.en-GB.sh install.sh.strings.${lang}.sh \"\$HOME/.walk-answers.tsv\" && \
        test -s \"\$HOME/.walk-answers.tsv\"" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/   /'
    if [[ $rc -ne 0 ]]; then
        echo "CANNOT-RUN: --lang ${lang}: the answers file was not generated (rc ${rc}). An empty override would stall the install at its first prompt." >&2
        return 2
    fi
    return 0
}

# Idempotent; safe when nothing was staged. Restores a set-aside operator file.
#   walk_lang_cleanup <remote_dir>
walk_lang_cleanup() {
    local rd="$1"
    "${SSH[@]}" "rm -f '${rd}/scripts/gen_walk_answers_lang.py'; \
        if [ -f ~/.walk-answers.tsv.lang-staged ]; then \
            if [ -f ~/.walk-answers.tsv.pre-lang ]; then mv -f ~/.walk-answers.tsv.pre-lang ~/.walk-answers.tsv; \
            else rm -f ~/.walk-answers.tsv; fi; \
            rm -f ~/.walk-answers.tsv.lang-staged; \
        fi; \
        test ! -e '${rd}/scripts/gen_walk_answers_lang.py' && test ! -e ~/.walk-answers.tsv.lang-staged" >/dev/null 2>&1 \
        || echo "WARNING: could not remove the staged language-leg files on the host (~/.walk-answers.tsv); remove them by hand." >&2
}
