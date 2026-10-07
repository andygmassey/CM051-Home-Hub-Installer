# Hub contract (Lane 10)

`vendor/cm041/assistant_api/hub_contract.yaml` lists every route a client can call on the
Hub: method, path pattern, listener and port, required auth, body limit, and the key request
and response fields. It is **generated from the server code**, never written by hand:

    scripts/gen_hub_contract.py --gateway-src ../ostler-assistant

The file is JSON text, which is valid YAML 1.2, so Swift, JS and Python clients read it with
their standard JSON parser.

## Where each fact comes from

| Fact | Source |
|---|---|
| ical-server routes, methods, query params, request and response fields, body limit | `vendor/cm041/assistant_api/ical-server.py` (AST of `Handler.do_GET` / `do_POST`, `MAX_POST_BYTES`, `_PUBLIC_GET_PATHS`) |
| Doctor routes and which are reverse-proxied | `vendor/doctor/agent/web_ui.py` decorators, `DOCTOR_PROXY_PATHS` in `install.sh`, `proxy.py` |
| Gateway routes, device-bearer gate, body limits (64 KiB, 1 MiB for big-body routes), ports 8000 and 8443 | `ostler-assistant` `crates/zeroclaw-gateway/src/{lib,api_auth,ws}.rs` |
| Store proxy ports and credentials (Qdrant `api-key` on 6333, Oxigraph Bearer on 7878) | the `ostler-store-proxy.conf` heredoc in `install.sh` |

If a source cannot be parsed the generator exits **2 (CANNOT-RUN)**; it never writes a
partial contract. Response fields are a heuristic (top-level dict keys that reach a `return`);
an empty list means "not derivable", which clients report as unchecked, not as "no fields".

## CI

`.github/workflows/hub-contract.yml`: unit tests that prove the generator and checker can go
red, a freshness check (regenerate, fail if the committed file differs), and a drift job that
lists every client repo whose pin is older than this contract (`hub_contract_clients.json`).

## Client side

`scripts/pin_hub_contract.py <client-repo>` vendors the contract, its pin
(`hub_contract.pin.json`, a sha256) and the checkers (`hub_contract_check.py` / `.js`) into
`<client>/contract/`. Each client's test builds every Hub call through its real request
builder and runs it through the checker: route exists on that method and port, auth sent is
one the route accepts, body is under the limit, fields read exist in the response.
Calls that are red today and not fixed here are listed in the client's
`contract/known_drift.json`; a listed call that stops violating fails the test, so the list
cannot rot.

## Auth kinds (Lane 11 addition)

A route's `auth` list names every credential it accepts. Besides the token kinds it can carry
`loopback_none`: the gateway lets a loopback peer with no relay or browser headers skip the
bearer on that exact path (`LOOPBACK_UNAUTH_PATHS` in `api_auth.rs`; today only
`/api/v1/speakers/identify`, which the Mac RemoteCapture app calls with no credential). The
checker accepts `token_source: "none"` for such a route only when the client dials 127.0.0.1,
localhost or ::1; a LAN host is still `AUTH_MISSING`.
