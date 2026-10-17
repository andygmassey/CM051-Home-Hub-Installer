#!/usr/bin/env python3
"""Generate hub_contract.yaml from the SERVER code. Never edit the output by hand.

Usage:
    scripts/gen_hub_contract.py [--gateway-src DIR] [--out FILE] [--check]

    --gateway-src  ostler-assistant checkout (default: $OSTLER_ASSISTANT_DIR,
                   then ../ostler-assistant). The gateway is a separate repo,
                   so its routes are read from lib.rs there.
    --check        regenerate in memory and exit 1 if --out differs (CI).

Exit: 0 ok / 1 stale / 2 could not run (a source is missing or unparsable).
"Nothing changed" and "I could not read the sources" must never print the same.

Sources parsed (every one is recorded with its sha256 in the output):
  ical-server   vendor/cm041/assistant_api/ical-server.py   (AST: do_GET / do_POST)
  doctor        vendor/doctor/agent/web_ui.py + proxy.py    (AST: @app.<verb>)
  install.sh    DOCTOR_PROXY_PATHS, ports, store-proxy nginx conf
  gateway       crates/zeroclaw-gateway/src/{lib,api_auth,ws}.rs (ostler-assistant)

The file is written as JSON, which is valid YAML 1.2, so Swift, JS and Python
clients can all read it with their standard JSON parser and no YAML library.
"""
import argparse
import ast
import hashlib
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICAL = "vendor/cm041/assistant_api/ical-server.py"
DOCTOR = "vendor/doctor/agent/web_ui.py"
PROXY = "vendor/doctor/agent/proxy.py"
INSTALL = "install.sh"
DEFAULT_OUT = "vendor/cm041/assistant_api/hub_contract.yaml"
ALL_METHODS = ["DELETE", "GET", "PATCH", "POST", "PUT"]


class CannotRun(Exception):
    pass


def read(rel, base=REPO):
    p = os.path.join(base, rel)
    if not os.path.isfile(p):
        raise CannotRun("missing source: %s" % p)
    with open(p, encoding="utf-8") as f:
        return f.read()


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def norm(path):
    """Placeholder-insensitive form used to join routes across listeners."""
    return re.sub(r"\{[^}]*\}", "{}", path)


# ───────────────────────── ical-server (AST) ─────────────────────────

def _is_path(node):
    if isinstance(node, ast.Attribute) and node.attr == "path":
        return True
    return isinstance(node, ast.Name) and node.id == "path"


def _path_tests(test):
    """Yield path templates from an If test, or []."""
    if isinstance(test, ast.Compare) and _is_path(test.left) and len(test.ops) == 1:
        c = test.comparators[0]
        if isinstance(test.ops[0], ast.Eq) and isinstance(c, ast.Constant) and isinstance(c.value, str):
            return [c.value]
        if isinstance(test.ops[0], ast.In) and isinstance(c, (ast.Tuple, ast.List, ast.Set)):
            return [e.value for e in c.elts if isinstance(e, ast.Constant)]
    if isinstance(test, ast.Call) and isinstance(test.func, ast.Attribute) \
            and test.func.attr == "startswith" and _is_path(test.func.value) \
            and test.args and isinstance(test.args[0], ast.Constant):
        pre = test.args[0].value
        return [pre + "{rest}"] if pre.endswith("/") else [pre, pre + "/{rest}"]
    if isinstance(test, ast.BoolOp) and isinstance(test.op, ast.And):
        pre = suf = None
        for v in test.values:
            if isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and _is_path(v.func.value) \
                    and v.args and isinstance(v.args[0], ast.Constant):
                if v.func.attr == "startswith":
                    pre = v.args[0].value
                elif v.func.attr == "endswith":
                    suf = v.args[0].value
        if pre and suf:
            return [pre + "{slug}" + suf]
    return []


def _str_keys_of_dicts(node):
    """Top-level string keys of a dict literal (nested dicts are NOT descended)."""
    keys = set()
    if isinstance(node, ast.Dict):
        for k in node.keys:
            if isinstance(k, ast.Constant) and isinstance(k.value, str):
                keys.add(k.value)
    elif isinstance(node, ast.Call) and node.args:
        # JSONResponse({...}, status_code=...) / dict(...)-style wrappers
        keys |= _str_keys_of_dicts(node.args[0])
    return keys


