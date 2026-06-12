"""Route-level contract guard (the #653 / #596 silent-404 class).

Every ``/api/v1/*`` path the Hub web frontend calls MUST be served by THIS
(vendored, shipping) ical-server -- either dispatched directly, or via the
``/api/v1`` -> internal alias map whose rewrite target is itself dispatched.

This is the route analogue of consent_cli's ``TICKBOX_REGISTRY`` completeness
guard (#659): a frontend caller referencing an endpoint the server never
implemented yields a silent 404 -> a blank Hub surface. It is the exact failure
mode behind #653 (Timeline) and the People-card class (#596/#600).

It also pins the source-vs-vendored divergence found 2026-06-12: CM041
``origin/main`` lacked the bare ``/api/v1/people`` route the Hub needs, while the
vendored copy (this file's sibling, what the DMG runs) implements it via
``people_list``. This test keeps the SHIPPING copy honest; when the route is
back-ported to CM041 source, copy this test there too.

``HUB_REQUIRED_V1`` is derived from ``ostler-assistant/web/src`` (snapshot
2026-06-12). Keep it in sync when the Hub adds/removes an ical-server call:
  - ``apiDataFetch('/api/v1/people?sort=...')``  web/src/pages/People.tsx
  - ``apiDataFetch('/api/v1/timeline')``         web/src/pages/Timeline.tsx
  - ``/api/v1/calendar`` + ``/api/v1/suggestions`` declared in web/src/lib/basePath.ts
"""
from __future__ import annotations

import re
from pathlib import Path

SERVER = Path(__file__).resolve().parents[1] / "ical-server.py"

# /api/v1 paths the Hub web frontend depends on (see module docstring).
HUB_REQUIRED_V1 = {
    "/api/v1/people",
    "/api/v1/timeline",
    "/api/v1/calendar",
    "/api/v1/suggestions",
}


def _parse_routes(src: str):
    """Extract the server's served routes from its source.

    Returns ``(alias, exact, prefixes)`` where:
      - ``alias``    maps ``/api/v1/X`` -> internal ``/Y`` (the alias rewrite map),
      - ``exact``    is the set of ``parsed.path == "/Z"`` dispatch literals,
      - ``prefixes`` is the set of ``parsed.path.startswith("/Z")`` dispatch bases.
    Only path-shaped values (leading ``/``) are kept, so the human-readable
    404 ``endpoints`` dict (whose values are descriptions) is ignored.
    """
    alias = dict(re.findall(r'"(/api/v1/[^"]+)"\s*:\s*"(/[^"]*)"', src))
    exact = set(re.findall(r'parsed\.path\s*==\s*"(/[^"]*)"', src))
    prefixes = set(re.findall(r'parsed\.path\.startswith\(\s*"(/[^"]*)"', src))
    return alias, exact, prefixes


def _dispatched(path: str, exact: set, prefixes: set) -> bool:
    return path in exact or any(
        path == p or path.startswith(p) for p in prefixes
    )


def _served(req: str, alias: dict, exact: set, prefixes: set) -> bool:
    # Served directly, or via an alias whose rewrite target is dispatched.
    if _dispatched(req, exact, prefixes):
        return True
    if req in alias and _dispatched(alias[req], exact, prefixes):
        return True
    return False


def test_hub_required_v1_endpoints_are_served():
    src = SERVER.read_text(encoding="utf-8")
    alias, exact, prefixes = _parse_routes(src)
    missing = sorted(
        r for r in HUB_REQUIRED_V1 if not _served(r, alias, exact, prefixes)
    )
    assert not missing, (
        "Hub web frontend calls these /api/v1 endpoints but this ical-server "
        f"does not serve them (silent 404 -> blank surface): {missing}"
    )


def test_alias_map_targets_are_all_dispatched():
    """No dangling alias: every ``/api/v1`` alias must rewrite to a path the
    server actually dispatches (else the rewrite 404s after the alias hop)."""
    src = SERVER.read_text(encoding="utf-8")
    alias, exact, prefixes = _parse_routes(src)
    dangling = sorted(
        f"{k} -> {v}"
        for k, v in alias.items()
        if not _dispatched(v, exact, prefixes)
    )
    assert not dangling, (
        "Alias-map entries whose rewrite target is never dispatched "
        f"(silent 404 after the alias hop): {dangling}"
    )
