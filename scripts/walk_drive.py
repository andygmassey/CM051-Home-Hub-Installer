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
import subprocess
import struct
import sys
import termios
import time
import fcntl

HOME = os.path.expanduser("~")
QA = os.path.join(HOME, ".walk-qa.tsv")

# The exact string written into the Q&A record for a prompt the table did not
# recognise. ONE definition, read by both the writer below and the verdict
# above: two copies of a sentinel is one copy plus a gate that silently stops
# matching.
UNMATCHED_MARK = "<ENTER (UNMATCHED, took installer default)>"


def _unmatched_prompts():
    """Prompts this run answered by falling open to the installer's default.

    Returns a list of prompt strings, or None when the record cannot be read.
    None is NOT an empty list: "we could not look" and "there were none" are
    different findings, and only one of them lets a cancel be blamed on the
    product. ttywalk clears this file at the start of every run, so what is
    here belongs to this run.
    """
    try:
        with open(QA, "r") as fh:
            rows = fh.read().splitlines()
    except IOError:
        return None
    out = []
    for row in rows[1:]:                      # row 0 is the header
        parts = row.split("\t")
        if len(parts) >= 3 and UNMATCHED_MARK in parts[2]:
            out.append(parts[1])
    return out

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

# THE RAW EXIT CODE IS NOT THE VERDICT, AND KEEPING THEM IN ONE FILE LET A
# FAILED WALK PRINT 0. MEASURED on walk 11: install.sh reached its end and
# exited 0, so .walk-rc held 0, and ttywalk.sh printed that 0 under the
# heading "VERDICT (walk_drive.py's own adjudication)". adjudicate() had
# already returned FAIL for three failed steps. The two numbers answer
# different questions -- "what did the process return" and "what do we
# conclude" -- and only the second is a verdict, so it gets its own file.
VERDICT_F = os.path.join(HOME, ".walk-verdict")

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
        # 🔴 THE PROMPT WHOSE DEFAULT ENDS THE INSTALL. Its title is
        # "One last thing: how third-party data works" and it ships "[n]",
        # where n means "I do not consent" and CANCELS. That default is
        # correct for a consent gate -- consent must be affirmative and a
        # default of yes would manufacture it -- but it means an unanswered
        # walk does not stall, it TERMINATES, and the run then reads as a
        # build failure. Measured 2026-09-04: walk 3 of v1.0.65 died here
        # with `#OSTLER DONE status=cancelled` after 24 answers, and the
        # verdict said FAIL.
        ("how third-party data works",                  "Y"),
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


def port_bind_probe(port):
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


def count_listen_rows(text, port):
    """LISTEN rows for `port` in netstat/ss output. THREE formats, one parser.

    🔴 MEASURE ON THE HOST THAT RUNS IT -- and my first version did not.
    I wrote this against `/usr/sbin/netstat -an -p tcp -f inet` alone, which
    is macOS. The walk box is macOS so the DRIVER was fine, but the TESTS run
    on a Linux runner with no /usr/sbin/netstat, so the probe returned "cant"
    for every port, `free + cant` graded unmeasured, and the preflight refused
    every port on CI. Two PRE-EXISTING tests went red and the cause was mine.

    The three shapes, and why one split() cannot do it:
        BSD netstat  tcp4  0  0  127.0.0.1.6333   *.*        LISTEN
        GNU netstat  tcp   0  0  127.0.0.1:6333   0.0.0.0:*  LISTEN
        ss -Hltn     LISTEN 0  4096  127.0.0.1:6333  0.0.0.0:*
    LISTEN is the LAST field on both netstats and the FIRST on ss, and the
    local address separates its port with '.' on BSD and ':' elsewhere.

    Split out as a pure function precisely so both formats can be tested
    from sample text on either host, rather than only the one I happen to be
    standing on.
    """
    n = 0
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        if cols[-1] == "LISTEN":          # netstat, BSD or GNU
            local = cols[3]
        elif cols[0] == "LISTEN":         # ss -Hltn
            local = cols[3]
        else:
            continue
        # ':' first: an IPv6 local address is [::1]:6333, and rsplitting on
        # '.' there would return the whole string.
        tail = local.rsplit(":", 1)[-1] if ":" in local else local.rsplit(".", 1)[-1]
        if tail == str(port):
            n += 1
    return n


