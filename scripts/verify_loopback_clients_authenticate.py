#!/usr/bin/env python3
"""Every shipped client that calls a gated loopback service must send credentials.

WHY THIS EXISTS. The front page rendered interest cards only for roughly two
dozen walks. "Needs you now" -- people waiting on you, commitments, drafts, prep
-- was simply absent. Measured on the v1.0.95 box: all three signal endpoints
returned 401 "missing or invalid service token"; the same three WITH the token
returned 200, and /api/v1/suggestions alone returned 3944 bytes. The data was
there the whole time and the compiler could not read it.

THE SHAPE, and it is why a static gate can catch it. Every other component
reaches the stores through ostler_store_auth, injected by a .pth into each
service's VIRTUALENV, which shims httpx and urllib alike. The editor is the only
component shipped WITHOUT a venv, so it is the only one outside that shim. Being
outside it is invisible at the call site: the code looks identical to code that
works.

AND THE FAILURE WAS SILENT BY CONSTRUCTION. signals._get_json returned None on
any error and read_signals turned None into "no live signals, never an error", so
a refusal and an idle service printed identically. The tick logged
"front-page: 12 cards (phase=steady)" throughout.

WHAT THIS ASSERTS. For each first-party source file that builds a request
against a gated loopback Ostler service, at least one of:
  * it sends a credential (Authorization / X-Ostler-Service / a token lookup), OR
  * it is covered by the auth shim, i.e. it ships INTO a venv that receives
    ostler_store_auth.pth, OR
  * every loopback URL it names is on the PUBLIC allowlist below.
Anything else is a client that will be refused in production and will very
likely say nothing about it.

🔴 THIS IS A STATIC GATE AND IT RUNS IN CI, DELIBERATELY. The runtime version --
call every endpoint on a walked box -- was tried first and was too noisy to
trust: GET against guessed ports cannot tell a missing route from a wrong verb,
and it reported the duplicates endpoint as broken when that endpoint demonstrably
works. A gate that produces a false finding teaches people to ignore it.
"""
import os
import re
import sys

# Never gated by the server, per ical-server.py:206-210. Liveness and
# counts-only surfaces that carry no PII and perform no writes.
PUBLIC = ("/health", "/api/v1/hydration/status", "/doctor/api/health")

# A loopback Ostler service behind the service-token gate.
GATED_HOSTS = re.compile(
    r"https?://(?:127\.0\.0\.1|localhost|\[::1\]):(8089|8090)")

# Evidence the call site presents a credential, in any of the shapes the
# server's own contract accepts (ical-server.py:211 names the env vars).
CREDENTIALLED = re.compile(
    r"Authorization|X-Ostler-Service|OSTLER_SERVICE_TOKEN|PWG_SERVICE_TOKEN"
    r"|service_token|_service_token|ostler_store_auth")

# Trees that ship INTO a venv and therefore receive ostler_store_auth.pth.
# Membership here is a claim about packaging, so it is asserted against the
# installer rather than trusted: see _venv_backed_is_real below.
VENV_BACKED = ("vendor/cm048_pipeline", "vendor/cm041", "vendor/ostler_fda",
               "vendor/doctor", "vendor/spoken_source")

# 🔴 A URL LITERAL IS NOT A CALL SITE. emit_frontpage.py names :8090 and then
# hands it to signals.fetch_signals, which does the actual fetching; flagging it
# is a FALSE FINDING, and a gate that produces those teaches people to ignore it
# (measured: it was the gate's first false positive, on its first run). So a
# file is only a client if it BUILDS a request of its own.
BUILDS_REQUEST = re.compile(
    # Deliberately wide. Review found three shapes the first version missed --
    # requests.Session().get, a bare urlopen, and http.client -- and each one
    # was a real unauthenticated client the gate called "not a client". A
    # detector that is too narrow does not under-report politely, it reports
    # CLEAN about code it never considered.
    r"urlopen\s*\(|urllib\.request\.Request|Request\s*\("
    r"|requests\.(?:get|post|put|delete|patch|head|request|Session)"
    r"|\.(?:get|post|put|delete|patch|head|request)\s*\(\s*[\"'f]?(?:https?://|url|base|endpoint)"
    r"|httpx\.(?:get|post|put|delete|patch|Client|AsyncClient|request)"
    r"|http\.client\.|HTTPConnection|HTTPSConnection"
    r"|\bfetch\s*\(|XMLHttpRequest|axios\.")

# DECLARED OPEN DEBT. Each entry is a client that IS refused today, recorded
# with its reason so the gate can land against real debt instead of being
# disabled. This is not an exemption list for convenience: an entry must name
# what is wrong and why it is not fixed in the same change, and the list must
# only ever shrink.
KNOWN_OPEN = {
    "vendor/cm052_ai_conversations/src/cm052/wire.py":
        "2026-09-13: posts to :8089 with no credential. MEASURED: :8089 answers "
        "401 'client bearer is not a paired token'; the route actually lives on "
        ":8090, which answers 400 'Missing transcript field' with the service "
        "token, so this is a wrong PORT as well as a missing credential. "
        "CM052_CM048_ENDPOINT is never set anywhere, so the wrong default always "
        "wins. Not fixed here because the fix belongs upstream in CM052 and the "
        "port change needs its owner; whether it is on the live path is also "
        "unproven, since the hourly agent runs the daemon's run-source aiconv "
        "rather than this CLI.",
}

SCAN_ROOTS = ("vendor",)
SCAN_EXT = (".py", ".js")


