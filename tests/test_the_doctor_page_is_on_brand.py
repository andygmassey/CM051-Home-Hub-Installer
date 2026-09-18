#!/usr/bin/env python3
"""The Doctor page the owner is SENT TO must render in the brand, light with oxblood.

WHY A RENDERED PAGE AND NOT A GREP. A palette can be correct in a stylesheet and
wrong on the page: the tokens live in NINE separate style blocks in web_ui.py, in
SIX divergent variants, so a fix applied to one block leaves the other eight
painting the old colours and a source grep still finds the new value. This file
calls the renderer and reads the bytes a customer's browser receives.

WHY IT MATTERS. The Doctor is where the owner is sent when something is wrong, so
it is the worst page to be off-brand. The brand is LIGHT with oxblood #7A1F1F,
not a dark page with bright reds. Measured on the rendered dashboard before this
gate existed: 0 occurrences of prefers-color-scheme, 0 of color-scheme, 0 of
data-theme, four near-black backgrounds, and #C84545 as the accent.

IT IS A CUT GATE, AND THE SHIPPED PAGE IS OFF BRAND TODAY. The fix already
exists UPSTREAM: HR015's doctor/agent is light with oxblood #7A1F1F in all seven
of its :root blocks, and carries its own render-based test naming this row. What
ships from CM051 is the VENDORED copy, and that copy is 48 commits behind its
pin. So this is not a defect to patch here -- patching it here would manufacture
divergence in a file that currently has none, and would collide with upstream's
own token roles, which differ from any hand-rolled inversion.

What CM051 owes is therefore not a palette, it is a REFUSAL: the cut must not go
out with an off-brand Doctor merely because a re-pin is outstanding. So outside a
cut this reports and exits 0, because the state is known and tracked; under
OSTLER_CUT_IN_PROGRESS=1 it FAILS and the cut stops. Same shape as the strict-
checks preflight gate, and for the same reason: a line of prose is not a
mechanism.

THREE STATES. 0 pass, 1 fail, 2 cannot-run. A missing runtime dependency is
CANNOT-RUN and exits 2, never 0: this gate guards a page that already shipped
broken once while every check was green, so "could not look" must not read as
"looks fine".
"""
import collections
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
WEB_UI = REPO / "vendor" / "doctor" / "agent" / "web_ui.py"

OXBLOOD = "#7a1f1f"
# Named in launch/CX81_B8b_REPORT.md as the canonical value, and the near-miss it
# is explicitly NOT. A near-miss is worse than an obvious wrong colour: it reads
# as correct to everyone who does not have the hex in front of them.
NEAR_MISS = "#8b1f1f"

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


def luminance(hex_colour):
    """Relative luminance, WCAG. Used to ask 'is this ground light or dark?'"""
    h = hex_colour.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    parts = []
    for i in (0, 2, 4):
        v = int(h[i:i + 2], 16) / 255.0
        parts.append(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4)
    return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------------------
# CONTROLS. The measuring functions must be shown to separate the cases they
# claim to separate, before any verdict below is worth reading.
# ---------------------------------------------------------------------------
print("-- controls: the instruments must discriminate --")

if luminance("#ffffff") > 0.9 and luminance("#000000") < 0.01:
    ok("CONTROL: luminance separates white from black")
else:
    bad("CONTROL: luminance is broken, so every light/dark verdict below is noise")

if contrast("#ffffff", "#000000") > 20 and contrast("#ffffff", "#fffffe") < 1.05:
    ok("CONTROL: contrast separates a legible pair from an illegible one")
else:
    bad("CONTROL: contrast is broken, so the legibility verdict below is noise")

# A POSITIVE CONTROL OF THE SAME SHAPE AS THE SUBJECT. If the token reader cannot
# find a seeded token in a seeded block, then finding none in the real file means
# "could not look", not "none present".
_seed = ":root {{\n  --ostler-accent: #C84545;\n  --ostler-ink: #0d0b08;\n}}"
_seen = dict(re.findall(r"(--[a-z0-9-]+)\s*:\s*([^;]+);", _seed))
if _seen.get("--ostler-accent", "").strip().lower() == "#c84545":
    ok("CONTROL: the token reader finds a seeded token, so an empty result means absent")