# Tried in order. The first that RUNS wins; "cant" only if none of them do.
_LISTEN_PROBES = (
    ["/usr/sbin/netstat", "-an", "-p", "tcp", "-f", "inet"],  # macOS, and
                                                  # install.sh's own argv
    ["ss", "-Hltn"],                              # Linux, modern
    ["netstat", "-ltn"],                          # Linux, older
)


def port_listeners(port):
    """LISTEN row count for `port`, or "cant" when NO instrument could run.

    The macOS argv is first and is byte-identical to install.sh's
    `_port_listeners` (install.sh:15303), so on the box the two ask the same
    question of the same tool. The others exist so this is measurable on the
    hosts our tests run on.

    MUST NEVER return 0 for a failed measurement. That is the false-clean
    this whole block exists to prevent.
    """
    for argv in _LISTEN_PROBES:
        try:
            out = subprocess.run(argv, capture_output=True, text=True)
        except OSError:
            continue                      # not installed here; try the next
        if out.returncode != 0:
            continue
        if not out.stdout.strip():
            # Ran cleanly and printed nothing. A machine with NO listening
            # sockets at all is possible but vanishingly rare, and an empty
            # read is the classic false zero, so do not count it as 0 --
            # fall through and let another instrument answer.
            continue
        return count_listen_rows(out.stdout, port)
    return "cant"


