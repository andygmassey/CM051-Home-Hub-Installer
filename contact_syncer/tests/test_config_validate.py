"""Unit tests for contact_syncer.config.validate_required.

Covers HIGH-4 of /tmp/silent_fail_audit_2026-05-04.md: a partial install
where CARDDAV_URL stuck but the credentials did not should produce a
clear RuntimeError at module entry rather than a downstream 401 /
connection-refused.

Uses the validate_required `_values` kwarg so we exercise each branch
without reload trickery against the live module-level snapshot.
"""
from __future__ import annotations

import pytest

from contact_syncer import config


def _vals(**overrides):
    """Helper -- start from a fully-empty config and override."""
    base = {
        "CARDDAV_URL": "",
        "CARDDAV_USERNAME": "",
        "CARDDAV_PASSWORD": "",
        "QDRANT_URL": "",
        "OXIGRAPH_URL": "",
        "EMBED_OLLAMA_URL": "",
    }
    base.update(overrides)
    return base


# -- Pair-coupling: CardDAV URL ↔ credentials -------------------------------


def test_carddav_url_alone_raises() -> None:
    """URL set but both creds empty -> the partial-install case the audit flagged."""
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(_values=_vals(CARDDAV_URL="https://carddav.example/"))
    msg = str(excinfo.value)
    assert "CARDDAV_URL is set but" in msg
    assert "CARDDAV_USERNAME or CARDDAV_PASSWORD is empty" in msg


def test_carddav_url_with_username_only_raises() -> None:
    """URL + username set but password empty -> still a partial install."""
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(
            _values=_vals(
                CARDDAV_URL="https://carddav.example/",
                CARDDAV_USERNAME="user",
            )
        )
    assert "CARDDAV" in str(excinfo.value)


def test_carddav_url_with_password_only_raises() -> None:
    """URL + password set but username empty -> still a partial install."""
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(
            _values=_vals(
                CARDDAV_URL="https://carddav.example/",
                CARDDAV_PASSWORD="secret",
            )
        )
    assert "CARDDAV" in str(excinfo.value)


def test_carddav_full_triple_passes() -> None:
    """All three set -> pair-check is satisfied (no require_* flags raised)."""
    config.validate_required(
        _values=_vals(
            CARDDAV_URL="https://carddav.example/",
            CARDDAV_USERNAME="user",
            CARDDAV_PASSWORD="secret",
        )
    )


def test_carddav_url_empty_passes_pair_check() -> None:
    """URL empty (regardless of creds) -> pair-check has nothing to require."""
    config.validate_required(_values=_vals(CARDDAV_URL=""))
    config.validate_required(
        _values=_vals(CARDDAV_URL="", CARDDAV_USERNAME="orphan", CARDDAV_PASSWORD="orphan")
    )


# -- require_carddav flag ---------------------------------------------------


def test_require_carddav_with_empty_raises() -> None:
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(require_carddav=True, _values=_vals())
    msg = str(excinfo.value)
    assert "CARDDAV_URL, CARDDAV_USERNAME and CARDDAV_PASSWORD must all" in msg


def test_require_carddav_with_full_triple_passes() -> None:
    config.validate_required(
        require_carddav=True,
        _values=_vals(
            CARDDAV_URL="https://carddav.example/",
            CARDDAV_USERNAME="user",
            CARDDAV_PASSWORD="secret",
        ),
    )


# -- require_qdrant / oxigraph / embed flags --------------------------------


def test_require_qdrant_empty_raises() -> None:
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(require_qdrant=True, _values=_vals())
    assert "QDRANT_URL must be set" in str(excinfo.value)


def test_require_oxigraph_empty_raises() -> None:
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(require_oxigraph=True, _values=_vals())
    assert "OXIGRAPH_URL must be set" in str(excinfo.value)


def test_require_embed_empty_raises() -> None:
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(require_embed=True, _values=_vals())
    assert "EMBED_OLLAMA_URL must be set" in str(excinfo.value)


def test_require_qdrant_oxigraph_embed_set_passes() -> None:
    config.validate_required(
        require_qdrant=True,
        require_oxigraph=True,
        require_embed=True,
        _values=_vals(
            QDRANT_URL="http://localhost:6333",
            OXIGRAPH_URL="http://localhost:7878",
            EMBED_OLLAMA_URL="http://localhost:11434",
        ),
    )


# -- Multi-error concatenation ----------------------------------------------


def test_multiple_errors_are_concatenated() -> None:
    """Caller asks for everything; nothing is set -> single RuntimeError listing all."""
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(
            require_carddav=True,
            require_qdrant=True,
            require_oxigraph=True,
            require_embed=True,
            _values=_vals(),
        )
    msg = str(excinfo.value)
    # Single raise, but every category surfaces in the message.
    assert "CARDDAV" in msg
    assert "QDRANT_URL" in msg
    assert "OXIGRAPH_URL" in msg
    assert "EMBED_OLLAMA_URL" in msg
    # Header line present so the operator knows it came from this validator.
    assert "contact_syncer config invalid" in msg


def test_pair_check_and_required_flag_compose() -> None:
    """Pair-check fires AND require_qdrant fires -> both surface together."""
    with pytest.raises(RuntimeError) as excinfo:
        config.validate_required(
            require_qdrant=True,
            _values=_vals(CARDDAV_URL="https://carddav.example/"),
        )
    msg = str(excinfo.value)
    assert "CARDDAV" in msg
    assert "QDRANT_URL" in msg


# -- Default-call sanity ----------------------------------------------------


def test_no_flags_no_values_passes() -> None:
    """validate_required() with everything empty and no flags -> no-op."""
    config.validate_required(_values=_vals())
