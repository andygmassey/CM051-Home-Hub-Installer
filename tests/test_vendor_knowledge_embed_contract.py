#!/usr/bin/env python3
"""Vendored cm024 knowledge embed-contract guard (#519).

The Knowledge convert->embed last mile is what populates the
``evernote_knowledge`` Qdrant collection that the CM044 wiki Knowledge
section + RAG-over-notes read. The Doctor "Import Evernote" flow forks
``ostler-knowledge convert ... --and-then embed ...`` (see
vendor/doctor/agent/import_evernote.py), where the embed phase is

    ostler-knowledge embed <staging> \
        --collection evernote_knowledge \
        --embedding-model nomic-embed-text \
        --max-compartment-level 2 \
        --db-path <metadata.db>

For that to work, the VENDORED cm024 CLI (the copy that actually ships
in the installer .app, src/-layout twin of the upstream
ostler_knowledge package) must:

  1. expose the ``--max-compartment-level`` flag on ``embed`` (else the
     Doctor import aborts on an unknown option and the collection stays
     empty);
  2. thread that cap through to the embed pipeline;
  3. apply the L3 privacy gate as a pure, fail-closed function (a
     private note must never become searchable);
  4. default the embedding model to nomic-embed-text (768 dims) so the
     vectors match the 768-dim collection the installer pre-creates --
     the legacy all-minilm (384) default makes every upsert fail the
     dimension check and leaves Knowledge silently empty.

This guard locks all four against the vendored copy so a future
re-vendor cannot silently drop the gap-closer.

Network-free. Needs only ``click`` (already a vendored-CLI dep).
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDORED_CM024 = REPO_ROOT / "vendor" / "cm024_knowledge"

pytest.importorskip("click")
pytest.importorskip("qdrant_client")
pytest.importorskip("yaml")

# The vendored package uses the literal ``src`` package name with
# relative intra-package imports (``from .ingestion ...``), so we import
# it as ``src.cli`` with the cm024 vendor root on sys.path -- exactly the
# layout the installer pip-installs.
if str(VENDORED_CM024) not in sys.path:
    sys.path.insert(0, str(VENDORED_CM024))

src_cli = pytest.importorskip("src.cli")
from src.cli import cli, embed_cmd, _note_passes_privacy_gate  # noqa: E402
from src.ingestion.embedder import Embedder  # noqa: E402
from src.storage.qdrant_store import QdrantStore  # noqa: E402

from click.testing import CliRunner  # noqa: E402


def _option_default(command, option_name):
    for param in command.params:
        if param.name == option_name:
            return param.default
    raise AssertionError(f"option {option_name!r} not found on {command.name}")


# -- Privacy gate (pure, security-critical) ----------------------------

def test_gate_none_cap_embeds_everything():
    for level in (0, 1, 2, 3, 99):
        assert _note_passes_privacy_gate(level, None) is True


def test_gate_cap_2_excludes_l3():
    assert _note_passes_privacy_gate(3, 2) is False
    assert _note_passes_privacy_gate(2, 2) is True
    assert _note_passes_privacy_gate(1, 2) is True
    assert _note_passes_privacy_gate(0, 2) is True


def test_gate_cap_excludes_anything_above():
    assert _note_passes_privacy_gate(4, 2) is False
    assert _note_passes_privacy_gate(3, 1) is False


def test_gate_garbled_level_fails_closed():
    # Malformed frontmatter must not leak a private note into search.
    assert _note_passes_privacy_gate(None, 2) is False
    assert _note_passes_privacy_gate("private", 2) is False
    assert _note_passes_privacy_gate("", 2) is False


def test_gate_string_numeric_level_is_honoured():
    assert _note_passes_privacy_gate("3", 2) is False
    assert _note_passes_privacy_gate("2", 2) is True


# -- embed command contract (the flag the Doctor relies on) ------------

def test_embed_exposes_max_compartment_level_option():
    result = CliRunner().invoke(cli, ["embed", "--help"])
    assert result.exit_code == 0, result.output
    assert "--max-compartment-level" in result.output


def test_embed_threads_cap_into_pipeline(monkeypatch, tmp_path):
    captured = {}

    async def fake_run_embed(*args, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(src_cli, "_run_embed", fake_run_embed)

    vault = tmp_path / "vault"
    vault.mkdir()
    result = CliRunner().invoke(
        cli, ["embed", str(vault), "--max-compartment-level", "2"],
    )
    assert result.exit_code == 0, result.output
    assert captured.get("max_compartment_level") == 2


# -- embed model / dimension contract ----------------------------------

def test_embed_default_model_is_nomic_768():
    assert _option_default(embed_cmd, "embedding_model") == "nomic-embed-text"


def test_embed_default_collection_is_evernote_knowledge():
    assert _option_default(embed_cmd, "collection") == "evernote_knowledge"


def test_nomic_dimension_matches_qdrant_store_default():
    nomic_dim = Embedder.MODEL_CONFIGS["nomic-embed-text"]["dimensions"]
    assert nomic_dim == 768
    store = QdrantStore()
    assert store.vector_size == 768
    assert store.vector_size == nomic_dim


def test_minilm_fossil_dim_would_mismatch():
    assert Embedder.MODEL_CONFIGS["all-minilm"]["dimensions"] == 384
    assert Embedder.MODEL_CONFIGS["all-minilm"]["dimensions"] != 768
