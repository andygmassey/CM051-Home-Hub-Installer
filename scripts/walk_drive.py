#!/usr/bin/env python3
"""Drive install.sh's interactive question phase on a real pty, and ADJUDICATE.

PROVENANCE. The pty mechanics, the reactive answer table, the loop guard and
the secret-withholding rule below are Archie's, handed over 2026-08-29 as a
283-line driver (sha256 bd18e08a...) that had run on the walk box and never
lived in a repo. Promoted here so it is reviewable, testable and versioned
rather than existing as one copy on one machine. Three defects were fixed on
the way in; each is marked FIX 1/2/3 and each has a test that fails without it.

WHY NOT `script`.
    /usr/bin/script -q LOG /bin/bash install.sh < fifo
        script: tcgetattr/ioctl: Operation not supported on socket

BSD script calls tcgetattr() on ITS OWN stdin to copy the terminal settings
onto the pty it creates. A FIFO is not a terminal, so it exits before ever
forking the child. Feeding it /dev/null instead does start, but delivers
exactly ONE end-of-file to the pty: the first pending read returns empty and
every read after it blocks forever with no data and no EOF. That is what
parked the 01:40Z walk at "Full name:" -- measured on the CHILD bash
(0:00.05 CPU across 7m44s), not on the script wrapper, whose own CPU is
always ~0 and proves nothing either way.

So we own the pty ourselves. pty.fork() gives the child a controlling
terminal, which satisfies install.sh's `[ -t 0 ]` check (it only does
`exec < /dev/tty` when stdin is NOT a tty), and the master end stays open
for the whole install, so a read never sees a spurious EOF.

ANSWERING IS REACTIVE, NOT A PRE-BAKED STREAM. A blind stream mis-pairs the
moment one prompt is skipped by a branch we did not predict, and every later
answer then lands on the wrong question while still looking healthy. Here we
read the prompt actually on screen, choose from it, and record the pair to a
TSV so the walk record can quote what was answered.

THIS SCRIPT RETURNS A THREE-WAY VERDICT, NOT A PASS/FAIL.

    0  PASS        install.sh reached its own end and said so
    1  FAIL        it did not, and we watched that happen
    2  CANNOT-RUN  we were not in a position to find out

That third exit is the whole point of the file. Andy's first line of the
discipline is that CANNOT-RUN is not FAIL and is not PASS -- three outcomes,
three branches -- and a walk driver is exactly where the three get collapsed,
because the operator is tired and the only number on screen is an exit code.
"""

import errno
import os
import pty
import re
import select
import socket
import struct
import sys
import termios
import time
import fcntl

HOME = os.path.expanduser("~")
QA = os.path.join(HOME, ".walk-qa.tsv")
TRACE = os.path.join(HOME, ".walk-drive.trace")

# FIX 1. The result file, and the stamp that proves WHICH RUN wrote it.
#
# THE DEFECT. `.walk-rc` was written once, at the very end, and never cleared
# at the start. Any run that did not reach its last line -- a crash, a kill, a
# box that rebooted, an operator who hit ^C -- left the PREVIOUS run's exit
# code sitting there, and the tracker read it as this run's verdict. A stale
# 0 is the worst of the two: it reports SUCCESS for a run that never finished.
#
# THE FIX has two halves, because either alone still has a hole:
#   (a) unlink the result at start, so an unfinished run leaves ABSENT (which
#       is honest) rather than a previous verdict (which is a lie); and
#   (b) stamp the run's start, and refuse to hand back a result that predates
#       it -- covering the case where a second reader, or an overlapping run,
#       finds a file written by neither.
#
# A STAMPED READ IS ONLY EVIDENCE AT ITS STAMP. That applies to our own
# output as much as to anything we measure.
RESULT = os.path.join(HOME, ".walk-rc")
RUN_START = os.path.join(HOME, ".walk-run-start")

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")