def _function_index(tree):
    return {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}


def _returned_keys(fn):
    """String keys of dict literals that reach a `return` (directly or via a local)."""
    keys = set()
    assigned = {}
    for n in ast.walk(fn):
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            assigned.setdefault(n.targets[0].id, []).append(n.value)
    for n in ast.walk(fn):
        if isinstance(n, ast.Return) and n.value is not None:
            vals = n.value.elts if isinstance(n.value, ast.Tuple) else [n.value]
            for v in vals:
                keys |= _str_keys_of_dicts(v)
                if isinstance(v, ast.Name):
                    for a in assigned.get(v.id, []):
                        keys |= _str_keys_of_dicts(a)
    # `result["k"] = ...` style additions on a returned local
    returned = set()
    for n in ast.walk(fn):
        if isinstance(n, ast.Return) and n.value is not None:
            for v in (n.value.elts if isinstance(n.value, ast.Tuple) else [n.value]):
                if isinstance(v, ast.Name):
                    returned.add(v.id)
    for n in ast.walk(fn):
        if isinstance(n, ast.Subscript) and isinstance(n.ctx, ast.Store) \
                and isinstance(n.value, ast.Name) and n.value.id in returned \
                and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str):
            keys.add(n.slice.value)
    return keys


def _payload_fields(fn, param):
    req, opt = set(), set()
    for n in ast.walk(fn):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "get" \
                and isinstance(n.func.value, ast.Name) and n.func.value.id == param \
                and n.args and isinstance(n.args[0], ast.Constant) and isinstance(n.args[0].value, str):
            opt.add(n.args[0].value)
        if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name) and n.value.id == param \
                and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str) \
                and isinstance(n.ctx, ast.Load):
            req.add(n.slice.value)
    return sorted(req), sorted(opt - req)


def _mark_required(fn, req, opt):
    """A field the handler rejects as 'Missing ...' is required, not optional."""
    msgs = [n.value for n in ast.walk(fn) if isinstance(n, ast.Constant) and isinstance(n.value, str)
            and "issing" in n.value]
    extra = {k for k in opt if any(re.search(r"issing.*\b%s\b" % re.escape(k), m) for m in msgs)}
    return sorted(set(req) | extra), sorted(set(opt) - extra)


def _imports(fn_or_tree):
    out = {}
    for n in ast.walk(fn_or_tree):
        if isinstance(n, ast.ImportFrom) and n.module:
            for a in n.names:
                out[a.asname or a.name] = (n.module, a.name)
    return out


def _follow_imported(fn, module_dir):
    """One level: response keys / payload fields of imported helpers the handler returns or feeds."""
    resp, req, opt = set(), set(), set()
    imp = _imports(fn)
    for n in ast.walk(fn):
        if isinstance(n, ast.Call):
            f = n.func.value if isinstance(n.func, ast.Await) else n.func
            if isinstance(f, ast.Name) and f.id in imp:
                mod, name = imp[f.id]
                path = os.path.join(module_dir, mod + ".py")
                if not os.path.isfile(path):
                    continue
                t = ast.parse(open(path, encoding="utf-8").read())
                target = next((x for x in t.body if isinstance(x, ast.FunctionDef) and x.name == name), None)
                if target is None:
                    continue
                resp |= _returned_keys(target)
                if target.args.args and n.args and isinstance(n.args[0], ast.Name) \
                        and n.args[0].id in ("body", "payload", "data"):
                    r, o = _payload_fields(target, target.args.args[0].arg)
                    r, o = _mark_required(target, r, o)
                    req |= set(r)
                    opt |= set(o)
    return resp, req, opt


def _query_params(body):
    q = set()
    for stmt in body:
        for n in ast.walk(stmt):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "get" \
                    and isinstance(n.func.value, ast.Name) and n.func.value.id == "params" \
                    and n.args and isinstance(n.args[0], ast.Constant):
                q.add(n.args[0].value)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "_safe_int" \
                    and len(n.args) >= 2 and isinstance(n.args[1], ast.Constant):
                q.add(n.args[1].value)
    return sorted(q)


