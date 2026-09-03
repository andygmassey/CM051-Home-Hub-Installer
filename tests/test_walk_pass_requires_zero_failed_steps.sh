#!/usr/bin/env bash
# A walk exists to FIND defects. It cannot report PASS over one it was told about.
#
# THE DEFECT, measured on ttywalk run 3 (2026-09-03). install.sh ended with
#
#     #OSTLER<TAB>DONE<TAB>status=ok<TAB>failed_steps=1<TAB>errors=0
#
# and the driver printed "WALK PASS: install.sh emitted its completion marker
# and exited 0". The failed step was health_check, status=error rc=2. A real,
# measured product failure was sitting in the very line that had just been
# graded green -- one field to the right of the one being read.
#
# 🔴 AND THE PRODUCT IS NOT LYING. gui_done answers TWO questions on purpose
# (#839): `status=ok` means REACHED THE END, `failed_steps=N` means N steps did
# not do their job. Collapsing them into one verdict is what hid a defect
# across 36 cuts. A driver that reads only the first field commits the same
# collapse from the other side -- and this time it is the instrument, which is
# worse, because the instrument is what we trust when nobody is watching.
#
# The three-state discipline applies to the tally itself: an ABSENT
# failed_steps is not a zero. It is CANNOT-RUN, because "no step failed" was
# never established.
#
# rc=2 from this file means the harness could not set itself up.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${OSTLER_WALK_DRIVER:-${REPO_ROOT}/scripts/walk_drive.py}"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }

[ -f "${DRIVER}" ] || cannot "driver-missing" "${DRIVER} not found -- nothing was checked."
command -v python3 >/dev/null 2>&1 || cannot "no-python3" "python3 is not on PATH."

STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

python3 - "${DRIVER}" "${STRINGS}" <<'PY'
import importlib.util, os, sys, tempfile

driver = sys.argv[1]
spec = importlib.util.spec_from_file_location("walk_drive_under_test", driver)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as exc:                                  # noqa: BLE001
    print("CANNOT-RUN [import]: %s could not be imported: %s" % (driver, exc),
          file=sys.stderr)
    raise SystemExit(2)

# PREMISE GUARD. Every arm below compares against these names; if the driver
# stopped exporting them, the comparisons would all be against AttributeError
# and the arms would report something other than what they measure.
for need in ("adjudicate", "PASS", "FAIL", "CANNOT_RUN",
             "UNANSWERED_PROMPT", "TCC_DEPENDENT_STEPS", "failed_step_ids"):
    if not hasattr(mod, need):
        print("CANNOT-RUN [premise]: the driver has no %r. Nothing was measured."
              % need, file=sys.stderr)
        raise SystemExit(2)

# PREMISE GUARD, the allowlist. Arms 7-10 expect health_check to be a step the
# harness admits it cannot judge. If it were dropped from the allowlist, those
# arms would still run and would measure a DIFFERENT rule than the one named.
if "health_check" not in mod.TCC_DEPENDENT_STEPS:
    print("CANNOT-RUN [premise]: health_check is not in TCC_DEPENDENT_STEPS, "
          "so arms 7-10 would measure something other than what they claim.",
          file=sys.stderr)
    raise SystemExit(2)

# 🔴 THE CROSS-FILE CONTRACT, and the whole reason this is a premise and not an
# arm. The driver's excuse fires on a sentence that INSTALL.SH OWNS. A copy
# edit to that string, in a repo where nothing links the two files, would
# silently switch the CANNOT-RUN rule off and every TCC-blocked walk would go
# back to reading as a product FAIL. So take the string from the strings file
# and prove the driver's pattern still matches the REAL text.
strings_path = sys.argv[2]
try:
    with open(strings_path, "r", encoding="utf-8", errors="replace") as fh:
        strings_body = fh.read()
except IOError as exc:
    print("CANNOT-RUN [premise]: %s is unreadable (%s), so the cross-file "
          "contract was not checked." % (strings_path, exc), file=sys.stderr)
    raise SystemExit(2)

KEY = "MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="
real_warn = None
for line in strings_body.splitlines():
    if line.startswith(KEY):
        real_warn = line[len(KEY):].strip().strip('"')
        break
if real_warn is None:
    print("CANNOT-RUN [premise]: %s does not define %s -- the string this whole "
          "rule keys off has moved or been renamed."
          % (strings_path, KEY.rstrip("=")), file=sys.stderr)
    raise SystemExit(2)
if not mod.UNANSWERED_PROMPT.search(real_warn):
    print("CANNOT-RUN [premise]: UNANSWERED_PROMPT does not match the CURRENT "
          "text of %s. The driver would grade every TCC-blocked walk as a "
          "product FAIL. Re-sync the pattern with the string."
          % KEY.rstrip("="), file=sys.stderr)
    raise SystemExit(2)