# FIX 2. The completion marker.
#
# THE DEFECT. The driver returned 0 unconditionally and recorded install.sh's
# own exit status as the verdict. Neither is a completion signal:
#
#   - install.sh CAN exit 0 without finishing. That is #568: a `set -u` abort
#     under bash 3.2 terminates the script with status 0, having run perhaps
#     a third of it. Every observable of a successful install is present --
#     zero exit, no error text, a log that simply stops -- and the walk
#     records PASS.
#   - the driver's OWN 0 said nothing at all; it was a literal.
#
# So success must require POSITIVE EVIDENCE that install.sh reached its end,
# and the absence of that evidence must be reported as CANNOT-RUN or FAIL
# with the difference stated -- never quietly as success.
#
# WHAT THE MARKER ACTUALLY IS, measured on origin/main rather than assumed:
# lib/progress_emitter.sh's gui_done() emits
#
#     #OSTLER<TAB>DONE<TAB>status=ok<TAB>failed_steps=N
#
# via gui_emit, whose FIRST LINE is `[[ "${OSTLER_GUI:-0}" != "1" ]] && return 0`.
#
# 🔴 THE CONSEQUENCE, AND IT IS A FINDING IN ITS OWN RIGHT: under a plain TTY
# walk (OSTLER_GUI unset) install.sh's gui_done is the no-op stub defined in
# its own else-branch, so it emits NOTHING. A pty walk driven without
# OSTLER_GUI=1 therefore CANNOT observe completion by any means -- there is no
# other end-of-run line that is not a locale string. That is why "marker
# absent" splits two ways below: with the channel off it is our blindness
# (CANNOT-RUN), with the channel on it is the product's silence (FAIL).
# Guessing would have made every TTY walk report a false product failure.
DONE_MARKER_FILE = os.path.join(HOME, ".walk-done-marker")
DEFAULT_DONE_OK = r"#OSTLER\s+DONE\s+status=ok\b"
DEFAULT_DONE_ANY = r"#OSTLER\s+DONE\s+status=(\w+)"

# FIX 3. Where the port list comes from.
#
# THE DEFECT. The pre-walk port check took its list from install.sh's own
# error message -- the text it prints when a port is already held. That is a
# scrape of a failure path, so it yields a list only when there is already a
# conflict, and an EMPTY list whenever the wording moves, the message is
# localised, or the install dies before printing it. An empty list then feeds
# a `for` loop, the loop body never executes, nothing is checked, and the
# check reports success. A zero-length loop is the cheapest possible green.
#
# THE FIX: read the DECLARED FIELD. install.sh assigns
#     OSTLER_PREFLIGHT_PORTS="3000 6333 6379 7878 8044 8144"
# and tests/test_port_preflight_covers_published.sh already holds that
# assignment equal to the ports the compose heredocs publish. Parsing the
# assignment means we check what the installer will check, and an empty or
# absent field is CANNOT-RUN -- never a vacuous pass.
PORTS_FIELD = re.compile(r'^OSTLER_PREFLIGHT_PORTS="?([^"\n]*)"?', re.M)

# Answers that would otherwise disclose where the operator is.
#
# The handed-over table hardcoded a country code, a timezone and a person's
# name. CM051 is a PUBLIC repository, and a fixture that pins a jurisdiction
# is a disclosure no PII pattern would ever flag -- it is a MEANING, not a
# shape. The values now come from an optional operator-local file and default
# to the installer's OWN shipped default (44) and to UTC, which assert nothing
# about anybody.
#
# 🔎 SET ~/.walk-locale.tsv TO EXERCISE #539. The original chose a country
# code deliberately: an answered code whose region resolves to "ZZ" is the
# input that exercises task #539, and 44 does not. The capability is kept and
# the disclosure is not -- put "country_code<TAB>NNN" and "timezone<TAB>..."
# in that file on the walk box and the walk covers #539 again.
LOCALE_FILE = os.path.join(HOME, ".walk-locale.tsv")
DEFAULT_COUNTRY_CODE = "44"      # install.sh's own shown default
DEFAULT_TIMEZONE = "UTC"