def _handler_call(body):
    """Name of the first module-level style call whose result feeds the response."""
    for stmt in body:
        for n in ast.walk(stmt):
            if isinstance(n, ast.Assign):
                tgt = n.targets[0]
                names = [tgt.id] if isinstance(tgt, ast.Name) else \
                    [e.id for e in getattr(tgt, "elts", []) if isinstance(e, ast.Name)]
                if "result" in names and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Name):
                    return n.value
    return None


def _module_assign(tree, name):
    for n in tree.body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in n.targets):
            return n.value
    return None


def extract_ical(text):
    tree = ast.parse(text)
    funcs = _function_index(tree)
    handler = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Handler")
    methods = {m.name: m for m in handler.body if isinstance(m, ast.FunctionDef)}

    port = None
    m = re.search(r'os\.environ\.get\("OSTLER_API_PORT",\s*"(\d+)"\)', text)
    code_default_port = int(m.group(1)) if m else None
    m = re.search(r"MAX_POST_BYTES\s*=\s*int\(os\.environ\.get\(\"MAX_POST_BYTES\",\s*\"(\d+)\"\)\)", text)
    if not m:
        raise CannotRun("MAX_POST_BYTES not found in ical-server")
    max_post = int(m.group(1))
    pub = _module_assign(tree, "_PUBLIC_GET_PATHS")
    public_get = sorted(e.value for e in pub.elts) if pub is not None else []
    alias = {}
    for n in handler.body:
        if isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "_VERSIONED_TO_LEGACY" for t in n.targets):
            alias = {k.value: v.value for k, v in zip(n.value.keys, n.value.values)}
    if not public_get or not alias or code_default_port is None:
        raise CannotRun("ical-server: public paths / alias map / port not parsable")

    routes = {}
    for verb, fname in (("GET", "do_GET"), ("POST", "do_POST")):
        fn = methods[fname]
        for node in ast.walk(fn):
            if not isinstance(node, ast.If):
                continue
            for p in _path_tests(node.test):
                call = _handler_call(node.body)
                rec = {"method": verb, "path": p, "line": node.lineno,
                       "query_params": _query_params(node.body) if verb == "GET" else []}
                resp, req, opt = set(), [], []
                if call is not None and call.func.id in funcs:
                    hf = funcs[call.func.id]
                    resp = _returned_keys(hf)
                    if verb == "POST" and hf.args.args:
                        # first arg that is the payload (skip leading slug/id params)
                        pname = hf.args.args[-1].arg
                        req, opt = _payload_fields(hf, pname)
                for stmt in node.body:
                    for c in ast.walk(stmt):
                        if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr == "dumps" \
                                and c.args and isinstance(c.args[0], ast.Dict):
                            resp |= _str_keys_of_dicts(c.args[0])
                if call is not None and call.func.id in funcs and verb == "POST":
                    req, opt = _mark_required(funcs[call.func.id], req, opt)
                rec["response_fields"] = sorted(resp)
                rec["request_required"] = req
                rec["request_optional"] = opt
                routes.setdefault((verb, p), rec)
    out = []
    for (verb, p), rec in routes.items():
        public = verb == "GET" and p in public_get
        r = dict(rec)
        r.update(listener="ical", ports=[8090], auth=["none"] if public else ["service_token"])
        r["body_limit_bytes"] = None if verb == "GET" else max_post
        if verb == "POST":
            r["content_type"] = "application/json"
            if p.endswith("/forget"):
                r["body_limit_bytes"] = 0
                r.pop("content_type")
        out.append(r)
        if verb == "GET" and p in alias.values():
            for v, legacy in alias.items():
                if legacy == p:
                    a = dict(r)
                    a["path"] = v
                    a["alias_of"] = p
                    out.append(a)
    return out, {"code_default_port": code_default_port, "public_get": public_get,
                 "max_post_bytes": max_post}


# ───────────────────────── Doctor (AST + install.sh) ─────────────────────────

