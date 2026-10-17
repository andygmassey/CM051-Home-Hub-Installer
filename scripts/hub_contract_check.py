"""Reference checker for hub_contract.yaml. Vendored into every client repo.

A client contract test builds a request through the client's REAL request
builder, captures it (method, url, headers, body), and hands it here:

    c = HubContract.load("contract/hub_contract.yaml")      # verifies the sha pin
    violations = c.check_call({
        "id": "wire.post",
        "method": "POST",
        "url": "http://127.0.0.1:8090/api/v1/conversation/process",
        "headers": {"Authorization": "Bearer x"},
        "token_source": "service_token",     # which credential the client sends
        "body_bytes": 1200,                  # captured size; None = unbounded
        "body_keys": ["transcript", "metadata"],
        "reads": ["job_id"],                 # response fields the client parses
    })

check_call returns (violations, notes). No violations is a pass. Each violation is (code, message). The codes:

    ROUTE_MISSING          no route with this path on any listener
    PORT_MISMATCH          path exists, but not on the port the client dials
    METHOD_MISMATCH        path+port exist, but not for this method
    AUTH_MISSING           route needs a credential the request does not carry
    AUTH_WRONG_CREDENTIAL  the client sends a credential the route does not accept
    BODY_TOO_LARGE         captured body exceeds the route's body limit
    BODY_UNBOUNDED         client can send an unbounded body to a limited route
    REQUEST_FIELD_MISSING  body lacks a field the server requires
    RESPONSE_FIELD_ABSENT  client reads a field the server never returns

`notes` (not violations) list what could not be checked, e.g. response fields
the generator could not derive. A check that could not measure is reported, not
passed silently.

Stdlib only. Python 3.8+.
"""
import hashlib
import json
import re
from urllib.parse import urlsplit

TOKEN_TO_SCHEME = {
    "device_token": "device_bearer",
    "service_token": "service_token",
    "extension_token": "extension_token",
    "oxigraph_token": "store_bearer",
    "qdrant_key": "qdrant_api_key",
    "admin_token": "admin_token",
    "none": "none",
}



def _tpl_regex(path):
    out, i = "", 0
    for part in re.split(r"(\{[^}]*\})", path):
        if part.startswith("{"):
            name = part[1:-1]
            out += ".+" if name in ("rest", "any") else "[^/]+"
        else:
            out += re.escape(part)
    return re.compile("^" + out + "$")


def _specificity(path):
    return (path.count("{"), -len(path))


class HubContract:
    def __init__(self, data):
        self.data = data
        self.routes = data["routes"]
        for r in self.routes:
            r["_re"] = _tpl_regex(r["path"])

    @classmethod
    def load(cls, path, pin_path=None):
        """Load and verify the vendored copy against its pin. Raises on mismatch."""
        with open(path, "rb") as f:
            raw = f.read()
        pin_path = pin_path or path.rsplit("/", 1)[0] + "/hub_contract.pin.json"
        with open(pin_path) as f:
            pin = json.load(f)
        got = hashlib.sha256(raw).hexdigest()
        if got != pin["contract_sha256"]:
            raise AssertionError(
                "vendored hub_contract.yaml (%s) does not match its pin (%s). "
                "Re-vendor with CM051 scripts/pin_hub_contract.py; never edit the copy." %
                (got[:12], pin["contract_sha256"][:12]))
        return cls(json.loads(raw))

    def candidates(self, url_path):
        return [r for r in self.routes if r["_re"].match(url_path)]

    def match(self, method, url):
        """Best route for a concrete call, or None."""
        u = urlsplit(url)
        port = u.port or (443 if u.scheme in ("https", "wss") else 80)
        hits = [r for r in self.candidates(u.path or "/")
                if port in r["ports"] and r["method"] == method.upper()]
        return sorted(hits, key=lambda r: _specificity(r["path"]))[0] if hits else None

    def check_call(self, call):
        v, notes = [], []
        method = call["method"].upper()
        u = urlsplit(call["url"])
        port = u.port or (443 if u.scheme in ("https", "wss") else 80)
        path = u.path or "/"
        route = self.match(method, call["url"])
        if route is None:
            cands = [r for r in self.candidates(path) if r["path"] != "/{any}"]
            if not cands:
                v.append(("ROUTE_MISSING", "%s %s: no server route has this path on any listener" % (method, path)))
            elif not any(port in r["ports"] for r in cands):
                v.append(("PORT_MISMATCH", "%s %s: served on port(s) %s, client dials %d" %
                          (method, path, sorted({p for r in cands for p in r["ports"]}), port)))
            else:
                v.append(("METHOD_MISMATCH", "%s %s:%d: server offers %s here" %
                          (method, path, port, sorted({r["method"] for r in cands if port in r["ports"]}))))
            return v, notes
        h = {k.lower(): str(val) for k, val in (call.get("headers") or {}).items()}
        src = call.get("token_source", "none")
        scheme = TOKEN_TO_SCHEME.get(src)
        allowed = route["auth"]
        if scheme is None:
            raise ValueError("unknown token_source %r" % src)
        if "none" not in allowed and "handler_defined" not in allowed:
            bearer = h.get("authorization", "")
            has_bearer = bearer.lower().startswith("bearer ") and bearer[7:].strip() != ""
            has_service = h.get("x-ostler-service", "").strip() != ""
            has_qkey = h.get("api-key", "").strip() != ""
            if "qdrant_api_key" in allowed:
                has = has_qkey
            elif "service_token" in allowed:
                has = has_bearer or has_service
            else:
                has = has_bearer
            if not has:
                v.append(("AUTH_MISSING", "%s %s needs %s, request carries no usable credential header" %
                          (method, path, "/".join(allowed))))
            elif scheme not in allowed:
                v.append(("AUTH_WRONG_CREDENTIAL", "%s %s accepts %s, client sends %s" %
                          (method, path, "/".join(allowed), src)))
        elif "handler_defined" in allowed:
            notes.append("auth for %s %s is handler-defined; not statically checkable" % (method, path))
        limit = route.get("body_limit_bytes")
        if method != "GET" and limit is not None and "body_bytes" in call:
            if call["body_bytes"] is None:
                v.append(("BODY_UNBOUNDED", "%s %s: server limit is %d bytes, client body has no bound" %
                          (method, path, limit)))
            elif call["body_bytes"] > limit:
                v.append(("BODY_TOO_LARGE", "%s %s: body %d bytes > server limit %d" %
                          (method, path, call["body_bytes"], limit)))
        if call.get("body_keys") is not None:
            missing = [k for k in route.get("request_required", []) if k not in call["body_keys"]]
            if missing:
                v.append(("REQUEST_FIELD_MISSING", "%s %s: server requires %s" % (method, path, missing)))
        reads = call.get("reads") or []
        if reads:
            have = route.get("response_fields", [])
            if not have:
                notes.append("%s %s: server response fields not derivable; %s unchecked" % (method, path, reads))
            else:
                absent = [f for f in reads if f not in have]
                if absent:
                    v.append(("RESPONSE_FIELD_ABSENT", "%s %s: client reads %s, server returns %s" %
                              (method, path, absent, have)))
        return v, notes