def _locale_defaults():
    vals = {"country_code": DEFAULT_COUNTRY_CODE, "timezone": DEFAULT_TIMEZONE}
    try:
        with open(LOCALE_FILE) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#") or "\t" not in line:
                    continue
                key, val = line.split("\t", 1)
                if key in vals and val:
                    vals[key] = val
    except IOError:
        pass
    return vals


def build_table():
    loc = _locale_defaults()
    cc = loc["country_code"]
    tz = loc["timezone"]
    # First match wins, so order matters where one title contains another.
    # "" means press Enter, i.e. accept the default the installer is showing.
    # Only prompts that offer NO usable default get an explicit answer.
    return [
        # -- no default offered; Enter would not advance ---------------------
        ("Ready to continue?",                          "y"),
        # BOTH TOKENS ARE IN THE APPROVED CAST -- see .pii-name-registry.tsv,
        # which CM051 shares verbatim with CM041 so the repos converge on one
        # cast rather than each inventing its own. That is a MACHINE-READABLE
        # declaration that this is not a person, which is strictly stronger
        # than a comment asserting it.
        #
        # The handed-over table spent three comment lines proving its phone
        # number fictional and none proving the same of its person name, which
        # invites the next reader to assume the unjustified one is real.
        # Justify both or neither.
        #
        # 🔴 My first attempt here invented a name and asserted in prose that
        # it was fictional. bin/pii_name_guard.py blocked it -- correctly, it
        # is a first+last pair like any other -- and the registry's own header
        # says the fix for that is to RENAME, never to add a cast row to turn a
        # red green. Renaming into the existing cast is the move it wants.
        ("Full name",                                   "Sam Doe"),
        # iMessage refuses an empty list and re-asks forever. The value is the
        # installer's OWN documented example, and +447700900000 is inside Ofcom's
        # reserved drama range (07700 900000-900999), so it is provably fictional
        # and can never reach a real person.
        ("Allowed contacts",                            "+447700900000"),
        # Two distinct titles: COUNTRY_CODE_ENTER has no default, COUNTRY_CODE_DEFAULT
        # ships "[44]". Matching only the first let the walk silently take the
        # shipped default on a box that is not in that country. Both are
        # answered, so the walk cannot depend on which one it is shown.
        ("Enter country code",                          cc),
        ("Default country code",                        cc),
        ("Use +",                                       "y"),
        ("Use this timezone?",                          "y"),
        ("Enter timezone",                              tz),
        ("What would you like to call your assistant?", "Ava"),
        ("Your decision (Y / N)",                       "Y"),      # Article 9
        ("Ready to install?",                           "INSTALL"),
        # -- deliberate answers that differ from the shown default -----------
        # Enrichment stays OFF: Andy's decision 2026-08-18 (task #397).
        ("Look up public facts about things you save?", "n"),
        # No iPhone to pair on this walk and setup wants an auth flow.
        ("Connect your iPhone and Watch",               "skip"),
        # Never store a login password on disk.
        ("Store your login password",                   "N"),
        # Skip the passphrase branch: keeps the walk clear of credential entry.
        ("Set a recovery passphrase too?",              "n"),
        # Clean account: nothing to import.
        ("Import these during install?",                "n"),
        ("Import Gmail messages from this Takeout?",    "n"),
        ("Add a mail account to Apple Mail?",           "n"),
        # No Aqua session on this account, so opening apps cannot succeed.
        ("Open Apple Mail so it can start syncing?",    "n"),
        ("Open Calendar so it can start syncing?",      "n"),
        ("Open Contacts so it can start syncing?",      "n"),
    ]


IDLE_BEFORE_ANSWER = 2.5   # seconds of silence before we treat a line as a prompt

# Live overrides, re-read on EVERY prompt so a surprise question can be answered
# WITHOUT restarting the install and throwing away the progress so far. Format
# is one "substring<TAB>answer" per line. Consulted BEFORE the built-in table.
OVERRIDES = os.path.join(HOME, ".walk-answers.tsv")

# A prompt whose answer must never be written to the Q&A record, the trace, or
# anything that could be pasted into a public repo. The installer's own `secret`
# kind is not visible from out here, so match on the wording instead.
SECRET_RE = re.compile(r"passphrase|password|secret|token|api key", re.I)

