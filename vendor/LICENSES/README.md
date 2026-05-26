# Third-Party Licence Texts

This directory holds the canonical, verbatim licence texts for every
permissive licence under which Ostler ships third-party software.

The installer copies this directory to `~/.ostler/LICENSES/` so the
licence text is available offline, and so any compliance review or
auditor can inspect what we redistribute under each licence.

## Files

| File | SPDX | Used by |
|---|---|---|
| `Apache-2.0.txt` | Apache-2.0 | bcrypt, aiokafka, aiofiles, sentence-transformers, diskcache, python-multipart, vobject, phonenumbers, qdrant-client, requests, cryptography (dual), realm-swift, realm-core, swift-transformers, swift-jinja, swift-collections, swift-crypto, swift-asn1, swift-argument-parser, FluidAudio, Qdrant, Oxigraph (dual), Qwen 3.5 (model), nomic-embed-text (model), OpenAI Privacy Filter (model) |
| `MIT.txt` | MIT | fastapi, fastapi-users, python-jose, pydantic, pydantic-settings, redis (Python client), sqlalchemy, aiosqlite, gunicorn, beautifulsoup4, openpyxl, msoffcrypto-tool, aiolimiter, mcp, rich, PyYAML, sounddevice, anthropic, WhisperKit, llama.swift, yyjson, Ollama, OpenAI Whisper (model), llama.cpp |
| `BSD-2-Clause.txt` | BSD-2-Clause | mkdocs |
| `BSD-3-Clause.txt` | BSD-3-Clause | uvicorn, httpx, click, torch, rdflib, lxml, numpy, Valkey, cryptography (dual), passlib |
| `Zlib.txt` | Zlib | pysqlcipher3 |
| `MPL-2.0.txt` | MPL-2.0 | orjson (component) |
| `MODELS.md` | various | catalogue of bundled local models and their upstream terms |

## What's NOT in this directory

- **MIT-licensed components by the Software Freedom Law Center** are
  individually not reproduced. The MIT template above is the canonical
  text; each component supplies its own copyright line at distribution.
- **Apache-2.0 NOTICE files** are reproduced under `NOTICES/<package>/NOTICE`
  for every shipped Apache-2.0 component whose upstream supplies one. As of
  2026-04-28: `swift-crypto` and `swift-asn1` (both used by CM031 and on the
  Hub via `cryptography` and TLS code paths). All other Apache-2.0 components
  in `../THIRD_PARTY_NOTICES.md` were verified to have no upstream NOTICE
  file on 2026-04-28; Apache §4(d) is satisfied for those by reproducing the
  LICENSE alone.
- **LGPL-3.0 components** because Ostler does not currently ship any.
  `pynput` (CM045 voice) is post-launch; if and when CM045 ships, we
  will either replace the dependency or add `LGPL-3.0.txt` here with
  the appropriate compliance documentation.
- **Custom restrictive licences** (Llama Community Licence, Gemma Terms
  of Use). If a user swaps in a non-default model under one of those
  licences, they're responsible for accepting the upstream terms; we
  do not redistribute the model weights, only point at them.

## Source of truth

These texts are taken verbatim from the SPDX licence list:
https://github.com/spdx/license-list-data/tree/main/text

They are widely reproduced and considered stable artefacts in the
free-software ecosystem. If a future SPDX update changes any of them
(very rare), refresh from the same source and bump the date below.

**Last refreshed:** 2026-04-28

## Cross-references

- Master attribution catalogue: `../THIRD_PARTY_NOTICES.md`
- Action plan rationale: `../OSS_LICENSE_ACKNOWLEDGEMENTS_PLAN.md`
- Public mirror (web): `https://creativemachines.ai/ostler/licenses.html`
- Hub install location after `install.sh`: `~/.ostler/LICENSES/`