def port_is_held(port):
    """TWO instruments, and DISAGREEMENT IS NOT A COIN TOSS.

    🔴 THIS COST A WALK, AND THE HARNESS WAS THE DEFECT.
    Run 9 (2026-09-04) refused on "6333 8044 already held" SEVEN SECONDS
    after its own --reset ran `colima stop`. Nothing held them: netstat
    showed ZERO LISTEN rows on both, measured on the box minutes later.
    What the bare bind() hit was TIME_WAIT. Demonstrated on an ephemeral
    port, same machine class:
        netstat rows after close : 2, both TIME_WAIT, LISTEN rows 0
        bare bind()              : EADDRINUSE (errno 48)  -> reads "held"
        bind + SO_REUSEADDR      : succeeds               <- what a server does
    So the reset MANUFACTURED the conflict the next step refused on, and a
    real server would have bound the port without noticing.

    install.sh already knew this. Its `_check_port` (install.sh:15458)
    grades bind=held + 0 listeners as COULD-NOT-MEASURE, in its own words
    because "Docker sets SO_REUSEADDR and may well survive it, so calling
    this a collision would block a working install". This function is that
    same table, so the driver cannot be STRICTER than the preflight it
    claims to be predicting:

      bind   listeners   verdict   why
      free   0           free      both agree
      held   >=1         held      both agree: the real collision
      held   0           cant      TIME_WAIT or similar, NOT a collision
      free   >=1         cant      a listener our bind did not hit
      held   cant        held      bind DEMONSTRATED the failure
      cant   0           cant      no authoritative instrument ran
      cant   >=1         held      netstat alone; a listener is a listener
      free   cant        cant      only the weaker instrument spoke
    """
    bind = port_bind_probe(port)
    listeners = port_listeners(port)

    if bind == "free" and listeners == 0:
        return "free"
    if bind == "held" and listeners == "cant":
        return "held"
    if bind == "held" and listeners != "cant" and listeners != 0:
        return "held"
    if bind == "cant" and listeners != "cant" and listeners != 0:
        return "held"
    return "unmeasured"


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

    # ⏱ WAIT OUT A TRANSIENT BEFORE CALLING IT UNMEASURABLE.
    #
    # Without this, `--reset` is SELF-BLOCKING: the reset stops colima, its
    # forwarded sockets sit in TIME_WAIT for 2*MSL (30s on macOS), and the
    # preflight that runs seconds later can measure neither free nor held.
    # Refusing there is honest but useless -- the operator's only remedy is
    # to wait and re-run, which is exactly what this loop does for them.
    #
    # This is NOT a retry-until-green: a port that is genuinely HELD exits on
    # the FIRST pass and is never re-probed, so a real collision can never be
    # waited away. Only the third state gets a second chance, and after the
    # budget it is still CANNOT-RUN.
    deadline_s = float(os.environ.get("OSTLER_WALK_PORT_SETTLE_S", "45"))
    waited = 0.0
    while True:
        states = [(p, port_is_held(p)) for p in ports]
        held = [p for p, s in states if s == "held"]
        unmeasured = [p for p, s in states if s == "unmeasured"]
        if held or not unmeasured or waited >= deadline_s:
            break
        trace("port preflight: %s unmeasured after %.0fs, waiting (TIME_WAIT "
              "clears in ~30s on macOS)" % (" ".join(unmeasured), waited))
        time.sleep(5)
        waited += 5.0

    trace("port preflight over %d declared port(s) after %.0fs: %s" % (
        len(ports), waited,
        " ".join("%s=%s" % (p, s) for p, s in states)))
    if held:
        return CANNOT_RUN, (
            "%d of %d declared port(s) are already held: %s. install.sh's own "
            "preflight will refuse to start containers over them, so this walk "
            "would measure the refusal and not the product."
            % (len(held), len(ports), " ".join(held)))
    if unmeasured:
        return CANNOT_RUN, (
            "%d of %d declared port(s) could not be measured: %s. A port we "
            "could not measure has NOT been shown free -- and it has NOT "
            "been shown held either. The commonest cause is a service "
            "that stopped seconds ago: its TIME_WAIT sockets refuse a "
            "bare bind() while netstat shows no listener. Wait ~30s and "
            "re-run before treating this as a busy box."
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


DONE_LINE = re.compile(r"^.*#OSTLER\s+DONE\s+status=\w+.*$", re.M)
FAILED_STEPS_FIELD = re.compile(r"\bfailed_steps=(\d+)")
ERRORS_FIELD = re.compile(r"\berrors=(\d+)")

# 🔴 THE HARNESS'S OWN BLIND SPOT, NAMED SO IT CAN BE GRADED.
#
# macOS Automation (TCC) consent is a GUI dialog. A pty cannot click one, so
# an unattended walk PROVOKES a failure it can never resolve. install.sh says
# so in its own words -- this is the stable head of
# MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT in
# install.sh.strings.en-GB.sh. Matched on the head only, so a copy edit to
# the remediation half of that sentence cannot silently switch this off.
UNANSWERED_PROMPT = re.compile(r"No answer to the Messages permission prompt",
                               re.I)

# Steps that DEPEND on a TCC grant and so cannot be judged unattended.
# An ALLOWLIST of exactly the steps measured to have that dependency, never a
# wildcard. A failure in any other step in the same run still grades FAIL --
# that is the control on this whole idea, and there is a test arm for it.
TCC_DEPENDENT_STEPS = ("health_check",)

STEP_ERROR = re.compile(r"#OSTLER\s+STEP_END\s+id=(\S+)\s+status=error\b")


def failed_step_ids(body):
    """Every step id the log itself reports as status=error, in order."""
    return STEP_ERROR.findall(body)


def tally_from_marker(body):
    """(failed_steps, errors) off the LAST DONE line, or None if not stated.

    THE LAST one, not the first. A walk log can carry more than one terminal
    marker -- #642 is exactly that: a pgrep no-match fabricated an early DONE
    mid-install. Reading the first would grade the fabricated one, whose
    tally describes a run that had not happened yet.

    None means the marker did not carry the field. That is CANNOT-RUN at the
    call site, never a pass: an absent field is not a zero.
    """
    lines = DONE_LINE.findall(body)
    if not lines:
        return None
    last = lines[-1]
    failed = FAILED_STEPS_FIELD.search(last)
    if not failed:
        return None
    errors = ERRORS_FIELD.search(last)
    return int(failed.group(1)), int(errors.group(1)) if errors else 0


def adjudicate(log_path, rc, marker_channel_on):
    """FIX 2: rc is evidence, never the verdict. Require the marker.

    The cases, and why each lands where it does:

      marker ok + rc 0 + failed_steps=0  -> PASS. The only path to PASS.
      marker ok + rc 0 + failed_steps>0  -> FAIL. It reached the end AND told
                                       us N steps did not do their job. Two
                                       different questions, both answered.
      marker ok + rc 0 + no tally        -> CANNOT-RUN. "No step failed" was
                                       never established.
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
        if rc != 0:
            return (FAIL,
                    "install.sh emitted its completion marker but exited rc=%d" % rc,
                    "Something after the marker failed. The marker is not a "
                    "licence to ignore a non-zero exit.")

        # 🔴 status=ok IS NOT THE WHOLE MARKER, AND READING ONLY IT COST A RUN.
        #
        # Run 3 of the ttywalk (2026-09-03) ended with
        #     #OSTLER DONE status=ok failed_steps=1 errors=0
        # and this driver called it "WALK PASS". The failed step was
        # health_check, status=error rc=2 -- a real, measured product failure
        # sitting in the same line the driver had just graded green.
        #
        # The product is NOT lying here. gui_done answers two different
        # questions on purpose (#839): status=ok means "reached the end",
        # failed_steps=N means "N steps did not do their job". Collapsing them
        # is what hid a defect across 36 cuts. A driver that reads only the
        # first field re-commits the same collapse from the other side.
        #
        # A WALK EXISTS TO FIND DEFECTS. If a step failed, the walk did not
        # pass, whatever the install thought of its own completion.
        tally = tally_from_marker(body)
        if tally is None:
            return (CANNOT_RUN,
                    "the completion marker carried no step tally",
                    "status=ok says install.sh REACHED THE END. It does not "
                    "say every step did its job -- that is failed_steps=N, a "
                    "separate field answering a separate question (#839). "
                    "Without it, 'no step failed' was never established, and "
                    "reporting PASS would be asserting something unmeasured. "
                    "If ~/.walk-done-marker overrides the pattern, make it "
                    "match a marker that carries failed_steps.")
        failed, errors = tally
        if failed or errors:
            # 🔴 BUT FIRST: WAS THE FAILURE OURS?
            #
            # Measured on run 8 (2026-09-04). health_check went rc=2 and the
            # installer's own WARN said why:
            #     No answer to the Messages permission prompt, so we moved on
            #     iMessage Automation permission: probe inconclusive
            # That is a macOS AUTOMATION (TCC) dialog. A pty cannot click one.
            # The driver pressed ENTER, the grant never happened, and the step
            # failed BECAUSE THIS HARNESS IS BLIND, not because the product is
            # broken. Reporting that as a product FAIL is the accusation
            # version of a false green, and after a few of them nobody reads
            # the walk at all.
            #
            # ⚠️ IT IS *NOT* SUPPRESSED, AND THAT DISTINCTION IS THE WHOLE
            # POINT. A harness that dodges the failure it provoked is worse
            # than no harness. This returns CANNOT-RUN -- the third state --
            # names the prompt, and still prints the failed-step count so a
            # reader sees exactly what went red. Nobody can read CANNOT-RUN as
            # a pass; the estate's own vocabulary forbids it.
            #
            # Conservative on purpose: it fires on the PRESENCE of the
            # unanswered-prompt WARN, and it says it cannot attribute
            # per-step. A real product failure in the SAME run would also land
            # here -- which is why the verdict is "could not judge", not
            # "fine".
            bad = failed_step_ids(body)
            if (UNANSWERED_PROMPT.search(body)
                    and bad
                    and all(s in TCC_DEPENDENT_STEPS for s in bad)):
                return (CANNOT_RUN,
                        "%d step(s) failed -- %s -- and a macOS permission "
                        "prompt went unanswered by this harness"
                        % (failed, ", ".join(bad)),
                        "An unattended pty CANNOT grant Automation/TCC -- the "
                        "dialog needs a human. install.sh recorded the "
                        "unanswered prompt itself, so this run cannot "
                        "separate 'the product failed' from 'we could not "
                        "answer'. That is CANNOT-RUN, not a pass and not a "
                        "product failure. To judge these steps, walk the GUI "
                        "installer by hand, or grant Automation on the box "
                        "first and re-run.")
            return (FAIL,
                    "install.sh completed, but %d step(s) failed and it "
                    "recorded %d error(s)" % (failed, errors),
                    "status=ok is a claim about REACHING THE END, not about "
                    "the steps. Grep the log for `status=error` to see which. "
                    "This is a MEASURED product failure: the installer "
                    "counted it itself.")

        return (PASS,
                "install.sh emitted its completion marker, exited 0, and "
                "recorded 0 failed steps", "")

    seen = any_re.search(body) if any_re else None
    if seen:
        status = seen.group(1)
        # 🔴 A CANCEL THIS HARNESS CAUSED IS NOT A VERDICT ON THE BUILD.
        #
        # `status=cancelled` means somebody chose to stop, and in an
        # unattended walk that somebody is US. The answer table falls open to
        # the installer's own default on any prompt it does not recognise, and
        # at least one of those defaults -- the third-party consent, which
        # ships "[n]" -- CANCELS. So a stale table produces a clean, correct,
        # customer-facing cancellation that this function then reported as
        # FAIL.
        #
        # MEASURED 2026-09-04, walk 3 of v1.0.65: 24 answers, several marked
        # UNMATCHED, terminal marker `status=cancelled`, verdict FAIL. Nothing
        # about the build was wrong. The install did exactly what it was told.
        #
        # This module's own docstring already states the principle for the
        # marker-channel case: "Calling this FAIL would accuse the product of
        # our own blindness." It simply was not applied here.
        #
        # THE DISCRIMINATOR IS WHETHER WE ANSWERED EVERYTHING WE WERE ASKED.
        # Every prompt matched and it still cancelled -> a real finding, and
        # FAIL is right. Any prompt unmatched -> we cannot attribute the cancel
        # to the product, so CANNOT-RUN, and the fix is a table entry.
        if status == "cancelled":
            unmatched = _unmatched_prompts()
            if unmatched is None:
                return (CANNOT_RUN,
                        "install.sh was cancelled, and the Q&A record could not be read",
                        "Without it there is no way to tell a cancel WE caused from "
                        "one the product chose. Not knowing is not a failure.")
            if unmatched:
                return (CANNOT_RUN,
                        "install.sh was cancelled after %d prompt(s) this harness "
                        "could not answer" % len(unmatched),
                        "The answer table fell open to the installer's own default, "
                        "and at least one of those defaults cancels. That is a HARNESS "
                        "gap, not a build verdict. Add a table entry for: "
                        + "; ".join(unmatched[-3:]))
            return (FAIL,
                    "install.sh cancelled even though every prompt was answered "
                    "from the table (rc=%d)" % rc,
                    "No prompt was unmatched, so this cancellation is the product's "
                    "own decision and is a real finding.")
        return (FAIL,
                "install.sh terminated with status=%s (rc=%d)" % (status, rc),
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


def _read_stamped(path, what):
    """Print a number recorded by THIS run, or refuse.

    Shared by --read-result and --read-verdict so the staleness guard cannot
    drift between them. Absence is CANNOT-RUN, never zero: "no walk has run"
    and "the walk passed" are different findings that print identically if
    absence is allowed to mean success.
    """
    if not os.path.exists(path):
        return verdict(CANNOT_RUN,
                       "no %s at %s" % (what, path),
                       "Absent is not zero. Either no walk has run since the "
                       "last clear, or the run that was going to write this "
                       "one died before it finished.")
    try:
        started = os.path.getmtime(RUN_START)
    except OSError:
        return verdict(CANNOT_RUN,
                       "no run-start stamp at %s" % RUN_START,
                       "Without it the age of the %s cannot be adjudicated, "
                       "so it cannot be told apart from a leftover of an "
                       "earlier run." % what)
    written = os.path.getmtime(path)
    if written < started:
        return verdict(CANNOT_RUN,
                       "the %s is STALE -- it predates the run it would "
                       "describe" % what,
                       "mtime %s < run start %s. This is a previous run's "
                       "number; reporting it as this one's is how a crashed "
                       "walk gets recorded as a pass."
                       % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(written)),
                          time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))))
    with open(path) as fh:
        sys.stdout.write(fh.read().strip() + "\n")
    return PASS


def read_verdict(argv):
    """Print the ADJUDICATED verdict for this run.

    This is the number a caller should branch on. --read-result prints the raw
    exit status of install.sh, which is evidence and not a conclusion: a run
    that reaches the end with failed steps exits 0 and adjudicates to FAIL.
    """
    return _read_stamped(VERDICT_F, "walk verdict")


def main(argv):
    if "--read-verdict" in argv:
        return read_verdict(argv)
    if "--read-result" in argv:
        return read_result(argv)

    # FIX 1 (half a). Clear the previous verdict BEFORE anything can fail, and
    # stamp this run's start. Every exit below this line therefore leaves
    # either this run's result or no result at all -- never a stale one.
    try:
        if os.path.exists(RESULT):
            os.unlink(RESULT)
        if os.path.exists(VERDICT_F):
            os.unlink(VERDICT_F)
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
            shown = UNMATCHED_MARK
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

    # Written AFTER adjudication and BEFORE returning, so the file a caller
    # reads is the conclusion this run reached rather than the status the
    # process happened to exit with.
    try:
        with open(VERDICT_F, "w") as fh:
            fh.write(str(code) + "\n")
    except OSError:
        # A verdict that cannot be recorded must not be reported as a pass by
        # a later reader finding nothing. read_verdict treats absence as
        # CANNOT-RUN for exactly this case.
        pass

    return verdict(code, headline, detail)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