# "@passphrase" in an override resolves from this 0600 file at answer time, so
# the value is never an argument, never in the process table, and never in this
# source. It is a throwaway chosen for a disposable walk account.
PASSPHRASE_FILE = os.path.join(HOME, ".walk-passphrase")

PASS, FAIL, CANNOT_RUN = 0, 1, 2


def load_overrides():
    rows = []
    try:
        with open(OVERRIDES) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#") or "\t" not in line:
                    continue
                needle, ans = line.split("\t", 1)
                rows.append((needle, ans))
    except IOError:
        pass
    return rows


def resolve(ans):
    if ans == "@passphrase":
        try:
            return open(PASSPHRASE_FILE).read().strip()
        except IOError:
            return ""
    return ans


def trace(msg):
    with open(TRACE, "a") as fh:
        fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    sys.stdout.flush()


def verdict(code, headline, detail=""):
    """Print the verdict in the one vocabulary the estate uses, and return it.

    The word comes first and the reason second, because the operator reading
    this at 3am scans the first token. CANNOT-RUN says, in the line itself,
    that nothing about the product has been shown -- so nobody goes off to
    debug install.sh on the strength of a harness problem (#1239).
    """
    word = {PASS: "PASS", FAIL: "FAIL", CANNOT_RUN: "CANNOT-RUN"}[code]
    sys.stderr.write("\nWALK %s: %s\n" % (word, headline))
    if detail:
        sys.stderr.write("%s\n" % detail)
    if code == CANNOT_RUN:
        sys.stderr.write(
            "CANNOT-RUN is not a pass and is not a product failure. The walk did "
            "not reach a position to judge install.sh. Fix the condition named "
            "above and walk again; do not record this as a result.\n")
    try:
        trace("verdict %s -- %s" % (word, headline))
    except IOError:
        pass
    return code


def read_config(name, what):
    """Read one of the HOME-rooted config files, or explain why we cannot."""
    path = os.path.join(HOME, name)
    try:
        with open(path) as fh:
            val = fh.read().strip()
    except IOError as exc:
        return None, "%s (%s) could not be read: %s" % (what, path, exc)
    if not val:
        return None, "%s (%s) is empty" % (what, path)
    return val, None


def declared_ports(install_sh):
    """FIX 3: the port list, from the DECLARED FIELD in install.sh.

    Returns (ports, error). An absent field, or a field that resolves to no
    ports, is an ERROR -- never an empty list handed back to a caller that
    would loop zero times over it and report success.
    """
    try:
        with open(install_sh, "r", errors="replace") as fh:
            src = fh.read()
    except IOError as exc:
        return None, "could not read %s to find its declared port list: %s" % (
            install_sh, exc)
    m = PORTS_FIELD.search(src)
    if not m:
        return None, (
            "install.sh declares no OSTLER_PREFLIGHT_PORTS field. The list is "
            "read from the ASSIGNMENT, not scraped from an error message, so "
            "there is nothing to check and nothing has been checked.")
    ports = [p for p in m.group(1).split() if p]
    if not ports:
        return None, (
            "OSTLER_PREFLIGHT_PORTS is declared but resolves to NO PORTS. That "
            "is not a box with nothing to check -- it is a check that cannot "
            "run. A zero-length loop over this list would pass having measured "
            "nothing.")
    bad = [p for p in ports if not p.isdigit()]
    if bad:
        return None, "OSTLER_PREFLIGHT_PORTS contains non-numeric entries: %s" % (
            " ".join(bad))
    return ports, None