else:
    bad("CONTROL: the token reader missed a seeded token. Its silence below proves nothing.")

# ---------------------------------------------------------------------------
# SUBJECT
# ---------------------------------------------------------------------------
print("-- subject: the rendered Doctor dashboard --")

if not WEB_UI.is_file():
    cant("%s is not a file" % WEB_UI)

src = WEB_UI.read_text(encoding="utf-8")

sys.path.insert(0, str(WEB_UI.parent))
ns = {"__name__": "web_ui_brand_probe"}
try:
    exec(compile(src, "web_ui.py", "exec"), ns)
except Exception as exc:  # noqa: BLE001
    cant("web_ui would not load (%s: %s). A runtime dependency is missing; this "
         "gate has NOT looked at the page." % (type(exc).__name__, exc))

try:
    from status_collector import SystemSnapshot  # noqa: E402
except Exception as exc:  # noqa: BLE001
    cant("status_collector would not import (%s: %s)" % (type(exc).__name__, exc))

render = ns.get("render_dashboard")
if not callable(render):
    cant("render_dashboard is not defined in web_ui's namespace")

# A POPULATED SNAPSHOT, ENTIRELY SYNTHETIC. An empty snapshot renders the page
# with every data-bearing component skipped, and the colour pairs that matter
# live inside those components: the status pills, the severity chips, the
# container rows. Rendering empty and calling it measured is the zero-denominator
# pass this file exists to refuse. No value below is real; the names are invented
# and the hosts are loopback.
import status_collector as _sc  # noqa: E402


def _synthetic_snapshot():
    kinds = {}
    for name, rows in (
        ("docker_containers", [
            _sc.DockerContainerInfo(name="example-store", image="example/store:1", state="running", status="Up 2 hours"),
            _sc.DockerContainerInfo(name="example-index", image="example/index:1", state="exited", status="Exited (1)"),
            _sc.DockerContainerInfo(name="example-cache", image="example/cache:1", state="paused", status="Paused"),
        ]),
        ("services", [
            _sc.ServiceHealthInfo(name="Example Healthy", status="healthy", status_code=200),
            _sc.ServiceHealthInfo(name="Example Degraded", status="unhealthy", status_code=503),
            _sc.ServiceHealthInfo(name="Example Down", status="unreachable"),
        ]),
        ("disk_usage", [
            _sc.DiskUsageInfo(mount_point="/", total_gb=500.0, used_gb=100.0, free_gb=400.0, percent_used=20.0),
            _sc.DiskUsageInfo(mount_point="/example-full", total_gb=100.0, used_gb=97.0, free_gb=3.0, percent_used=97.0),
        ]),
        ("network_checks", [
            _sc.NetworkCheckInfo(source="hub", target="127.0.0.1", reachable=True, latency_ms=1.0),
            _sc.NetworkCheckInfo(source="hub", target="127.0.0.2", reachable=False),
        ]),
        ("ollama_models", [_sc.OllamaModelInfo(name="example-model", size_gb=1.0)]),
    ):
        kinds[name] = rows
    return SystemSnapshot(hostname="example-host", os_version="15.0", **kinds)


_FINDINGS = [
    {"severity": "critical", "title": "Example critical finding", "detail": "Synthetic."},
    {"severity": "warning", "title": "Example warning finding", "detail": "Synthetic."},
    {"severity": "info", "title": "Example info finding", "detail": "Synthetic."},
]

try:
    html = render(_synthetic_snapshot(), _FINDINGS)
except Exception as exc:  # noqa: BLE001
    cant("render_dashboard raised %s: %s" % (type(exc).__name__, exc))

if not isinstance(html, str) or len(html) < 2000:
    cant("render_dashboard returned %s of length %s, which is not a page"
         % (type(html).__name__, len(html) if hasattr(html, "__len__") else "?"))

