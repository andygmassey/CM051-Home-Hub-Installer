"""Ostler store-auth shim (#550).

Attaches a per-destination credential to loopback store traffic without
editing any call site. Each store gets its OWN header, prefix and secret;
a credential for one store is never sent to another, nor to anything else.

No secret -> no header -> the store 401s. A loud broken feature, never a
silent open port.
"""
import os

_ALLOWED_HOSTS = {"localhost", "127.0.0.1", "::1"}

# port -> (header, value prefix, env var, secrets filename)
_ROUTES = {
    int(os.environ.get("OSTLER_QDRANT_PORT", "6333")):
        ("api-key", "", "QDRANT_API_KEY", "qdrant_api_key"),
    int(os.environ.get("OSTLER_OXIGRAPH_PORT", "7878")):
        ("Authorization", "Bearer ", "OXIGRAPH_TOKEN", "oxigraph_token"),
}

_SECRETS_DIR = os.environ.get(
    "OSTLER_SECRETS_DIR", os.path.expanduser("~/.ostler/secrets"))
_CACHE = {}


def _secret(env_var, filename):
    """env first, then the 0600 secrets file. Memoised once non-empty so a
    service started before install.sh seeds the secret self-heals."""
    if _CACHE.get(filename):
        return _CACHE[filename]
    v = os.environ.get(env_var) or ""
    if not v:
        try:
            with open(os.path.join(_SECRETS_DIR, filename), encoding="utf-8") as fh:
                v = fh.read().strip()
        except Exception:
            v = ""
    if v:
        _CACHE[filename] = v
    return v


def _credential_for(host, port):
    """-> (header_name, header_value) or None. Destination-scoped."""
    if host not in _ALLOWED_HOSTS:
        return None
    route = _ROUTES.get(port)
    if not route:
        return None
    header, prefix, env_var, filename = route
    val = _secret(env_var, filename)
    if not val:
        return None
    return header, prefix + val


def _port_of(scheme, port):
    return port or (443 if scheme == "https" else 80)


# ---- failure breadcrumb (#550, @TNM 2026-08-28) --------------------------
#
# Every arm below swallows its exception, and it MUST: this module is imported
# by a .pth before user code, so raising here would break every interpreter in
# the venv. But SWALLOW WITHOUT RECORDING means a broken shim is undetectable
# on a customer box -- the process runs, the calls go out bare, and nothing
# anywhere says so.
#
# 📌 That is the exact defect this shim was written to fix, one layer up: the
# seeder's own ok() message made "copied but never imported" read as finished.
# A silent failure arm would reproduce it inside the fix.
#
# Records FAILURE ONLY. Success is the common path and gets no I/O -- a
# breadcrumb per arm per process would be thousands of writes a day to say
# "fine". The rare case is the one nobody can currently see.
#
# NEVER records a credential, only WHICH arm failed and why. The log sits
# beside the secrets dir (so it follows a non-default OSTLER_DIR) at 0600, and
# every step is itself wrapped: a shim that crashed while reporting a crash
# would be worse than the silence it replaces.
STATUS = {"httpx": "not-attempted", "urllib": "not-attempted"}


def _record(arm, exc):
    """Note that an arm failed. Cannot raise, by construction."""
    STATUS[arm] = "FAILED: %s: %s" % (type(exc).__name__, exc)
    try:
        d = os.path.join(os.path.dirname(_SECRETS_DIR.rstrip(os.sep)), "logs")
        os.makedirs(d, exist_ok=True)
        fd = os.open(os.path.join(d, "store-auth-shim.log"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            # One line, one write: O_APPEND makes a short write atomic, so
            # concurrent interpreters cannot interleave halves of a line.
            os.write(fd, ("pid=%d arm=%s %s\n"
                          % (os.getpid(), arm, STATUS[arm])).encode(
                              "utf-8", "replace"))
        finally:
            os.close(fd)
    except Exception:
        # Disk full, read-only home, secrets dir absent. STATUS is still set,
        # so an in-process reader (the Doctor imports this module) can report
        # it even when the durable breadcrumb could not be written.
        pass


# ---- httpx: qdrant_client SDK + doctor + pwg_ingest + 6 others ----
try:
    import httpx

    def _wrap(orig):
        def send(self, request, *a, **kw):
            u = request.url
            cred = _credential_for(u.host, _port_of(u.scheme, u.port))
            if cred:
                request.headers.setdefault(cred[0], cred[1])
            return orig(self, request, *a, **kw)
        send._ostler_shim = True
        return send

    def _wrap_async(orig):
        async def send(self, request, *a, **kw):
            u = request.url
            cred = _credential_for(u.host, _port_of(u.scheme, u.port))
            if cred:
                request.headers.setdefault(cred[0], cred[1])
            return await orig(self, request, *a, **kw)
        send._ostler_shim = True
        return send

    if not getattr(httpx.Client.send, "_ostler_shim", False):
        httpx.Client.send = _wrap(httpx.Client.send)
    if not getattr(httpx.AsyncClient.send, "_ostler_shim", False):
        httpx.AsyncClient.send = _wrap_async(httpx.AsyncClient.send)
    STATUS["httpx"] = "patched"
except Exception as _e:
    _record("httpx", _e)

# ---- urllib.request: ical-server + hygiene + repair scripts ----
try:
    import urllib.request as _ur
    from urllib.parse import urlparse as _up

    if not getattr(_ur.urlopen, "_ostler_shim", False):
        _orig = _ur.urlopen

        def urlopen(url, *a, **kw):
            target = url.full_url if hasattr(url, "full_url") else url
            p = _up(target)
            cred = _credential_for(p.hostname, _port_of(p.scheme, p.port))
            if cred:
                if hasattr(url, "add_header"):
                    url.add_header(cred[0], cred[1])
                else:
                    url = _ur.Request(target, headers={cred[0]: cred[1]})
            return _orig(url, *a, **kw)

        urlopen._ostler_shim = True
        _ur.urlopen = urlopen
    STATUS["urllib"] = "patched"
except Exception as _e:
    _record("urllib", _e)
