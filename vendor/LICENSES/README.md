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
| `MPL-2.0.txt` | MPL-2.0 | orjson (component); MPL-2.0-permitted transitive Rust crates in the Ostler Assistant daemon |
| `OFL-1.1.txt` | OFL-1.1 | Bundled web-UI fonts in the Ostler Assistant daemon: Outfit, IBM Plex Sans, JetBrains Mono |
| `MODELS.md` | various | catalogue of bundled local models and their upstream terms |

## What's NOT in this directory

- **MIT-licensed components by the Software Freedom Law Center** are
  individually not reproduced. The MIT template above is the canonical
  text; each component supplies its own copyright line at distribution.
- **Apache-2.0 NOTICE files** are reproduced under `NOTICES/<package>/NOTICE`
  for every shipped Apache-2.0 component whose upstream supplies one. As of
  2026-04-28: `swift-crypto`, `swift-asn1`, and the **Ostler Assistant
  daemon** (`ostler-assistant` / ex-ZeroClaw; NOTICE reproduced at
  `NOTICES/ostler-assistant/NOTICE`, carrying the ZeroClaw Labs copyright
  and the Verifiable Intent attribution). `swift-crypto`/`swift-asn1` are
  used by CM031 and on the Hub via `cryptography` and TLS code paths. All
  other Apache-2.0 components
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

## Ostler Assistant daemon (Rust engine) and outstanding licence texts

The core engine ships as the **Ostler Assistant daemon** (`ostler-assistant`,
a dual MIT-or-Apache soft-fork of ZeroClaw). Its full statically-linked Rust
dependency tree (1,207 crates, `Cargo.lock`) is constrained to a permissive
allow-list enforced by `deny.toml` (`cargo-deny`). See the daemon section in
`../THIRD_PARTY_NOTICES.md` for the enforced allow-list and the verified major
crates.

**Licence texts still to add here for a complete offline bundle** (the Rust
allow-list references SPDX licences whose verbatim text is not yet in this
directory; fetch verbatim from the SPDX license-list-data repo -- could not be
reproduced offline in this pass, human follow-up):

- `ISC.txt` (ISC) -- e.g. `rustls-webpki`, `ring` (dual)
- `OFL-1.1.txt` (OFL-1.1) -- **DONE this pass** (bundled fonts)
- `Unicode-3.0.txt` / `Unicode-DFS-2016.txt` (Unicode data crates)
- `OpenSSL.txt` (OpenSSL) -- `ring` component
- `BSL-1.0.txt` (Boost Software License 1.0)
- `CC0-1.0.txt` (CC0-1.0)
- `CDLA-Permissive-2.0.txt` (CDLA-Permissive-2.0)
- Apache-2.0 WITH LLVM-exception -- document the LLVM exception text
  alongside `Apache-2.0.txt`.

Until these are added, the deployed `~/.ostler/LICENSES/` bundle is complete
for the Python/Swift/binary components but incomplete for a small set of the
daemon's transitive Rust licences. This is an attribution-completeness gap,
not a licence-compatibility problem: every licence in the tree is permissive
and machine-enforced by `deny.toml`.

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