def extract_doctor(web_ui_text, proxy_text, install_text, ical_routes):
    tree = ast.parse(web_ui_text)
    consts = {}
    for n in tree.body:
        if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    consts[t.id] = n.value.value
    out, native = [], set()
    for fn in tree.body:
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        src = ast.get_source_segment(web_ui_text, fn) or ""
        for d in fn.decorator_list:
            if isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and d.func.attr in ("get", "post", "put", "delete", "patch") \
                    and isinstance(d.func.value, ast.Name) and d.func.value.id == "app" and d.args:
                a = d.args[0]
                path = a.value if isinstance(a, ast.Constant) else consts.get(getattr(a, "id", ""))
                if not path:
                    continue
                verb = d.func.attr.upper()
                req, opt = [], []
                resp = _returned_keys(fn)
                fr, fq, fo = _follow_imported(fn, os.path.dirname(os.path.join(REPO, DOCTOR)))
                resp |= fr
                if verb != "GET":
                    req, opt = sorted(set(req) | fq), sorted((set(opt) | fo) - fq - set(req))
                out.append({
                    "method": verb, "path": path, "listener": "doctor", "ports": [8089],
                    "auth": ["none"], "cross_site_refusal": "_cross_site_refusal(" in src,
                    "body_limit_bytes": None, "line": fn.lineno,
                    "query_params": [], "response_fields": sorted(resp),
                    "request_required": req, "request_optional": opt,
                })
                native.add((verb, path))
    m = re.search(r'DEFAULT_PROXY_PATHS\s*=\s*\(([^)]*)\)', proxy_text)
    proxy_paths = re.findall(r'"([^"]+)"', m.group(1)) if m else []
    m = re.search(r"<key>DOCTOR_PROXY_PATHS</key>\s*<string>([^<]+)</string>", install_text)
    if not m or not proxy_paths:
        raise CannotRun("DOCTOR_PROXY_PATHS / DEFAULT_PROXY_PATHS not parsable")
    for p in m.group(1).strip().split(","):
        if p.strip() not in proxy_paths:
            proxy_paths.append(p.strip())
    by_norm = {}
    for r in ical_routes:
        by_norm.setdefault(norm(r["path"]), []).append(r)
    native_paths = {p for _, p in native}
    for p in proxy_paths:
        ups = by_norm.get(norm(p), [])
        verbs = sorted({u["method"] for u in ups}) or ALL_METHODS
        for verb in verbs:
            if p in native_paths and (verb, p) in native:
                continue
            u = next((x for x in ups if x["method"] == verb), None)
            auth = ["device_bearer"]
            if p == "/api/safari/ingest" and verb == "POST":
                auth.append("extension_token")
            rec = {
                "method": verb, "path": p, "listener": "doctor", "ports": [8089], "auth": auth,
                "proxy_to": "ical:%s:%s" % (verb, u["path"]) if u else None,
                "body_limit_bytes": u["body_limit_bytes"] if u else None,
                "line": 0, "query_params": u["query_params"] if u else [],
                "response_fields": u["response_fields"] if u else [],
                "request_required": u["request_required"] if u else [],
                "request_optional": u["request_optional"] if u else [],
            }
            if u and u.get("content_type"):
                rec["content_type"] = u["content_type"]
            if not u:
                rec["upstream_missing"] = True
            out.append(rec)
    return out


# ───────────────────────── Gateway (Rust, regex + paren scan) ─────────────────────────

def _strip_rs_comments(text):
    return re.sub(r"(?m)^\s*//.*$", "", text)


def _balanced(text, start):
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        elif c == '"':
            i = text.index('"', i + 1)
        i += 1
    raise CannotRun("unbalanced parens in gateway lib.rs")


