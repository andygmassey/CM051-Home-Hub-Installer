'use strict';
// JS port of hub_contract_check.py. Same rules, same violation codes. CommonJS, no deps.
// const c = HubContract.load('contract/hub_contract.yaml');
// const { violations, notes } = c.checkCall({ id, method, url, headers, token_source,
//                                             body_bytes, body_keys, reads });
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const TOKEN_TO_SCHEME = {
  device_token: 'device_bearer', service_token: 'service_token', extension_token: 'extension_token',
  oxigraph_token: 'store_bearer', qdrant_key: 'qdrant_api_key', admin_token: 'admin_token', none: 'none',
};

function tplRegex(p) {
  const out = p.split(/(\{[^}]*\})/).map((part) => {
    if (part.startsWith('{')) {
      const name = part.slice(1, -1);
      return name === 'rest' || name === 'any' ? '.+' : '[^/]+';
    }
    return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }).join('');
  return new RegExp('^' + out + '$');
}

function parseUrl(url) {
  const u = new URL(url);
  const port = u.port ? Number(u.port) : (u.protocol === 'https:' || u.protocol === 'wss:' ? 443 : 80);
  return { port, path: u.pathname || '/' };
}

class HubContract {
  constructor(data) {
    this.data = data;
    this.routes = data.routes;
    for (const r of this.routes) r._re = tplRegex(r.path);
  }

  static load(file, pinFile) {
    const raw = fs.readFileSync(file);
    pinFile = pinFile || path.join(path.dirname(file), 'hub_contract.pin.json');
    const pin = JSON.parse(fs.readFileSync(pinFile, 'utf8'));
    const got = crypto.createHash('sha256').update(raw).digest('hex');
    if (got !== pin.contract_sha256) {
      throw new Error(`vendored hub_contract.yaml (${got.slice(0, 12)}) does not match its pin ` +
        `(${pin.contract_sha256.slice(0, 12)}). Re-vendor with CM051 scripts/pin_hub_contract.py; never edit the copy.`);
    }
    return new HubContract(JSON.parse(raw.toString('utf8')));
  }

  candidates(p) { return this.routes.filter((r) => r._re.test(p)); }

  match(method, url) {
    const { port, path: p } = parseUrl(url);
    const hits = this.candidates(p).filter((r) => r.ports.includes(port) && r.method === method.toUpperCase());
    hits.sort((a, b) => (a.path.split('{').length - b.path.split('{').length) || (b.path.length - a.path.length));
    return hits[0] || null;
  }

  checkCall(call) {
    const violations = []; const notes = [];
    const method = call.method.toUpperCase();
    const { port, path: p } = parseUrl(call.url);
    const route = this.match(method, call.url);
    if (!route) {
      const cands = this.candidates(p).filter((r) => r.path !== '/{any}');
      if (!cands.length) violations.push(['ROUTE_MISSING', `${method} ${p}: no server route has this path on any listener`]);
      else if (!cands.some((r) => r.ports.includes(port))) {
        violations.push(['PORT_MISMATCH', `${method} ${p}: served on port(s) ${[...new Set(cands.flatMap((r) => r.ports))]}, client dials ${port}`]);
      } else {
        violations.push(['METHOD_MISMATCH', `${method} ${p}:${port}: server offers ${[...new Set(cands.filter((r) => r.ports.includes(port)).map((r) => r.method))]} here`]);
      }
      return { violations, notes };
    }
    const h = {};
    for (const [k, v] of Object.entries(call.headers || {})) h[k.toLowerCase()] = String(v);
    const src = call.token_source || 'none';
    const scheme = TOKEN_TO_SCHEME[src];
    if (!scheme) throw new Error(`unknown token_source ${src}`);
    const allowed = route.auth;
    if (!allowed.includes('none') && !allowed.includes('handler_defined')) {
      const b = h.authorization || '';
      const hasBearer = /^bearer /i.test(b) && b.slice(7).trim() !== '';
      const hasService = (h['x-ostler-service'] || '').trim() !== '';
      const hasQkey = (h['api-key'] || '').trim() !== '';
      const has = allowed.includes('qdrant_api_key') ? hasQkey
        : allowed.includes('service_token') ? (hasBearer || hasService) : hasBearer;
      if (!has) violations.push(['AUTH_MISSING', `${method} ${p} needs ${allowed.join('/')}, request carries no usable credential header`]);
      else if (!allowed.includes(scheme)) violations.push(['AUTH_WRONG_CREDENTIAL', `${method} ${p} accepts ${allowed.join('/')}, client sends ${src}`]);
    } else if (allowed.includes('handler_defined')) {
      notes.push(`auth for ${method} ${p} is handler-defined; not statically checkable`);
    }
    const limit = route.body_limit_bytes;
    if (method !== 'GET' && limit !== null && limit !== undefined && 'body_bytes' in call) {
      if (call.body_bytes === null) violations.push(['BODY_UNBOUNDED', `${method} ${p}: server limit is ${limit} bytes, client body has no bound`]);
      else if (call.body_bytes > limit) violations.push(['BODY_TOO_LARGE', `${method} ${p}: body ${call.body_bytes} bytes > server limit ${limit}`]);
    }
    if (call.body_keys) {
      const missing = (route.request_required || []).filter((k) => !call.body_keys.includes(k));
      if (missing.length) violations.push(['REQUEST_FIELD_MISSING', `${method} ${p}: server requires ${missing}`]);
    }
    const reads = call.reads || [];
    if (reads.length) {
      const have = route.response_fields || [];
      if (!have.length) notes.push(`${method} ${p}: server response fields not derivable; ${reads} unchecked`);
      else {
        const absent = reads.filter((f) => !have.includes(f));
        if (absent.length) violations.push(['RESPONSE_FIELD_ABSENT', `${method} ${p}: client reads ${absent}, server returns ${have}`]);
      }
    }
    return { violations, notes };
  }
}

module.exports = { HubContract };