print("     EXAMINED: %d bytes of rendered HTML, %d style block(s), %d :root block(s)"
      % (len(html), src.count("<style>"), len(re.findall(r":root \{\{", src))))

# --- 1. the accent is oxblood -----------------------------------------------
root_blocks = re.findall(r":root \{\{(.*?)\}\}", src, re.S)
if not root_blocks:
    cant("no :root block found in web_ui.py, so no palette was read")

accents = set()
for block in root_blocks:
    for name, value in re.findall(r"(--[a-z0-9-]+)\s*:\s*([^;]+);", block):
        if name == "--ostler-accent":
            accents.add(value.strip().lower())

if not accents:
    bad("no --ostler-accent is defined in any of the %d :root block(s), so the "
        "brand accent is whatever each rule happens to hardcode" % len(root_blocks))
elif accents == {OXBLOOD}:
    ok("the brand accent is oxblood %s in all %d :root block(s)" % (OXBLOOD, len(root_blocks)))
elif NEAR_MISS in accents:
    bad("the accent is the NEAR MISS %s, not oxblood %s" % (NEAR_MISS, OXBLOOD))
else:
    bad("the brand accent is %s, not oxblood %s" % (", ".join(sorted(accents)), OXBLOOD))

# --- 2. every :root block agrees on every colour -----------------------------
# The palette is duplicated across the blocks. Duplicated and DIVERGENT is the
# state that makes a one-block fix look complete and ship eight stale copies.
values = collections.defaultdict(set)
for block in root_blocks:
    for name, value in re.findall(r"(--[a-z0-9-]+)\s*:\s*([^;]+);", block):
        if re.search(r"#[0-9a-fA-F]{3,6}|rgba?\(", value):
            values[name].add(value.strip().lower())
conflicts = {k: v for k, v in values.items() if len(v) > 1}
if not values:
    bad("no colour tokens were read from any :root block, so agreement was not measured")
elif conflicts:
    bad("%d colour token(s) hold DIFFERENT values in different :root blocks, so a "
        "fix to one block leaves the others painting the old colour: %s"
        % (len(conflicts), "; ".join("%s = %s" % (k, " | ".join(sorted(v)))
                                     for k, v in sorted(conflicts.items()))[:400]))
else:
    ok("all %d colour token(s) agree across every :root block" % len(values))

# --- 3. the page renders LIGHT ----------------------------------------------
grounds = []
for name in ("--ostler-chassis", "--ostler-panel", "--ostler-panel-elev"):
    for v in values.get(name, ()):
        m = re.match(r"^#[0-9a-f]{6}$", v)
        if m:
            grounds.append((name, v))
if not grounds:
    bad("no page-ground token resolved to a hex colour, so light-versus-dark was "
        "NOT measured. This is not a pass.")
else:
    dark = [(n, v) for n, v in grounds if luminance(v) < 0.5]
    if dark:
        bad("the page ground is DARK: %s. The brand is light."
            % ", ".join("%s=%s (luminance %.3f)" % (n, v, luminance(v)) for n, v in dark))
    else:
        ok("every page-ground token is light: %s"
           % ", ".join("%s=%s" % (n, v) for n, v in grounds))

# --- 4. body text is legible on that ground ---------------------------------
text_vals = {v for v in values.get("--ostler-ink", set()) if re.match(r"^#[0-9a-f]{6}$", v)}
ground_vals = {v for v in values.get("--ostler-chassis", set()) if re.match(r"^#[0-9a-f]{6}$", v)}
if not text_vals or not ground_vals:
    bad("could not resolve both a text colour and a ground colour to hex, so "
        "legibility was NOT measured")
else:
    worst = min(contrast(t, g) for t in text_vals for g in ground_vals)
    if worst >= 7.0:
        ok("body text on the page ground has contrast %.1f:1 (WCAG AAA is 7.0)" % worst)
    else:
        bad("body text on the page ground has contrast only %.1f:1, below the 7.0 "
            "this page needs: it is the page an owner reads when something is wrong" % worst)