def extract_gateway(src_dir, ical_routes, doctor_routes):
    base = os.path.join(src_dir, "crates/zeroclaw-gateway/src")
    raw_lib = read("lib.rs", base)
    a = raw_lib.find("fn build_gateway_router(")
    b = raw_lib.find("pub async fn run_gateway(")
    if a < 0 or b < a:
        raise CannotRun("gateway: build_gateway_router span not found")
    lib = _strip_rs_comments(raw_lib[a:b])
    consts_src = raw_lib
    auth_rs = read("api_auth.rs", base)
    ws_rs = read("ws.rs", base)
    cfg_rs = read("crates/zeroclaw-config/src/schema.rs", src_dir)

    m = re.search(r"PRE_AUTH_ALLOWLIST:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]", auth_rs)
    pre_auth = re.findall(r'"([^"]+)"', m.group(1)) if m else None
    m = re.search(r"pub const MAX_BODY_SIZE:\s*usize\s*=\s*([\d_]+)", consts_src)
    default_limit = int(m.group(1).replace("_", "")) if m else None
    m = re.search(r"fn default_companion_port\(\)\s*->\s*u16\s*\{\s*(\d+)", cfg_rs)
    companion_port = int(m.group(1)) if m else None
    m = re.search(r"fn default_gateway_host\(\)\s*->\s*String\s*\{\s*\"([^\"]+)\"", cfg_rs)
    gw_host = m.group(1) if m else None
    if pre_auth is None or default_limit is None or companion_port is None:
        raise CannotRun("gateway: allowlist / body limit / companion port not parsable")
    ws_bearer = "extract_ws_token" in ws_rs and "is_authenticated" in ws_rs

    m = re.search(r"let big_body_router\s*=(.*?);", lib, re.S)
    big_span = (m.start(), m.end()) if m else (0, 0)
    big_limit = None
    if m:
        mm = re.search(r"RequestBodyLimitLayer::new\(([\d_]+)\)", m.group(1))
        big_limit = int(mm.group(1).replace("_", "")) if mm else None

    ical_by = {(r["method"], r["path"]): r for r in ical_routes}
    ical_by_norm = {(r["method"], norm(r["path"])): r for r in ical_routes}
    doc_by_norm = {(r["method"], norm(r["path"])): r for r in doctor_routes}

    out = []
    for m in re.finditer(r"\.route\(", lib):
        end = _balanced(lib, m.end() - 1)
        body = lib[m.end():end]
        pm = re.match(r'\s*"([^"]+)"\s*,(.*)$', body, re.S)
        if not pm:
            continue
        path, rest = re.sub(r"\{\*(\w+)\}", r"{\1}", pm.group(1)), pm.group(2)
        prev_cfg = lib.rfind("#[cfg(", 0, m.start())
        gated = prev_cfg != -1 and ";" not in lib[prev_cfg:m.start()]
        in_big = big_span[0] <= m.start() <= big_span[1]
        for verb, handler in re.findall(r"\b(get|post|put|delete|patch)\(\s*([\w:]+)", rest):
            V = verb.upper()
            auth = ["device_bearer"] if (path.startswith("/api/") and path not in pre_auth) else None
            if auth is None:
                if path.startswith("/ws/") and ws_bearer:
                    auth = ["device_bearer"]
                elif path.startswith(("/admin/", "/internal/")):
                    auth = ["admin_token"]
                elif path in pre_auth:
                    auth = ["none"]
                else:
                    auth = ["handler_defined"]
            rec = {"method": V, "path": path, "listener": "gateway", "ports": [8000, companion_port],
                   "auth": auth, "body_limit_bytes": (big_limit if in_big else default_limit) if V != "GET" else None,
                   "line": raw_lib[:raw_lib.find('"%s"' % path)].count("\n") + 1 if '"%s"' % path in raw_lib else 0,
                   "query_params": [], "response_fields": [], "request_required": [], "request_optional": []}
            if gated:
                rec["feature_gated"] = True
            if path.startswith("/ws/"):
                rec["transport"] = "websocket"
            if path.endswith("{*rest}") or "{*" in path:
                pass
            up = None
            if "pwg_proxy::" in handler:
                up = ical_by_norm.get((V, norm(path)))
                if up is None:
                    # wildcard: the route fronts EVERY ical route under this prefix
                    pre = path.split("{")[0]
                    cand = [r for r in ical_routes if r["method"] == V and r["path"].startswith(pre)]
                    if cand:
                        up = {"path": cand[0]["path"], "content_type": cand[0].get("content_type")}
                        for k in ("query_params", "response_fields", "request_required", "request_optional"):
                            up[k] = sorted({x for c in cand for x in c[k]})
                        rec["proxy_to"] = ["ical:%s:%s" % (V, c["path"]) for c in cand]
                else:
                    rec["proxy_to"] = "ical:%s:%s" % (V, up["path"])
                if up is None and "daily_brief" not in handler:
                    rec["upstream_missing"] = True
            elif "doctor_proxy::" in handler:
                up = doc_by_norm.get((V, norm(path)))
                rec["proxy_to"] = "doctor:%s:%s" % (V, up["path"]) if up else None
                if up is None:
                    rec["upstream_missing"] = True
            if up:
                for k in ("query_params", "response_fields", "request_required", "request_optional"):
                    rec[k] = up[k]
                if up.get("content_type"):
                    rec["content_type"] = up["content_type"]
            if isinstance(rec.get("proxy_to"), list):
                # A wildcard fronts several upstream routes. Expand it so every
                # route a client can hit is concrete and carries ITS OWN fields.
                for c in [r for r in ical_routes if r["method"] == V and r["path"].startswith(path.split("{")[0])]:
                    e = dict(rec)
                    e.update(path=c["path"], proxy_to="ical:%s:%s" % (V, c["path"]), via_wildcard=path,
                             query_params=c["query_params"], response_fields=c["response_fields"],
                             request_required=c["request_required"], request_optional=c["request_optional"])
                    if c.get("content_type"):
                        e["content_type"] = c["content_type"]
                    out.append(e)
                continue
            out.append(rec)
    info = {"default_body_limit": default_limit, "big_body_limit": big_limit,
            "pre_auth_allowlist": pre_auth, 
            "companion_port": companion_port,
            "default_host": gw_host}
    return out, info


