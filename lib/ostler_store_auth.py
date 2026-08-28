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
except Exception:
    pass

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
except Exception:
    pass
