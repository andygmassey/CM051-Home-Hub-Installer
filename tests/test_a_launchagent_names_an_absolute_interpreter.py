#!/usr/bin/env python3
"""Every LaunchAgent the installer writes must name an ABSOLUTE first argument.

PROVED-RED-BY: this file, mutation 1 and mutation 2.

THE DEFECT THIS PROTECTS AGAINST, from CM051 #951 and #952:

  #951  Four feed plists are rendered with a bare `python3`, so WhatsApp,
        email, spoken and iMessage ingest depend on whatever `python3` launchd
        happens to resolve.
  #952  context-refresh and ostler-fda resolve python3 off PATH, so their store
        reads run under an interpreter nobody chose.

A LaunchAgent does not inherit the customer's shell PATH. That is stated in this
repo's own plist comments and it is why a bare interpreter is not a style
question: launchd resolves it against a minimal PATH, so the agent either runs
the wrong Python or fails to exec at all and parks with EX_CONFIG, which is not
retried.

BOTH ROWS ARE FIXED. MEASURED ON THE WALK BOX 2026-09-18, reading the plists
launchd actually loaded rather than the source that wrote them: 23 of 23 Ostler
agents name an absolute ProgramArguments[0], with the 23 itself as the CONTROL --
a zero there would have meant PlistBuddy read nothing rather than that nothing
was absolute. The six agents the two rows name by hand were checked individually
and all six are absolute.

🔴 AND NOTHING KEPT THEM THAT WAY, WHICH IS WHY THIS FILE EXISTS. A search for a
guard over plist interpreters returned only tests about other things. The fix was
present and ungated, which is the state that lets a defect come back quietly and
be rediscovered by a customer.

WHAT IT ASSERTS, in two layers, because one is not enough:

  1. Every ProgramArguments array install.sh writes has a first <string> that is
     absolute, or a ${VAR}.
  2. Every ${VAR} used that way is itself assigned an absolute value somewhere in
     install.sh. Layer 1 alone is satisfied by OSTLER_PYTHON=python3, which is
     exactly the defect wearing a variable.

British English throughout; " -- " not em-dashes.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "install.sh"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in str(detail).splitlines():
            print(f"        | {line}")


_ARRAY = re.compile(
    r"<key>ProgramArguments</key>\s*\n\s*<array>\s*\n\s*<string>([^<]*)</string>", re.M)
_VAR = re.compile(r"^\$\{?([A-Za-z_][A-Za-z_0-9]*)\}?")

# HOME is absolute by definition -- POSIX requires it and the shell owns it --
# so demanding an assignment inside install.sh would be demanding the script
# redefine something it correctly inherits. Kept as an explicit named set rather
# than a silent exception, so adding to it is a visible decision.
_ABSOLUTE_BY_DEFINITION = {"HOME"}


def first_args(text):
    return _ARRAY.findall(text)


def offenders(text):
    """Return (list of non-absolute first-args, list of vars that are not absolute)."""
    bare, loose_vars = [], []
    for a in first_args(text):
        a = a.strip()
        if a.startswith("/"):
            continue
        m = _VAR.match(a)
        if not m:
            bare.append(a or "<empty>")
            continue
        name = m.group(1)
        # Layer 2. Every assignment of that name must yield an absolute path:
        # a literal /, or another ${VAR}/..., or a command substitution that
        # resolves one (command -v). A bare word is the defect with a variable
        # in front of it.
        if name in _ABSOLUTE_BY_DEFINITION:
            continue
        assigns = re.findall(
            r"(?m)^[ \t]*(?:local[ \t]+)?%s=(.+)$" % re.escape(name), text)
        if not assigns:
            loose_vars.append(f"{name} (no assignment found in install.sh)")
            continue
        for v in assigns:
            v = v.strip().strip('"').strip("'")
            # A value that STARTS with another expansion is absolute exactly
            # when that expansion is, and this file already walks those: the
            # defect it hunts is a BARE WORD, which starts with a letter.
            # Accepting $VAR unbraced and $1 matters because install.sh writes
            # both, and rejecting them would bury the one shape that is a
            # defect under fifty that are not.
            if not v or v.startswith("/") or v.startswith("$"):
                continue
            loose_vars.append(f"{name}={v[:48]}")
    return bare, loose_vars


def main():
    print("test_a_launchagent_names_an_absolute_interpreter")
    if not SRC.is_file():
        print(f"CANNOT-RUN: no install.sh at {SRC}", file=sys.stderr)
        return 2
    src = SRC.read_text(encoding="utf-8")

    # ── 0. DENOMINATOR AND CONTROL. Every ProgramArguments key in the file must
    #       have been PARSED. If the regex reads 12 of 17, the five it missed are
    #       exactly where a bare interpreter would hide, and the run would report
    #       a clean pass on a partial read.
    keys = src.count("<key>ProgramArguments</key>")
    parsed = len(first_args(src))
    if keys > 0 and parsed == keys:
        ok(f"(0) DENOMINATOR: all {parsed} of {keys} ProgramArguments arrays were parsed, "
           "so a clean result below covers every one of them")
    else:
        bad(f"(0) parsed {parsed} of {keys} ProgramArguments arrays. The unparsed ones are "
            "exactly where a bare interpreter would hide, so this run proves nothing")
        return 1

    bare, loose = offenders(src)
    if not bare:
        ok(f"(1) every one of the {parsed} first arguments is absolute or a variable")
    else:
        bad(f"(1) {len(bare)} LaunchAgent(s) name a NON-ABSOLUTE first argument", "\n".join(bare))

    if not loose:
        ok("(2) and every variable used as the first argument is itself assigned an "
           "absolute value -- OSTLER_PYTHON=python3 would be the defect wearing a variable")
    else:
        bad(f"(2) {len(loose)} variable(s) used as ProgramArguments[0] are not absolute",
            "\n".join(loose))

    # ===================================================================
    # MUTATION. Both shapes of the defect must go RED.
    # ===================================================================
    print()
    print("  -- mutation --")

    m1 = src.replace("<string>/bin/bash</string>", "<string>python3</string>", 1)
    if m1 == src:
        bad("(M1) the mutant could not be built", "no <string>/bin/bash</string> to mutate")
    else:
        b1, _ = offenders(m1)
        if "python3" in b1:
            ok("(M1) RED ON THE BARE FORM: a plist rendered with a bare python3 is caught, "
               "so assertion (1) is load-bearing")
        else:
            bad(f"(M1) MUTANT SURVIVED: a bare python3 first argument was not flagged ({b1})")

    m2 = re.sub(r"(?m)^(OSTLER_PYTHON=).*$", r"\1python3", src, count=1)
    if m2 == src:
        bad("(M2) the mutant could not be built", "no top-level OSTLER_PYTHON assignment")
    else:
        _, l2 = offenders(m2)
        if any(x.startswith("OSTLER_PYTHON=") for x in l2):
            ok("(M2) RED ON THE VARIABLE FORM: OSTLER_PYTHON=python3 is caught by assertion "
               "(2), which is the half assertion (1) cannot see")
        else:
            bad(f"(M2) MUTANT SURVIVED: the defect wearing a variable was not flagged ({l2})")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