# ───────────────────────── Stores (install.sh nginx) ─────────────────────────

def extract_store(install_text):
    m = re.search(r"cat > \"\$\{OSTLER_DIR\}/ostler-store-proxy\.conf\" <<'NGINXEOF'\n(.*?)\nNGINXEOF", install_text, re.S)
    if not m:
        raise CannotRun("store-proxy nginx heredoc not found in install.sh")
    conf = m.group(1)
    unlimited = bool(re.search(r"client_max_body_size\s+0;", conf))
    servers = {}
    for blk in re.finditer(r"server\s*\{\s*listen\s+(\d+);(.*?)\n    \}", conf, re.S):
        port, body = int(blk.group(1)), blk.group(2)
        up = re.search(r'set \$ostler_(\w+)_upstream "http://(\w+):(\d+)"', body)
        if up:
            servers[up.group(2)] = (port, body)
    if "qdrant" not in servers or "oxigraph" not in servers:
        raise CannotRun("store-proxy: qdrant/oxigraph server blocks not found")
    bearer = re.search(r'\$http_authorization != "Bearer \$\{OXIGRAPH_TOKEN\}"', install_text) is not None
    qkey = "QDRANT__SERVICE__API_KEY" in install_text
    if not (bearer and qkey):
        raise CannotRun("store auth lines not found in install.sh")
    out = []
    for name, auth, hdr in (("qdrant", "qdrant_api_key", "api-key"), ("oxigraph", "store_bearer", "Authorization")):
        port = servers[name][0]
        for verb in ALL_METHODS:
            out.append({"method": verb, "path": "/{any}", "listener": "store_" + name, "ports": [port],
                        "auth": [auth], "body_limit_bytes": None if unlimited else 1048576,
                        "line": 0, "query_params": [], "response_fields": [], "request_required": [],
                        "request_optional": [], "auth_header": hdr})
    return out


# ───────────────────────── Assemble ─────────────────────────

AUTH_SCHEMES = {
    "none": {"header": None, "note": "no credential required"},
    "device_bearer": {"header": "Authorization: Bearer <paired device token>",
                      "note": "token minted by pairing; validated by the gateway PairingGuard (Doctor asks the gateway oracle)"},
    "service_token": {"header": "Authorization: Bearer <PWG_SERVICE_TOKEN> or X-Ostler-Service: <token>",
                      "note": "per-install secret in ~/.ostler/secrets/service_token; ical-server fails closed without it"},
    "extension_token": {"header": "Authorization: Bearer <OSTLER_EXTENSION_TOKEN>",
                        "note": "browser-extension key; Doctor accepts it for POST /api/safari/ingest from loopback only"},
    "admin_token": {"header": "Authorization: Bearer <machine admin token>", "note": "loopback admin surface"},
    "qdrant_api_key": {"header": "api-key: <QDRANT_API_KEY>", "note": "Qdrant native key, behind the :6333 store proxy"},
    "store_bearer": {"header": "Authorization: Bearer <OXIGRAPH_TOKEN>", "note": "checked by the :7878 store proxy"},
    "handler_defined": {"header": None, "note": "enforced inside the handler; not statically classified by the generator"},
}


