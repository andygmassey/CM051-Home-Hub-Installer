#!/usr/bin/env python3
"""followup_keys_match_chat_threads finds pwg-convo where install.sh puts it.

Walk 132 (MBP re-run): /usr/local/bin/pwg-convo does not exist on the warm box, so the
synthetic 1:1 never ran. The probe now resolves the CLI from the install's own locations
(install.sh:24724-24725: the CM048 venv, the ${OSTLER_DIR}/bin link, the /usr/local/bin link),
first executable wins, and reads its shebang for the venv interpreter.

Control: the same check on a copy with the old single hardcoded path must FAIL.
Exit 0 pass, 1 fail. No box.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes",
                     "followup_keys_match_chat_threads.sh")
VENV = "services/cm048/.venv/bin/pwg-convo"
OLD = 'CLI=\\${OSTLER_CONVO_SEED_CLI:-/usr/local/bin/pwg-convo}'


def resolves_like_install(src):
    return ("services/cm048/.venv/bin/pwg-convo" in src
            and "/bin/pwg-convo" in src
            and "for c in" in src
            and OLD not in src)


def main():
    with open(PROBE, encoding="utf-8") as fh:
        real = fh.read()
    ok_real = resolves_like_install(real)
    mutant = real.replace("for c in", "for c in __REMOVED__", 1)
    # control: the pre-fix hardcoded line, which the MBP proved absent
    old_line = 'seed_py="$(box_run "CLI=\\${OSTLER_CONVO_SEED_CLI:-/usr/local/bin/pwg-convo}; '
    ok_mutant = resolves_like_install(real.replace("for c in", "CLI_OLD_ONLY_" , 1)
                                      + "\n" + old_line + '\\"\\$CLI\\"')
    print("real probe resolves pwg-convo like install.sh: %s" % ok_real)
    print("control (hardcoded /usr/local/bin only): resolves like install: %s" % ok_mutant)
    if ok_real and not ok_mutant:
        print("PASS")
        return 0
    print("FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
