#!/usr/bin/env python3
"""tests/test_launchagent_bootstrap_after_staging.py

THE INVARIANT
-------------
No LaunchAgent whose ProgramArguments[0] is the daemon binary inside
OstlerAssistant.app may be bootstrapped BEFORE that .app has been staged
on disk.

WHY IT IS AN ORDERING TEST AND NOT A GUARD TEST
-----------------------------------------------
Observed on a real install log: at step 19 of 39 the installer reached the
email-ingest LaunchAgent while
${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant did not
yet exist. vendor/email_ingest/INSTALL_SNIPPET.sh REFUSED to bootstrap and
said so, naming EX_CONFIG (78). The refusal was correct. The ordering that
made it necessary is the defect.

If an agent IS bootstrapped while its program is missing, launchd cannot
exec, records last-exit-code=78 (EX_CONFIG) and writes zero-byte .log/.err
because nothing ran. EX_CONFIG is not a retry: launchd parks the job, and
the 78 survives reboots and reinstalls until something calls
`launchctl kickstart -k`. It presents as silence, with a clean install log.

So the guards are load-bearing and stay. But a guard that fires on EVERY
install is the last line of defence being used as the first. This test
asserts the ordering itself, so the guards go back to never firing.

WHAT IT MEASURES
----------------
1. Derives the agent set from what the installer actually ships: heredoc
   plists inside install.sh, plus vendored plist templates carrying the
   OSTLER_ASSISTANT_BINARY placeholder. Derivation, not a hand list, is
   the only shape that catches agent number eleven.
2. Resolves EXECUTION order, not text order. A `launchctl bootstrap`
   written inside a shell function does not run where it is written; it
   runs at the function's first call site. Comparing raw line numbers
   would report a false PASS for every bootstrap that lives in a helper.
3. Compares each agent's effective bootstrap line against the effective
   line at which OstlerAssistant.app is staged.

THE CONTROLS, which are the point of the exercise
-------------------------------------------------
A checker that resolves nothing prints "0 violations" just as loudly as a
correct one. Both controls run on every invocation:

  * NEGATIVE control: a synthetic install.sh carrying a new app-binary
    agent bootstrapped BEFORE the staging anchor MUST be reported as a
    violation. If it is not, this file is measuring nothing and exits 2.
  * POSITIVE control: the same synthetic agent moved AFTER the staging
    anchor MUST come back clean, so the checker is not simply failing
    everything.

EXIT CODES
  0  invariant holds, and both controls behaved
  1  at least one agent is bootstrapped before the daemon is staged
  2  cannot run / the instrument failed its own controls
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO_ROOT / "install.sh"

# ProgramArguments[0] shapes that mean "the late-staged daemon binary".
#   * install.sh heredocs interpolate the app-bundle path directly;
#   * vendored plist templates carry the OSTLER_ASSISTANT_BINARY token that
#     _install_conversation_feed / the vendor snippets sed-render.
APP_BINARY_PA0 = re.compile(
    r"<string>\s*(?:\$\{OSTLER_DIR\}/OstlerAssistant\.app/Contents/MacOS/ostler-assistant"
    r"|OSTLER_ASSISTANT_BINARY)\s*</string>"
)

# The line at which the DMG-bundled daemon lands at ~/.ostler/OstlerAssistant.app.
# This is the primary customer path; the local-wrap and curl-recovery arms are
# the other limbs of the same if/elif chain, so they share its effective line.
STAGE_ANCHOR = re.compile(r'^\s*ditto\s+"\$ASSISTANT_BUNDLED_APP"\s+"\$ASSISTANT_APP_BUNDLE"\s*$')

FUNC_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{\s*$")
FUNC_END = re.compile(r"^\}\s*$")
HEREDOC_OPEN = re.compile(r'^\s*cat\s+>\s*"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"\s*<<')
LABEL_KEY = re.compile(r"<key>Label</key>")
STRING_VAL = re.compile(r"<string>(.*?)</string>")

# Agents whose plist is rendered by a VENDORED template rather than an
# install.sh heredoc. The vendored snippet owns the launchctl call, so the
# thing that orders it is the install.sh line that INVOKES the snippet.
# One row per label, with the reason the row exists.
VENDOR_TRIGGERS: dict[str, tuple[str, str]] = {
    "com.creativemachines.ostler.email-ingest": (
        r'bash\s+"\$EMAIL_INGEST_SNIPPET"',
        "vendor/email_ingest/INSTALL_SNIPPET.sh bootstraps; install.sh invokes it here",
    ),
    "com.creativemachines.ostler.whatsapp-bundle": (
        r"^\s*_install_conversation_feed\s+whatsapp\b",
        "shared _install_conversation_feed body bootstraps; this is its call site",
    ),
    "com.creativemachines.ostler.email-bundle": (
        r"^\s*_install_conversation_feed\s+email\b",
        "shared _install_conversation_feed body bootstraps; this is its call site",
    ),
    "com.creativemachines.ostler.spoken-bundle": (
        r"^\s*_install_conversation_feed\s+spoken\b",
        "shared _install_conversation_feed body bootstraps; this is its call site",
    ),
    "com.creativemachines.ostler.imessage-bundle": (
        r"^\s*_install_conversation_feed\s+imessage\b",
        "shared _install_conversation_feed body bootstraps; this is its call site",
    ),
}

# Helpers whose ENTIRE PURPOSE is the post-staging sweep. They are called
# from the success path of _finalise_daemon_staging, so resolving them would
# put them at the staging line itself. Excluded by name, and each exclusion
# is re-earned below: the body must carry the daemon-binary guard.
POST_STAGING_SWEEPS = {
    "_ostler_ensure_export_scan_bootstrap": r'-x\s+"\$_bin"',
    "_ostler_ensure_app_binary_agents_bootstrap": r'-x\s+"\$_bin"',
    "_ostler_start_assistant_daemon": r'ASSISTANT_BINARY_INSTALLED:-false\}"\s*==\s*true',
}

FAILED = 0
CANNOT_RUN = 0


def fail(msg: str) -> None:
    global FAILED
    print(f"FAIL: {msg}", file=sys.stderr)
    FAILED = 1


def cannot_run(msg: str) -> None:
    global CANNOT_RUN
    print(f"CANNOT RUN: {msg}", file=sys.stderr)
    CANNOT_RUN = 1


def ok(msg: str) -> None:
    print(f"PASS: {msg}")


# ---------------------------------------------------------------------------
# Execution-order resolution
# ---------------------------------------------------------------------------
def function_ranges(lines: list[str]) -> dict[str, tuple[int, int]]:
    """name -> (first_line, last_line), 1-based inclusive, column-0 defs only."""
    out: dict[str, tuple[int, int]] = {}
    i = 0
    while i < len(lines):
        m = FUNC_DEF.match(lines[i])
        if m:
            for j in range(i + 1, len(lines)):
                if FUNC_END.match(lines[j]):
                    out[m.group(1)] = (i + 1, j + 1)
                    i = j
                    break
        i += 1
    return out


def enclosing_function(funcs: dict[str, tuple[int, int]], line_no: int) -> str | None:
    best = None
    best_span = None
    for name, (s, e) in funcs.items():
        if s <= line_no <= e:
            span = e - s
            if best_span is None or span < best_span:
                best, best_span = name, span
    return best


def first_call_site(lines: list[str], funcs: dict[str, tuple[int, int]], name: str) -> int | None:
    """First line that INVOKES `name` from outside its own body."""
    s, e = funcs[name]
    pat = re.compile(r"(^|[\s;&|(])" + re.escape(name) + r"($|[\s;&|)])")
    for idx, ln in enumerate(lines, start=1):
        if s <= idx <= e:
            continue
        stripped = ln.strip()
        if stripped.startswith("#"):
            continue
        if pat.search(ln):
            return idx
    return None


def effective_line(lines: list[str], funcs: dict[str, tuple[int, int]], line_no: int) -> int | None:
    """Where line_no actually RUNS: hoist through enclosing function definitions."""
    seen: set[str] = set()
    cur = line_no
    while True:
        fn = enclosing_function(funcs, cur)
        if fn is None:
            return cur
        if fn in seen:
            return None  # recursive definition; refuse to guess
        seen.add(fn)
        call = first_call_site(lines, funcs, fn)
        if call is None:
            return None  # defined but never invoked
        cur = call


# ---------------------------------------------------------------------------
# Agent derivation
# ---------------------------------------------------------------------------
def heredoc_agents(lines: list[str]) -> dict[str, dict]:
    """Labels from install.sh heredoc plists whose PA[0] is the daemon binary."""
    agents: dict[str, dict] = {}
    for idx, ln in enumerate(lines, start=1):
        if not APP_BINARY_PA0.search(ln):
            continue
        label = None
        for j in range(idx - 1, max(idx - 60, 0), -1):
            if LABEL_KEY.search(lines[j - 1]):
                m = STRING_VAL.search(lines[j])
                if m:
                    label = m.group(1).strip()
                break
        if not label or not label.startswith("com."):
            continue
        var = None
        for j in range(idx - 1, max(idx - 80, 0), -1):
            m = HEREDOC_OPEN.match(lines[j - 1])
            if m:
                var = m.group(1)
                break
        agents[label] = {"pa0_line": idx, "plist_var": var, "source": "install.sh heredoc"}
    return agents


def vendor_agents() -> dict[str, dict]:
    """Labels from vendored plist templates carrying OSTLER_ASSISTANT_BINARY."""
    agents: dict[str, dict] = {}
    for p in sorted(REPO_ROOT.rglob("*.plist")):
        if ".git" in p.parts:
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if "OSTLER_ASSISTANT_BINARY" not in text:
            continue
        m = re.search(r"<key>Label</key>\s*<string>(.*?)</string>", text, re.S)
        if not m:
            continue
        agents[m.group(1).strip()] = {
            "pa0_line": None,
            "plist_var": None,
            "source": str(p.relative_to(REPO_ROOT)),
        }
    return agents


def bootstrap_line_for(lines: list[str], funcs: dict[str, tuple[int, int]], label: str, info: dict) -> int | None:
    """Raw install.sh line that causes this agent to be bootstrapped, or None."""
    if label in VENDOR_TRIGGERS:
        pat = re.compile(VENDOR_TRIGGERS[label][0])
        for idx, ln in enumerate(lines, start=1):
            if ln.strip().startswith("#"):
                continue
            if pat.search(ln):
                return idx
        return None

    var = info.get("plist_var")
    if not var:
        return None
    home_fn = enclosing_function(funcs, info["pa0_line"]) if info.get("pa0_line") else None
    pat = re.compile(r'launchctl\s+(?:bootstrap|load)\b.*"\$\{?' + re.escape(var) + r'\}?"')
    for idx, ln in enumerate(lines, start=1):
        if ln.strip().startswith("#"):
            continue
        if not pat.search(ln):
            continue
        if enclosing_function(funcs, idx) in POST_STAGING_SWEEPS:
            continue
        if home_fn is not None and enclosing_function(funcs, idx) != home_fn:
            continue
        return idx
    return None


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------
def check(lines: list[str], extra_agents: dict[str, dict] | None = None):
    """Returns (violations, examined_labels, uninstalled_labels, stage_eff)."""
    funcs = function_ranges(lines)
    agents = heredoc_agents(lines)
    if extra_agents:
        agents.update(extra_agents)

    stage_lines = [i for i, ln in enumerate(lines, start=1) if STAGE_ANCHOR.match(ln)]
    if len(stage_lines) != 1:
        return None, [], [], None
    stage_eff = effective_line(lines, funcs, stage_lines[0])
    if stage_eff is None:
        return None, [], [], None

    violations = []
    examined = []
    uninstalled = []
    for label in sorted(agents):
        raw = bootstrap_line_for(lines, funcs, label, agents[label])
        if raw is None:
            uninstalled.append(label)
            continue
        eff = effective_line(lines, funcs, raw)
        if eff is None:
            uninstalled.append(label)
            continue
        examined.append(label)
        if eff <= stage_eff:
            violations.append((label, raw, eff, stage_eff))
    return violations, examined, uninstalled, stage_eff


# ---------------------------------------------------------------------------
# Controls: prove the instrument fires before believing its answer
# ---------------------------------------------------------------------------
CONTROL_AGENT = """
CONTROL_PLIST="${HOME}/Library/LaunchAgents/com.ostler.canary-control.plist"
cat > "$CONTROL_PLIST" <<CANARYEOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.canary-control</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant</string>
        <string>run-source</string>
        <string>canary-control</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