def port_is_held(port):
    """Three outcomes, not two: held / free / could not measure."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", int(port)))
        return "free"
    except OSError as exc:
        # EADDRINUSE is the only errno that means SOMETHING ELSE HAS IT.
        # EACCES means we lacked the privilege to ask -- a privileged port
        # under an unprivileged user reports the same refusal whether it is
        # held or free, so it is unmeasured, not held. Collapsing the two
        # would have this probe accuse an idle box of a conflict.
        if exc.errno == errno.EADDRINUSE:
            return "held"
        return "unmeasured"
    finally:
        sock.close()


def preflight_ports(install_sh):
    """Refuse a walk that install.sh's own preflight is going to refuse.

    Not a duplicate of that preflight: this one runs BEFORE the install so the
    operator learns the box is unusable in a second rather than after the
    prompts, and it names the ports. Its list is the installer's own declared
    field, so the two cannot drift apart silently.
    """
    ports, err = declared_ports(install_sh)
    if err:
        return CANNOT_RUN, err
    states = [(p, port_is_held(p)) for p in ports]
    held = [p for p, s in states if s == "held"]
    unmeasured = [p for p, s in states if s == "unmeasured"]
    trace("port preflight over %d declared port(s): %s" % (
        len(ports), " ".join("%s=%s" % (p, s) for p, s in states)))
    if held:
        return CANNOT_RUN, (
            "%d of %d declared port(s) are already held: %s. install.sh's own "
            "preflight will refuse to start containers over them, so this walk "
            "would measure the refusal and not the product."
            % (len(held), len(ports), " ".join(held)))
    if unmeasured:
        return CANNOT_RUN, (
            "%d of %d declared port(s) could not be measured: %s. A port we "
            "could not measure has NOT been shown free."
            % (len(unmeasured), len(ports), " ".join(unmeasured)))
    return PASS, "%d declared port(s) free: %s" % (len(ports), " ".join(ports))


def done_patterns():
    """The completion marker, overridable for tests and for a changed wire."""
    try:
        with open(DONE_MARKER_FILE) as fh:
            custom = fh.read().strip()
    except IOError:
        custom = ""
    if custom:
        return re.compile(custom), None
    return re.compile(DEFAULT_DONE_OK), re.compile(DEFAULT_DONE_ANY)


def adjudicate(log_path, rc, marker_channel_on):
    """FIX 2: rc is evidence, never the verdict. Require the marker.

    The four cases, and why each lands where it does:

      marker says ok      + rc 0    -> PASS. The only path to PASS.
      marker says ok      + rc != 0 -> FAIL. It announced completion and then
                                       exited non-zero; something after the
                                       marker died and that is a real defect.
      marker says not-ok            -> FAIL, quoting the status it gave.
      no marker, channel ON         -> FAIL. The channel that carries
                                       completion was open and nothing
                                       terminal came out of it. This is the
                                       #568 shape: exited without finishing.
      no marker, channel OFF        -> CANNOT-RUN. We had no way to see
                                       completion. Calling this FAIL would
                                       accuse the product of our own blindness.
    """
    ok_re, any_re = done_patterns()
    try:
        with open(log_path, "rb") as fh:
            body = fh.read().decode("utf-8", "replace")
    except IOError as exc:
        return CANNOT_RUN, "the pty log could not be re-read: %s" % exc, ""

    if ok_re.search(body):
        if rc == 0:
            return PASS, "install.sh emitted its completion marker and exited 0", ""
        return (FAIL,
                "install.sh emitted its completion marker but exited rc=%d" % rc,
                "Something after the marker failed. The marker is not a "
                "licence to ignore a non-zero exit.")

    seen = any_re.search(body) if any_re else None
    if seen:
        return (FAIL,
                "install.sh terminated with status=%s (rc=%d)" % (seen.group(1), rc),
                "This is a MEASURED failure: the installer said so itself.")

    if marker_channel_on:
        return (FAIL,
                "no completion marker in the whole log, and install.sh exited rc=%d" % rc,
                "The marker channel was ON (OSTLER_GUI=1), so a completed "
                "install would have emitted one. rc=0 here is the #568 shape: "
                "a `set -u` abort under bash 3.2 exits 0 having never finished. "
                "AN EXIT CODE OF ZERO IS NOT A COMPLETION SIGNAL.")

    return (CANNOT_RUN,
            "no completion marker, and the marker channel was OFF",
            "install.sh only emits `#OSTLER DONE` through gui_emit, whose first "
            "line returns early unless OSTLER_GUI=1; under a plain TTY walk its "
            "gui_done is a no-op stub. So THIS WALK COULD NOT HAVE SEEN "
            "COMPLETION even on a perfect install, whatever rc says. Re-run with "
            "OSTLER_GUI=1, or put a pattern in ~/.walk-done-marker.")


def answer_for(prompt, table):
    # Live overrides win, so a question we did not anticipate can be answered
    # without killing the install and losing everything answered so far.
    for needle, ans in load_overrides():
        if needle in prompt:
            return resolve(ans), True
    for needle, ans in table:
        if needle in prompt:
            return resolve(ans), True
    # NOTHING MATCHED. We still press Enter, because most prompts carry a
    # safe default -- but this MUST be visible, and it was not.
    #
    # 2026-08-29: the Article 9 consent prompt had been renamed to "One
    # last thing: how third-party data works". The stale needle missed,
    # Enter took the shown default, and that default is DECLINE. The
    # installer cancelled cleanly and exited 0. A whole walk was spent
    # discovering that a table entry had drifted.
    #
    # A STALE ANSWER TABLE FAILS OPEN TO THE DEFAULT, and one of those
    # defaults ends the install. The miss is the thing to make loud.
    return "", False


def read_result(argv):
    """FIX 1 (half b): hand back a result only if THIS run produced it.

    `walk_drive.py --read-result` prints the recorded exit code, and refuses
    with CANNOT-RUN when the file predates the run start it claims to describe.
    A result whose mtime is older than the run is somebody else's result.
    """
    if not os.path.exists(RESULT):
        return verdict(CANNOT_RUN,
                       "no walk result at %s" % RESULT,
                       "Absent is not zero. Either no walk has run since the "
                       "last clear, or the run that was going to write this one "
                       "died before it finished.")
    try:
        started = os.path.getmtime(RUN_START)
    except OSError:
        return verdict(CANNOT_RUN,
                       "no run-start stamp at %s" % RUN_START,
                       "Without it the result's age cannot be adjudicated, so it "
                       "cannot be told apart from a leftover of an earlier run.")
    written = os.path.getmtime(RESULT)
    if written < started:
        return verdict(CANNOT_RUN,
                       "the walk result is STALE -- it predates the run it would "
                       "describe",
                       "result mtime %s < run start %s. This is a previous run's "
                       "verdict; reporting it as this one's is how a crashed walk "
                       "gets recorded as a pass."
                       % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(written)),
                          time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))))
    with open(RESULT) as fh:
        sys.stdout.write(fh.read().strip() + "\n")
    return PASS


def main(argv):
    if "--read-result" in argv:
        return read_result(argv)

    # FIX 1 (half a). Clear the previous verdict BEFORE anything can fail, and
    # stamp this run's start. Every exit below this line therefore leaves
    # either this run's result or no result at all -- never a stale one.
    try:
        if os.path.exists(RESULT):
            os.unlink(RESULT)
        with open(RUN_START, "w") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
    except OSError as exc:
        return verdict(CANNOT_RUN,
                       "could not clear the previous walk result",
                       "%s. Refusing to start, because a run that cannot clear "
                       "the old verdict can leave it behind to be read as its "
                       "own." % exc)

    log_path, err = read_config(".walk-log", "the pty log path")
    if err:
        return verdict(CANNOT_RUN, "the walk is not configured", err)
    install_sh, err = read_config(".walk-installsh", "the install.sh path")
    if err:
        return verdict(CANNOT_RUN, "the walk is not configured", err)
    if not os.path.isfile(install_sh):
        return verdict(CANNOT_RUN, "the walk is not configured",
                       "install.sh (%s) is not a file" % install_sh)

    # Open the log BEFORE forking. A child we cannot log is a child whose
    # output is gone, and gone output is unadjudicable later.
    try:
        log = open(log_path, "ab", buffering=0)
    except IOError as exc:
        return verdict(CANNOT_RUN, "the pty log could not be opened",
                       "%s: %s" % (log_path, exc))

    code, detail = preflight_ports(install_sh)
    if code != PASS:
        return verdict(code, "port preflight", detail)
    trace("port preflight: %s" % detail)

    marker_channel_on = os.environ.get("OSTLER_GUI") == "1"
    table = build_table()

    if not os.path.exists(QA):
        with open(QA, "w") as fh:
            fh.write("utc\tprompt\tanswer\n")

    pid, master = pty.fork()
    if pid == 0:
        # Child: a real controlling terminal, so install.sh's `[ -t 0 ]`
        # test passes and it does NOT try to reopen /dev/tty.
        os.environ["TERM"] = "xterm-256color"
        os.execv("/bin/bash", ["/bin/bash", install_sh])
        os._exit(127)

    # Give the pty a sane window so the installer's layout does not wrap oddly.
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 48, 120, 0, 0))
    except Exception as exc:
        trace("could not set winsize: %r" % (exc,))

    trace("driver up: child pid %d, log %s" % (pid, log_path))

    pending = b""          # bytes since the last newline
    last_out = time.time()
    answered = None
    answered_with = None
    repeat = 0

    while True:
        try:
            rd, _, _ = select.select([master], [], [], 1.0)
        except select.error as exc:
            if exc.args[0] == errno.EINTR:
                continue
            raise

        if rd:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                trace("pty closed -- child finished")
                break
            log.write(chunk)
            last_out = time.time()
            buf = pending + chunk
            if b"\n" in buf:
                pending = buf.rsplit(b"\n", 1)[1]
            else:
                pending = buf
            continue

        # No output for a second. A prompt is pending only when there are
        # unterminated bytes on the current line and output has gone quiet.
        if not pending.strip():
            continue
        if time.time() - last_out < IDLE_BEFORE_ANSWER:
            continue

        prompt = ANSI.sub(b"", pending).decode("utf-8", "replace").strip()
        if not prompt:
            pending = b""
            continue

        # Resolve the answer BEFORE the loop guard. The guard exists to
        # stop us answering the same question the same WAY forever. It
        # must not stop us answering it a DIFFERENT way, which is exactly
        # what the live-override channel is for.
        #
        # Keyed on the question alone, it defeated that channel outright:
        # 2026-08-29, a stale table answered the now-MANDATORY passphrase
        # prompt with an empty line, the guard latched after 3 tries, and
        # the override written 170 re-asks later could never be applied.
        # The install sat unanswerable in a `while true` with no cap.
        # The guard is now keyed on the (question, answer) PAIR.
        ans, matched = answer_for(prompt, table)
        if not matched:
            trace("UNMATCHED -- no needle for this prompt, pressing Enter "
                  "to take the installer default: %r" % (prompt,))

        if prompt == answered and ans == answered_with:
            repeat += 1
            if repeat >= 3:
                trace("LOOP: %r re-asked %d times, answer unchanged -- not answering again" % (prompt, repeat))
                last_out = time.time()
                continue
        else:
            repeat = 0
        os.write(master, (ans + "\n").encode())
        answered = prompt
        answered_with = ans

        # The walk record gets quoted into PRs and a PUBLIC repo, so a secret
        # must never reach it. Record that the question was answered and that
        # the answer was withheld, which is the honest thing to write down.
        if SECRET_RE.search(prompt):
            shown = "<SECRET WITHHELD, %d chars>" % len(ans)
        elif ans:
            shown = ans
        elif matched:
            shown = "<ENTER (deliberate)>"
        else:
            shown = "<ENTER (UNMATCHED, took installer default)>"
        with open(QA, "a") as fh:
            fh.write("%s\t%s\t%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), prompt, shown))
        trace("answered %r -> %s" % (prompt, shown))
        pending = b""
        last_out = time.time()

    _, status = os.waitpid(pid, 0)
    rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
    trace("install.sh exited rc=%d" % rc)
    log.close()

    # The recorded rc is EVIDENCE and is written for the record. It is not
    # the verdict, and the file it goes in is named for what it is.
    with open(RESULT, "w") as fh:
        fh.write(str(rc) + "\n")

    code, headline, detail = adjudicate(log_path, rc, marker_channel_on)
    return verdict(code, headline, detail)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
