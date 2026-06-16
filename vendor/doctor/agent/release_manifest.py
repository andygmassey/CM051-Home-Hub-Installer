"""Release-manifest reader for Ostler Doctor (WORKSTREAM C / C2).

Reads ``~/.ostler/ostler-release.json`` -- the single runtime-queryable
record of *what version is actually deployed* -- and exposes it to the
Doctor version surface. The absence of this knowability is what cost a
whole night on the .152 walk: the daemon's ``--version`` reported the
frozen ``zeroclaw 0.4.1`` Cargo field, the wiki images had their own
SHA pins, and nothing on the box could answer "which build is this?".

Written by CM051 ``install.sh`` via ``lib/release_manifest.sh`` at the
end of a successful install (and on every re-run-as-update). See
``CM051/docs/RELEASE_MANIFEST.md`` for the schema contract.

**Doctor-side reader only.** This module never writes. It is deliberately
backwards-tolerant per ``launch/BACKWARDS_TOLERANT_READERS.md``: it
accepts an absent file, an absent field, a ``null`` field, and an unknown
``manifest_schema_version`` without ever raising. A malformed manifest
degrades the version surface to "unknown", which is strictly safer than a
blank that looks legitimate.

i18n: this module returns DATA only (no rendered strings). All
operator-facing copy lives in ``web_ui_copy.py`` and is applied by
``dashboard_components.render_version_surface``.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any, Optional, TypedDict

logger = logging.getLogger(__name__)

# The schema version this reader was written against. We READ any
# version (backwards-tolerant) but record what we know so a future
# reader can branch on a breaking bump. See RELEASE_MANIFEST.md.
SUPPORTED_SCHEMA_VERSION = "1"

MANIFEST_NAME = "ostler-release.json"


class ReleaseManifest(TypedDict, total=False):
    """Parsed, normalised shape of ``~/.ostler/ostler-release.json``.

    Every field is optional: a manifest written by an older build may
    omit fields a newer Doctor knows about, and vice versa. Consumers
    must use ``.get`` with a default -- never blind-index.
    """

    manifest_schema_version: str
    ostler_version: str
    installer_version: str
    channel: str
    daemon_version: Optional[str]
    daemon_tag: Optional[str]
    wiki_site_image_sha: Optional[str]
    wiki_compiler_image_sha: Optional[str]
    source_repos: dict
    built_at: Optional[str]
    installed_at: Optional[str]
    schema_known: bool


def _manifest_path() -> Path:
    """Return ``~/.ostler/ostler-release.json``.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments,
    mirroring the iMessage / observability posture readers.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    return base / MANIFEST_NAME


def read_release_manifest() -> Optional[ReleaseManifest]:
    """Read and normalise the release manifest.

    Returns ``None`` when the file is absent (fresh install before
    install.sh has emitted it) or genuinely unreadable. Otherwise
    returns a normalised :class:`ReleaseManifest`. Never raises: any
    parse / shape problem is logged at debug and yields ``None`` so the
    surface falls through to its "unknown" state rather than 500-ing the
    dashboard.
    """
    path = _manifest_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as exc:  # permissions, etc.
        logger.debug("release manifest unreadable at %s: %s", path, exc)
        return None

    try:
        data: Any = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        logger.debug("release manifest malformed at %s: %s", path, exc)
        return None

    if not isinstance(data, dict):
        logger.debug("release manifest is not a JSON object at %s", path)
        return None

    return _normalise(data)


def _normalise(data: dict) -> ReleaseManifest:
    """Map the on-disk shape to the normalised reader shape.

    Backwards-tolerant by construction:

    - Nested ``daemon`` / ``wiki`` objects are flattened, but a build
      that wrote them flat (or omitted them) is tolerated.
    - An unknown ``manifest_schema_version`` is accepted; we flag it via
      ``schema_known`` so the surface can hint "newer than this Doctor".
    - Every ``.get`` carries a default; nothing is blind-indexed.
    """
    schema = str(data.get("manifest_schema_version", "")) or "0"

    daemon = data.get("daemon")
    if not isinstance(daemon, dict):
        daemon = {}
    wiki = data.get("wiki")
    if not isinstance(wiki, dict):
        wiki = {}
    source_repos = data.get("source_repos")
    if not isinstance(source_repos, dict):
        source_repos = {}

    out: ReleaseManifest = {
        "manifest_schema_version": schema,
        "schema_known": schema == SUPPORTED_SCHEMA_VERSION,
        "ostler_version": str(data.get("ostler_version") or "unknown"),
        "installer_version": str(
            data.get("installer_version") or data.get("ostler_version") or "unknown"
        ),
        "channel": str(data.get("channel") or "stable"),
        # daemon.version may live nested (v1) or, defensively, flat.
        "daemon_version": daemon.get("version") or data.get("daemon_version"),
        "daemon_tag": daemon.get("tag") or data.get("daemon_tag"),
        "wiki_site_image_sha": wiki.get("site_image_sha")
        or data.get("wiki_site_image_sha"),
        "wiki_compiler_image_sha": wiki.get("compiler_image_sha")
        or data.get("wiki_compiler_image_sha"),
        "source_repos": source_repos,
        "built_at": data.get("built_at"),
        "installed_at": data.get("installed_at"),
    }
    return out