def build(gateway_dir):
    ical_text = read(ICAL)
    web_text = read(DOCTOR)
    proxy_text = read(PROXY)
    install_text = read(INSTALL)

    ical, ical_info = extract_ical(ical_text)
    doctor = extract_doctor(web_text, proxy_text, install_text, ical)
    store = extract_store(install_text)
    gateway, gw_info = extract_gateway(gateway_dir, ical, doctor)

    routes = ical + doctor + gateway + store
    for r in routes:
        r["id"] = "%s %s %s" % (r["listener"], r["method"], r["path"])
        r["source"] = {"ical": ICAL, "doctor": DOCTOR if not r.get("proxy_to") else INSTALL,
                       "gateway": "ostler-assistant:crates/zeroclaw-gateway/src/lib.rs",
                       "store_qdrant": INSTALL, "store_oxigraph": INSTALL}[r["listener"]] + \
            ""
        r.pop("line", None)
        for k in [k for k, v in r.items() if v is None and k not in ("body_limit_bytes", "proxy_to")]:
            del r[k]
        if r.get("proxy_to") is None:
            r.pop("proxy_to", None)
    routes.sort(key=lambda r: (r["listener"], r["path"], r["method"]))
    ids = [r["id"] for r in routes]
    if len(ids) != len(set(ids)):
        raise CannotRun("duplicate route ids: %s" % sorted({i for i in ids if ids.count(i) > 1})[:5])

    listeners = {
        "gateway": {"ports": {"8000": {"scheme": "http", "scope": "loopback"},
                              str(gw_info["companion_port"]): {"scheme": "https", "scope": "lan_tailnet", "tls": "self-signed"}},
                    "note": "ostler-assistant gateway; port 8000 pinned by install.sh, 8443 is the Companion TLS listener serving the same router"},
        "doctor": {"ports": {"8089": {"scheme": "http", "scope": "loopback_tailnet"}},
                   "note": "FastAPI Doctor; proxies /api/v1/* to ical after validating the paired bearer"},
        "ical": {"ports": {"8090": {"scheme": "http", "scope": "loopback"}},
                 "note": "ical-server.py (assistant API); install.sh sets OSTLER_API_PORT=8090, the code default is %d" % ical_info["code_default_port"]},
        "store_qdrant": {"ports": {str(next(r["ports"][0] for r in store if r["listener"] == "store_qdrant")): {"scheme": "http", "scope": "loopback"}}},
        "store_oxigraph": {"ports": {str(next(r["ports"][0] for r in store if r["listener"] == "store_oxigraph")): {"scheme": "http", "scope": "loopback"}}},
    }
    return {
        "contract_version": 1,
        "generated_by": "scripts/gen_hub_contract.py",
        "do_not_edit": "Generated from server code. Run scripts/gen_hub_contract.py; CI fails if this file is stale.",
        "note_on_format": "JSON text, which is valid YAML 1.2; read it with any JSON parser.",
        "listeners": listeners,
        "auth_schemes": AUTH_SCHEMES,
        "facts": {"ical": ical_info, "gateway": gw_info},
        "field_extraction": "heuristic: dict-literal keys reaching a return in the handler (response), payload[...] / payload.get(...) (request). Empty list means not statically derivable, not 'no fields'.",
        "routes": routes,
    }


def render(contract):
    return json.dumps(contract, indent=1, sort_keys=True, ensure_ascii=True) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway-src", default=os.environ.get("OSTLER_ASSISTANT_DIR") or
                    os.path.join(os.path.dirname(REPO), "ostler-assistant"))
    ap.add_argument("--out", default=os.path.join(REPO, DEFAULT_OUT))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    try:
        text = render(build(a.gateway_src))
    except CannotRun as e:
        print("CANNOT-RUN: %s" % e, file=sys.stderr)
        return 2
    if a.check:
        cur = open(a.out, encoding="utf-8").read() if os.path.isfile(a.out) else ""
        if cur != text:
            print("STALE: %s differs from the server code. Run scripts/gen_hub_contract.py and commit." % a.out,
                  file=sys.stderr)
            return 1
        print("hub_contract.yaml is current (%d routes)" % len(json.loads(text)["routes"]))
        return 0
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    c = json.loads(text)
    print("wrote %s: %d routes" % (a.out, len(c["routes"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