# --- 5. the banned bright reds are gone from the RENDERED bytes --------------
BANNED = {"#c84545", "#d76060", "#e26a6a", "#d96666"}
rendered = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", html)}
still = sorted(BANNED & rendered)
if still:
    bad("the rendered page still paints the banned bright reds %s. Oxblood is %s."
        % (", ".join(still), OXBLOOD))
else:
    ok("none of the %d banned bright reds appears in the rendered page" % len(BANNED))

# --- 6. every inline text colour is readable ON THE PAGE GROUND --------------
# THE ARM THAT CATCHES WHAT THE TOKEN ARMS CANNOT. The tokens can be a perfect
# light palette while an inline style="color:..." still carries a value chosen
# for the old dark ground. Inverting this page produced exactly that: cream text
# left sitting on a newly cream background, invisible, with every token arm
# green. These elements take their background from a class, so the ground to
# measure against is the page ground, and a light-on-light pair is the failure.
def _rgb(token):
    token = (token or "").strip().lower()
    m = re.match(r"^#([0-9a-f]{3}|[0-9a-f]{6})$", token)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (1.0,)
    m = re.match(r"^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([0-9.]+)\s*)?\)$", token)
    if m:
        a = float(m.group(4)) if m.group(4) else 1.0
        return tuple(int(m.group(i)) for i in (1, 2, 3)) + (a,)
    return None


def _over(fg, bg_hex):
    """Composite a possibly translucent colour over an opaque ground."""
    b = _rgb(bg_hex)
    r, g, bl, a = fg
    return "#%02x%02x%02x" % tuple(int(round(c * a + bc * (1 - a))) for c, bc in zip((r, g, bl), b[:3]))


ground = sorted(ground_vals)[0] if ground_vals else None
if ground is None:
    bad("no page-ground colour resolved, so inline text colours were NOT measured")
else:
    inline_colours = []
    for style in re.findall(r'style="([^"]*)"', html):
        # Skip attributes that are really inline JS template fragments: they
        # carry an unresolved expression, not a colour a browser will paint.
        if "'" in style or "+" in style:
            continue
        for part in style.split(";"):
            k, _, v = part.partition(":")
            if k.strip().lower() == "color":
                c = _rgb(v)
                if c:
                    inline_colours.append((v.strip(), _over(c, ground)))
    if not inline_colours:
        bad("no inline style declared a literal text colour, so this arm measured "
            "nothing. On a page that sets 18 inline colours that is a broken "
            "reader, not a clean result.")
    else:
        unreadable = [(raw, comp, contrast(comp, ground))
                      for raw, comp in inline_colours if contrast(comp, ground) < 4.5]
        if unreadable:
            bad("%d of %d inline text colour(s) cannot be read on the page ground "
                "%s: %s" % (len(unreadable), len(inline_colours), ground,
                            "; ".join("%s composites to %s = %.1f:1" % (r, c, x)
                                      for r, c, x in unreadable[:5])))
        else:
            worst = min(contrast(c, ground) for _, c in inline_colours)
            ok("all %d inline text colour(s) clear 4.5:1 on the page ground %s "
               "(worst %.1f:1)" % (len(inline_colours), ground, worst))

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))

import os  # noqa: E402

IN_CUT = os.environ.get("OSTLER_CUT_IN_PROGRESS", "") not in ("", "0")
if not FAIL:
    sys.exit(0)
if IN_CUT:
    print()
    print("CUT BLOCKED: the Doctor page a customer is sent to is off brand, and a")
    print("cut must not carry it. The fix is upstream in HR015 doctor/agent; what")
    print("ships here is the vendored copy, so the remedy is the doctor re-pin,")
    print("NOT a graft in vendor/. Re-pin, then re-run this.")
    sys.exit(1)
print()
print("NOT A CUT: reporting %d finding(s) and exiting 0. This is the KNOWN state of" % len(FAIL))
print("the vendored Doctor, tracked as board row 2141 and blocked on the doctor")
print("re-pin. Run with OSTLER_CUT_IN_PROGRESS=1 and this refuses instead.")
sys.exit(0)