def _code_only(src, ext):
    """Source with comments and docstrings removed.

    🔴 THE FIRST VERSION SEARCHED THE WHOLE FILE FOR "Authorization", SO A
    COMMENT SAYING "# TODO: add Authorization" MADE AN UNAUTHENTICATED CLIENT
    PASS. Review demonstrated it with a working file. A gate whose evidence can
    be a comment is checking prose, not behaviour, and that is the exact defect
    class this gate exists to catch -- sitting inside the gate.
    """
    if ext == ".py":
        src = re.sub(r'(?s)""".*?"""|\'\'\'.*?\'\'\'', "", src)
        src = re.sub(r"(?m)#.*$", "", src)
    else:
        src = re.sub(r"(?s)/\*.*?\*/", "", src)
        src = re.sub(r"(?m)//.*$", "", src)
    return src


def _iter_sources(repo):
    for root in SCAN_ROOTS:
        base = os.path.join(repo, root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in ("node_modules", "__pycache__", ".venv",
                                        "tests", "test", "build")]
            for fn in filenames:
                if fn.endswith(SCAN_EXT):
                    yield os.path.join(dirpath, fn)


def _venv_for(repo, rel):
    """True only when install.sh builds a venv for THIS component.

    Review's finding: the old check asked whether "ostler_store_auth.pth"
    appeared anywhere in install.sh, then exempted any file under one of five
    path prefixes. That is an exemption granted by a tuple, not by packaging,
    and any new file dropped under those prefixes inherited it. The shim only
    reaches code that runs from a venv, so that is what gets asserted.
    """
    comp = rel.split(os.sep)[1] if os.sep in rel else rel
    try:
        with open(os.path.join(repo, "install.sh"), "r", encoding="utf-8",
                  errors="replace") as fh:
            sh = fh.read()
    except OSError:
        return False
    stem = comp.replace("_", "[-_]").replace("cm0", "cm0")
    return bool(re.search(r"%s[^\n]{0,200}\.venv|\.venv[^\n]{0,200}%s" % (stem, stem), sh))


def _venv_backed_is_real(repo):
    """A tree is only venv-backed if install.sh actually builds it one.

    Without this, the allowlist above is an unchecked assertion and the gate
    becomes a way to wave a component through by adding a string to a tuple.
    """
    try:
        with open(os.path.join(repo, "install.sh"), "r", encoding="utf-8",
                  errors="replace") as fh:
            sh = fh.read()
    except OSError:
        return None
    return "ostler_store_auth.pth" in sh


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "."
    shim_real = _venv_backed_is_real(repo)
    if shim_real is False:
        print("CANNOT-RUN: install.sh never writes ostler_store_auth.pth, so the "
              "venv-backed exemption below cannot be true. Re-derive the "
              "exemption before trusting this gate.", file=sys.stderr)
        return 3
    if shim_real is None:
        print("CANNOT-RUN: no readable install.sh at %s" % repo, file=sys.stderr)
        return 3

    offenders, examined, exempt_public, exempt_venv = [], 0, 0, 0
    delegated = 0
    known = []
    for path in _iter_sources(repo):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        code = _code_only(src, os.path.splitext(path)[1])
        if not GATED_HOSTS.search(code):
            continue
        if not BUILDS_REQUEST.search(code):
            delegated += 1
            continue
        examined += 1
        rel = os.path.relpath(path, repo)
        if any(rel.startswith(v) for v in VENV_BACKED) and _venv_for(repo, rel):
            exempt_venv += 1
            continue
        if CREDENTIALLED.search(code):
            continue
        # Only public paths named? Then being uncredentialled is correct.
        paths = re.findall(r"[\"'](/(?:api/v1|doctor|health)[a-z0-9/_.-]*)", code)
        # A path assembled at runtime is not a path this gate has read. Review
        # showed a file whose only literal route was /health while its real
        # call was built from os.environ.get(...) -- every literal was public
        # and the file sailed through. So the exemption requires that NOTHING
        # is assembled.
        assembles = re.search(r"(?:environ\.get|\+\s*[a-z_]+|format\(|f[\"'])[^\n]*"
                              r"(?:/api|url|endpoint)", code)
        if paths and not assembles and all(
                any(p.startswith(x) for x in PUBLIC) for p in paths):
            exempt_public += 1
            continue
        if rel in KNOWN_OPEN:
            known.append(rel)
            continue
        offenders.append((rel, sorted(set(paths))[:4]))

    print("EXAMINED: %d first-party source file(s) build a request against a "
          "gated loopback service (:8089/:8090)" % examined)
    print("  %d exempt: ship into a venv that receives ostler_store_auth.pth"
          % exempt_venv)
    print("  %d exempt: name only PUBLIC routes (%s)"
          % (exempt_public, ", ".join(PUBLIC)))
    print("  %d not a client: names a gated URL but builds no request of its own"
          % delegated)
    if examined == 0:
        print("VERDICT: CANNOT-RUN -- zero files matched, so this gate examined "
              "nothing. A pattern that finds no clients in a tree that has them "
              "is broken, not clean.", file=sys.stderr)
        return 3
    for rel in known:
        print("  KNOWN OPEN (declared, still refused): %s\n      %s"
              % (rel, KNOWN_OPEN[rel]))
    if offenders:
        print("\nVERDICT: FAIL -- %d client(s) call a gated service with no "
              "credential and no exemption. They will be refused in production, "
              "and the refusal is usually silent:" % len(offenders))
        for rel, paths in offenders:
            print("    %s  %s" % (rel, " ".join(paths) or "(paths not literal)"))
        return 1
    print("\nVERDICT: PASS -- every client of a gated loopback service either "
          "sends a credential, ships inside the auth shim, or names only public "
          "routes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