NAME = {mod.PASS: "PASS", mod.FAIL: "FAIL", mod.CANNOT_RUN: "CANNOT-RUN"}
TAB = "\t"


def step_error(step_id):
    return ("#OSTLER" + TAB + "STEP_END" + TAB + "id=" + step_id + TAB
            + "status=error" + TAB + "elapsed_s=171" + TAB + "rc=2\n")


def warn_line():
    """The installer's own words, taken from the strings file, not retyped."""
    return "#OSTLER" + TAB + "WARN" + TAB + "msg=" + real_warn + "\n"


def grade(body, rc=0, channel_on=True):
    fd, path = tempfile.mkstemp()
    with os.fdopen(fd, "w") as fh:
        fh.write(body)
    try:
        return mod.adjudicate(path, rc, channel_on)
    finally:
        os.unlink(path)


def marker(status="ok", failed=None, errors=None):
    line = "#OSTLER" + TAB + "DONE" + TAB + "status=" + status
    if failed is not None:
        line += TAB + "failed_steps=%d" % failed
    if errors is not None:
        line += TAB + "errors=%d" % errors
    return line + "\n"


# (label, log body, expected verdict, why this arm exists)
ARMS = [
    ("the run-3 shape",
     marker("ok", 1, 0),
     mod.FAIL,
     "status=ok with failed_steps=1 was reported as WALK PASS. THIS IS THE DEFECT."),

    ("a genuinely clean run",
     marker("ok", 0, 0),
     mod.PASS,
     "CONTROL. A tightening that also fails clean runs is a blanket refusal, "
     "not a predicate -- and it would make every future walk unreadable."),

    ("errors recorded, no failed step",
     marker("ok", 0, 2),
     mod.FAIL,
     "errors=N is the second half of the same tally and was equally unread."),

    ("marker with no tally at all",
     marker("ok"),
     mod.CANNOT_RUN,
     "An absent field is not a zero. 'No step failed' was never established, "
     "so PASS would assert something unmeasured."),

    ("a fabricated early DONE, then a clean one",
     marker("ok", 9, 9) + "...install continues...\n" + marker("ok", 0, 0),
     mod.PASS,
     "#642 fabricates a terminal DONE mid-install. The LAST marker describes "
     "the run that finished; the first describes one that had not happened."),

    ("install.sh said fail",
     marker("fail", 3, 0),
     mod.FAIL,
     "REGRESSION DIRECTION. The pre-existing status!=ok path must be untouched."),

    # ------------------------------------------------------------------
    # THE HARNESS'S OWN BLIND SPOT. Measured on run 8 (2026-09-04):
    # health_check went rc=2 because a macOS Automation dialog was never
    # answered, and a pty CANNOT answer one. Grading that as a product FAIL
    # is the accusation version of a false green: it is wrong, it is
    # permanent, and after a few of them nobody reads the walk at all.
    # ------------------------------------------------------------------
    ("TCC dialog nobody could answer",
     step_error("health_check") + warn_line() + marker("ok", 1, 0),
     mod.CANNOT_RUN,
     "THE DEFECT THIS PAIR EXISTS FOR. The only failed step depends on a "
     "grant no unattended run can give, and the installer said so itself. "
     "That is CANNOT-RUN: not a pass, and not the product's fault."),

    ("a product failure in the same run",
     step_error("wiki_compile") + warn_line() + marker("ok", 1, 0),
     mod.FAIL,
     "CONTROL, AND THE ONE THAT MATTERS MOST. The unanswered prompt must "
     "excuse ONLY the steps that depend on it. If the WARN alone were the "
     "trigger, one dialog would launder every other failure in the run."),

    ("health_check failed with no prompt involved",
     step_error("health_check") + marker("ok", 1, 0),
     mod.FAIL,
     "CONTROL. The excuse needs EVIDENCE, not just a step name on a list. "
     "health_check can fail for ordinary product reasons and must still "
     "grade FAIL when it does."),

    ("a tally we cannot attribute",
     warn_line() + marker("ok", 1, 0),
     mod.FAIL,
     "CONTROL. failed_steps=1 with no STEP_END to name it: we cannot show "
     "the failure was ours, so we do not get to claim it was. Refusing to "
     "excuse what you cannot attribute is the whole discipline."),
]

rc = 0
for label, body, expected, why in ARMS:
    got, headline, _ = grade(body)
    if got == expected:
        print("ok   %-42s -> %s" % (label, NAME[got]))
    else:
        rc = 1
        print("FAIL %-42s -> %s, expected %s"
              % (label, NAME[got], NAME[expected]))
        print("     %s" % why)
        print("     driver said: %s" % headline)

if rc == 0:
    print("PASS: tests/test_walk_pass_requires_zero_failed_steps.sh (%d arms)"
          % len(ARMS))
raise SystemExit(rc)
PY
