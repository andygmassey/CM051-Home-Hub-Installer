#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_the_generated_uninstaller_parses.sh
#
# The uninstaller the customer runs is ~790 lines of shell that NOTHING has
# ever syntax-checked.
#
# WHY IT ESCAPES EVERY EXISTING CHECK
# ---------------------------------------------------------------------------
# install.sh writes it as a QUOTED heredoc:
#
#     cat > "${OSTLER_DIR}/bin/ostler-uninstall" <<'UNINSTALLEOF'
#     ... ~790 lines ...
#     UNINSTALLEOF
#
# A quoted heredoc's body is DATA, not code. `bash -n install.sh` parses the
# `cat` command and the delimiter and never looks inside, so the body can
# contain any syntax error at all and install.sh still parses clean.
#
# .github/workflows/colima-autostart.yml:236 runs exactly that check --
# `bash -n install.sh` -- and it is the only syntax check anywhere near this
# file. So the guard that looks like it covers the uninstaller does not.
#
# MEASURED, NOT ASSUMED. Injecting `if [ broken ; then` into the heredoc:
#
#     bash -n install.sh                    rc=0     <- CI stays green
#     bash -n on the EXTRACTED uninstaller  rc=2     <- catches it
#
# WHAT THAT COSTS. A syntax error here ships. It cannot fail during install,
# because install.sh only ever `cat`s the text. It fails the first time a
# customer runs `ostler-uninstall` -- at the exact moment they are trying to
# remove the product and are least willing to debug it, on a machine that is
# then left half-torn-down.
#
# ARM 3 IS THE CONTROL AND IT MUST NOT BE REMOVED. Arm 2 says "the extracted
# uninstaller parses". That is also what it would say if the extraction
# silently produced an empty file, or if bash -n had stopped working. Arm 3
# proves the predicate can fail by feeding it a known-bad copy.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uparse.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

GEN="${WORK}/ostler-uninstall"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-uninstall" <<.UNINSTALLEOF.$/{f=1;next} /^UNINSTALLEOF$/{f=0} f' \
    "$INSTALL_SH" > "$GEN"

# 1. The extraction has to have produced something substantial. An empty or
#    tiny file would make arm 2 pass vacuously.
_lines="$(wc -l < "$GEN" | tr -d ' ')"
if [[ "$_lines" -ge 200 ]]; then
    ok "1 extracted ${_lines} lines of generated uninstaller"
else
    echo "CANNOT-RUN: extracted only ${_lines} lines -- the heredoc markers moved," >&2
    echo "            so this is a broken search and not a verdict (exit 2)" >&2
    exit 2
fi

# 2. It must parse. This is the whole point of the file.
if bash -n "$GEN" 2>"${WORK}/err"; then
    ok "2 the generated uninstaller parses under bash"
else
    bad "2 the generated uninstaller has a SYNTAX ERROR: $(head -1 "${WORK}/err")"
fi

# 3. CONTROL. Prove the predicate can fail, by breaking a copy on purpose.
#    Without this, arm 2 reads the same whether the check works or not.
cp "$GEN" "${WORK}/broken"
printf 'if [ deliberately_broken ; then\n' >> "${WORK}/broken"
if bash -n "${WORK}/broken" 2>/dev/null; then
    bad "3 CONTROL: a deliberately broken copy PARSED -- the check is inert"
else
    ok "3 CONTROL: a deliberately broken copy is rejected"
fi

# 4. And under the shell a customer's Mac actually has. macOS ships
#    /bin/bash 3.2, and the uninstaller runs there, not under whatever
#    bash 5 a developer has on PATH.
if [[ -x /bin/bash ]]; then
    if /bin/bash -n "$GEN" 2>"${WORK}/err32"; then
        ok "4 it also parses under /bin/bash ($(/bin/bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1))"
    else
        bad "4 parses under bash but NOT under /bin/bash: $(head -1 "${WORK}/err32")"
    fi
else
    ok "4 no /bin/bash on this host, skipped (not a macOS runner)"
fi

# 5. The gap this file closes, asserted so it cannot quietly come back:
#    `bash -n install.sh` must NOT be treated as covering the uninstaller.
#    We demonstrate the blindness rather than describe it.
cp "$INSTALL_SH" "${WORK}/mutant.sh"
printf '\ncat > "/tmp/x" <<%s\nif [ broken ; then\n%s\n' "'HEREEOF'" "HEREEOF" >> "${WORK}/mutant.sh"
if bash -n "${WORK}/mutant.sh" 2>/dev/null; then
    ok "5 demonstrated: bash -n does NOT see inside a quoted heredoc"
else
    bad "5 bash -n DID see inside a quoted heredoc -- this file's premise is wrong"
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