CANARYEOF
launchctl bootstrap "gui/$(id -u)" "$CONTROL_PLIST" 2>/dev/null || true
""".strip().splitlines()


def run_controls(lines: list[str]) -> bool:
    funcs = function_ranges(lines)
    stage_lines = [i for i, ln in enumerate(lines, start=1) if STAGE_ANCHOR.match(ln)]
    if len(stage_lines) != 1:
        cannot_run("staging anchor did not match exactly once; controls cannot be placed")
        return False
    stage_eff = effective_line(lines, funcs, stage_lines[0])
    if stage_eff is None:
        cannot_run("staging anchor resolves to no call site; controls cannot be placed")
        return False

    # NEGATIVE: agent bootstrapped one line BEFORE the daemon is staged.
    bad = lines[: stage_eff - 1] + CONTROL_AGENT + lines[stage_eff - 1 :]
    v, ex, _, _ = check(bad)
    if v is None:
        cannot_run("negative control could not be evaluated")
        return False
    if not any(lbl == "com.ostler.canary-control" for lbl, *_ in v):
        cannot_run(
            "NEGATIVE CONTROL DID NOT FIRE: a synthetic agent bootstrapped before staging "
            "was reported clean. This file measures nothing."
        )
        return False
    ok("negative control fired (synthetic pre-staging agent reported as a violation)")

    # POSITIVE: the same agent, after the daemon is staged.
    good = lines[:stage_eff] + CONTROL_AGENT + lines[stage_eff:]
    v2, _, _, _ = check(good)
    if v2 is None:
        cannot_run("positive control could not be evaluated")
        return False
    if any(lbl == "com.ostler.canary-control" for lbl, *_ in v2):
        cannot_run(
            "POSITIVE CONTROL FAILED: a synthetic agent bootstrapped AFTER staging was "
            "reported as a violation. The checker fails everything."
        )
        return False
    ok("positive control clean (synthetic post-staging agent reported as safe)")
    return True


def main() -> int:
    if not INSTALL_SH.is_file():
        cannot_run(f"install.sh not found at {INSTALL_SH}")
        return 2
    lines = INSTALL_SH.read_text(encoding="utf-8", errors="replace").splitlines()

    if not run_controls(lines):
        return 2

    funcs = function_ranges(lines)
    derived = heredoc_agents(lines)
    derived.update(vendor_agents())
    if len(derived) < 8:
        cannot_run(
            f"derived only {len(derived)} app-binary agents; the shipped set is larger. "
            "The derivation is broken, and a short list reads as a clean run."
        )
        return 2
    ok(f"derived {len(derived)} LaunchAgents whose ProgramArguments[0] is the daemon binary")

    # Every vendored-template agent needs a trigger row, or it is invisible here.
    for label, info in sorted(derived.items()):
        if info["source"] == "install.sh heredoc":
            continue
        if label not in VENDOR_TRIGGERS and not re.search(
            r'rm -f "\$\{HOME\}/Library/LaunchAgents/\$\{_imb_label\}\.plist"', "\n".join(lines)
        ):
            fail(f"{label} is rendered from {info['source']} but has no VENDOR_TRIGGERS row")

    # The sweeps are excluded by name; re-earn each exclusion.
    for name, guard in POST_STAGING_SWEEPS.items():
        if name not in funcs:
            fail(f"{name} is in POST_STAGING_SWEEPS but is not defined in install.sh")
            continue
        s, e = funcs[name]
        body = "\n".join(lines[s - 1 : e])
        if not re.search(guard, body):
            fail(f"{name} is excluded as a post-staging sweep but its body lacks the guard {guard!r}")
    if not FAILED:
        ok("every post-staging-sweep exclusion still carries its daemon-binary guard")

    violations, examined, uninstalled, stage_eff = check(lines, derived)
    if violations is None:
        cannot_run("could not resolve the daemon staging line in install.sh")
        return 2

    print("")
    print(f"EXAMINED: {len(examined)} bootstrapped agent(s); daemon staged at effective line {stage_eff}")
    for label in examined:
        print(f"  checked  {label}")
    for label in uninstalled:
        print(f"  skipped  {label} (no bootstrap reachable in install.sh -- not installed)")
    if not examined:
        cannot_run("zero agents examined; 0 violations over 0 items is not a pass")
        return 2
    print("")

    for label, raw, eff, se in violations:
        fail(
            f"{label} is bootstrapped at install.sh:{raw} (effective line {eff}), "
            f"BEFORE OstlerAssistant.app is staged at effective line {se}. "
            "launchd answers EX_CONFIG (78) and parks the job permanently."
        )

    if CANNOT_RUN:
        return 2
    if FAILED:
        print("", file=sys.stderr)
        print(
            "test_launchagent_bootstrap_after_staging: FAILED -- "
            f"{len(violations)} of {len(examined)} bootstrapped agents run before the daemon is staged.",
            file=sys.stderr,
        )
        return 1
    ok(f"all {len(examined)} bootstrapped agents run after the daemon is staged")
    print("test_launchagent_bootstrap_after_staging: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
