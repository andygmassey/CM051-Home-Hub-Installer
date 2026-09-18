#!/usr/bin/env python3
"""The end-of-install panel must TELL the customer its rows are the transcript.

BOARD ROW 1589. Every service row on the success screen is built by grepping the
installer's own log: `ok(probe)` is `lines.contains { $0.localizedCaseInsensitiveContains(probe) }`
over `coordinator.logLines`. So the customer is shown what the installer BELIEVES
it did, not what is running. If a service died between the log line and the
panel, the panel still shows a tick and nothing on that screen can contradict the
transcript.

🔴 THE DEFECT THIS FILE EXISTS FOR IS NOT THE GREP. It is that the file SAID it
had been mitigated and it had not. The comment above `serviceChecks` read:

    3. THE LOG-DERIVED ROWS SAY SO. They are labelled as the installer's own
       report. A customer reading "as reported during install" knows what they
       are being told; a green tick implies a check that did not happen.

Measured: that phrase existed ONLY in that comment. Zero rendered strings said
anything of the kind, against a positive control of 18 `install_complete.*` keys
proving the search reaches the copy catalogue. A reviewer reading the file would
conclude the honest half was done.

Same shape as a vendored file whose comment said "rebind to oxblood" while the
value beside it was still the old red. A comment is a claim about code, and a
claim about code is exactly the thing a test is for.

SO THE DISCRIMINATOR IS RENDERED VERSUS MENTIONED, and it is the whole point: a
key named only inside a `//` comment is NOT rendered. That is asserted with a
control in both directions rather than assumed.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
VIEW = REPO / "gui" / "OstlerInstaller" / "Views" / "InstallCompleteView.swift"
COPY = REPO / "gui" / "OstlerInstaller" / "Resources" / "ViewCopy.json"

CAVEAT_KEY = "install_complete.hub_status_caveat"
CONTROL_KEY = "install_complete.hub_status_label"

PASS, FAIL = [], []


def ok(msg):
    PASS.append(msg)
    print("  [PASS] %s" % msg)


def bad(msg):
    FAIL.append(msg)
    print("  [FAIL] %s" % msg)


def cant(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    sys.exit(2)


def strip_comments(swift):
    """Swift source with // line comments and /* */ blocks removed.

    A key named in a comment is a CLAIM. A key named in code is a RENDER. This
    function is the difference between the two, so it is controlled below.
    """
    swift = re.sub(r"/\*.*?\*/", "", swift, flags=re.S)
    out = []
    for line in swift.split("\n"):
        # Not string-literal aware, deliberately: a `//` inside a string would
        # over-strip, which can only ever LOSE a render and produce a false
        # FAIL. The failure direction is the safe one.
        out.append(line.split("//", 1)[0])
    return "\n".join(out)


def renders(swift_no_comments, key):
    return bool(re.search(r'string\s*\(\s*for\s*:\s*"%s"' % re.escape(key), swift_no_comments))


if not VIEW.is_file():
    cant("%s is not a file" % VIEW)
if not COPY.is_file():
    cant("%s is not a file" % COPY)

try:
    copy = json.loads(COPY.read_text(encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    cant("the copy catalogue does not parse (%s), so nothing could be checked" % exc)

swift = VIEW.read_text(encoding="utf-8")
code = strip_comments(swift)

print("-- controls: rendered versus merely mentioned --")

# The comment stripper must actually strip, or every claim below is a render.
_probe = 'let x = 1 // string(for: "install_complete.not_real")'
if not renders(strip_comments(_probe), "install_complete.not_real"):
    ok("CONTROL: a key named only inside a // comment is NOT counted as rendered")
else:
    bad("CONTROL: the comment stripper does not strip, so a comment claiming a "
        "string would count as rendering it. That is the exact defect this file "
        "exists to catch, and it would pass.")

_probe2 = 'Text(ViewCopy.shared.string(for: "install_complete.not_real"))'
if renders(strip_comments(_probe2), "install_complete.not_real"):
    ok("CONTROL: a key named in CODE is counted as rendered")
else:
    bad("CONTROL: a real render was not recognised, so every absence below would "
        "be an artefact of the reader")

# POSITIVE CONTROL OF THE SAME SHAPE AS THE SUBJECT.
if renders(code, CONTROL_KEY):
    ok("CONTROL: %s is found rendered, so a miss below is real" % CONTROL_KEY)
else:
    bad("CONTROL: the known-rendered key %s was not found. The reader is broken "
        "and the finding below is noise." % CONTROL_KEY)

print("-- subject: the end-of-install panel --")

section, _, key = CAVEAT_KEY.partition(".")
declared = isinstance(copy.get(section), dict) and key in copy[section]
print("     EXAMINED: %d bytes of Swift, %d %s.* copy key(s)"
      % (len(swift), len(copy.get(section, {})), section))

if declared:
    ok("the caveat string is declared in the copy catalogue")
else:
    bad("%s is not declared in ViewCopy.json, so the panel cannot render it" % CAVEAT_KEY)

if renders(code, CAVEAT_KEY):
    ok("the caveat is RENDERED in the view, not merely described in a comment")
else:
    bad("%s is not rendered anywhere in %s outside a comment. The customer is "
        "shown six green ticks derived from the installer's own transcript with "
        "nothing on screen saying so, and a green tick implies a check that did "
        "not happen." % (CAVEAT_KEY, VIEW.name))

# The caveat has to SAY the thing. A string that renders but reassures is worse
# than none, because it looks like the mitigation while removing the doubt.
if declared:
    text = copy[section][key].lower()
    wanted = ("not a live check", "installer")
    missing = [w for w in wanted if w not in text]
    if not missing:
        ok("the caveat names both the installer and the absence of a live check")
    else:
        bad("the caveat is missing %s, so it does not tell the customer what the "
            "rows actually are" % " and ".join(repr(w) for w in missing))

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
