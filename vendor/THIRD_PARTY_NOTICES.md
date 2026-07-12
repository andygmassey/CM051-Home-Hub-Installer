# Third-Party Notices

This file is the source of truth for every third-party component that ships
in the Ostler product (parent: Creative Machines). It satisfies attribution
requirements under MIT, BSD-2-Clause, BSD-3-Clause, Apache 2.0, and
similar permissive licences.

Three downstream surfaces mirror this file:

- **iOS app:** Settings -> About -> Acknowledgements (CM031, generated from
  this file at release time).
- **Mac Hub installer:** copied to `~/.ostler/THIRD_PARTY_NOTICES.md`
  on install; printable via `ostler --licenses`.
- **Website:** rendered to `licenses.html` on the marketing site.

When a new third-party dependency is added anywhere in the product, it
must land here first. The downstream surfaces are mechanical mirrors and
must not be hand-edited.

> **Status (2026-04-28):** v0.1 draft. Versions extracted from manifest
> files; SPDX identifiers marked **[VERIFY]** were inferred from common
> upstream knowledge and need a final pass against each upstream's actual
> LICENSE file before launch. Components with no marker have been spot-checked.

---

## Headline issues to resolve before launch

1. **`pynput` is LGPL-3.0** (used by CM045 PWG Voice Interaction). LGPL
   has stricter dynamic-linking requirements than MIT/Apache and is
   awkward in a closed-source bundle. CM045 is post-launch – either
   defer the dependency, replace with an MIT alternative
   (e.g. `keyboard`, `evdev`), or document the LGPL boundary
   precisely. **Action: do not ship CM045 in the launch installer
   without resolving.**
2. **Local model licences** vary widely: Apache 2.0 (Qwen, Whisper,
   nomic-embed), Llama Community Licence (Llama family – restrictive),
   Gemma Terms of Use (Google – restrictive). Whichever model the Hub
   ships as default needs its full licence reproduced and the user
   must be informed of the bundled-model terms during install.
   **Action: lock the default-model choice and reproduce the full
   licence text for it (not just SPDX) before launch.**
3. ~~**Redis 7+ relicensed to RSAL/SSPL.**~~ **RESOLVED 2026-04-28.**
   Migrated all shipped configs from `redis:7-alpine` to
   `valkey/valkey:8-alpine` (Valkey is the BSD-3-Clause Linux
   Foundation fork; drop-in compatible at the protocol level and
   ships `redis-server` / `redis-cli` aliases so existing healthchecks
   and commands work unchanged). Files updated: HR015 SETUP_GUIDE.md
   + SECURITY_LOCALHOST_AUTH_DESIGN.md, CM019 docker-compose.yml +
   docker-compose.v2.yml + .github/workflows/multi-arch.yml,
   CM043/deployment/single-mac/docker-compose.yml, CM051/install.sh.
   Andy's running Mac Mini deployment still has `redis:7-alpine`
   live; rotation to Valkey on the active container is a separate
   ops task (low risk: `docker pull valkey/valkey:8-alpine`,
   recreate the container).
4. **NOTICE-file bundling for Apache 2.0 components.** Apache §4(d)
   requires reproducing each upstream's `NOTICE` file (if it exists)
   verbatim in our bundle. Status after the 2026-04-28 sweep across
   all Apache-2.0 components in this catalogue:
   - **NOTICE files bundled:** `swift-crypto`, `swift-asn1`, and the
     **Ostler Assistant daemon** (`ostler-assistant` / ex-ZeroClaw, dual
     MIT-or-Apache -- its upstream `NOTICE` ships at
     `LICENSES/NOTICES/ostler-assistant/NOTICE`, carrying the ZeroClaw
     Labs copyright and the Verifiable Intent attribution). All are
     reproduced verbatim under `LICENSES/NOTICES/<package>/NOTICE` and
     shipped via the installer to `~/.ostler/LICENSES/NOTICES/`.
   - **No upstream NOTICE file (verified 2026-04-28; Apache §4 satisfied
     by reproducing the LICENSE alone):** `realm-swift`, `realm-core`,
     `FluidAudio`, `swift-transformers`, `swift-jinja`,
     `swift-collections`, `swift-argument-parser`, Qdrant, Oxigraph.
   - **`torch`:** BSD-3-Clause primary plus vendored components
     (NVIDIA, Intel MKL, Caffe2, FBGEMM) each with their own notices.
     We do not redistribute `torch` directly – pip fetches the wheel at
     install time and the wheel's own metadata carries the third-party
     notices. No bundling required on our side.
   - **`orjson`:** no upstream NOTICE; contains MPL-2.0 components
     alongside Apache-2.0/MIT. MPL is weak-copyleft – the MPL portions
     must be source-available on request. The package is pip-fetched at
     install time (we do not redistribute), and source lives at
     `https://github.com/ijl/orjson` (LICENSE-MPL-2.0 at repo root).
     The link is reproduced in the public Acknowledgements page.
   - **`pysqlcipher3` / SQLCipher / OpenSSL:** `pysqlcipher3` is Zlib;
     it dynamically links against the system or Homebrew OpenSSL at
     runtime. We do not statically link OpenSSL, so the §4 attribution
     burden does not transfer to our bundle.
5. **WhisperKit / OpenAI Whisper models** are MIT but the `openai/whisper`
   model weights themselves are released under MIT too – confirm any
   fine-tuned variants we ship retain MIT compatibility.

---

## Python packages (Hub services)

Used by the Mac Hub installer in `~/.ostler/python/`. All Python
packages here ship as bundled Python source (not vendored) – installed
into a managed venv at install time from PyPI mirrors. Versions follow
each manifest's pin / range.

### Core PWG services (CM019)

| Package | Version | Licence | Used by |
|---|---|---|---|
| fastapi | ≥0.109.0 | MIT | gateway, ingest, mcp, doctor, IT-guy-cloud |
| uvicorn | ≥0.27.0 | BSD-3-Clause | gateway, ingest, doctor |
| fastapi-users | ≥13.0.0 | MIT | gateway (auth) |
| python-jose | ≥3.3.0 | MIT | gateway (JWT) |
| passlib | ≥1.7.4 | BSD-3-Clause | gateway (password hashing) |
| bcrypt | ≥4.0.0,<5.0.0 | Apache-2.0 | gateway |
| pydantic | ≥2.5.0 | MIT | all services |
| pydantic-settings | ≥2.1.0 | MIT | all services |
| httpx | ≥0.25.0 | BSD-3-Clause | all services |
| redis (Python client) | ≥5.0.0 | MIT | gateway, extractor |
| aiokafka | ≥0.10.0 | Apache-2.0 | gateway, ingest (legacy, see Redis Streams migration) |
| sqlalchemy | ≥2.0.0 | MIT | gateway |
| aiosqlite | ≥0.19.0 | MIT | gateway |
| gunicorn | ≥21.0.0 | MIT | gateway (production WSGI) |
| aiofiles | ≥23.2.0 | Apache-2.0 | ingest |
| sentence-transformers | ≥2.2.0 | Apache-2.0 | ingest, mcp |
| torch | ≥2.1.0 | BSD-3-Clause [VERIFY] (see: https://github.com/pytorch/pytorch/blob/main/LICENSE – BSD-3-Clause primary, bundled vendored components carry additional notices) | ingest (transitive of sentence-transformers) |
| rdflib | ≥7.0.0 | BSD-3-Clause | ingest |
| orjson | ≥3.9.0 | MPL-2.0 AND (Apache-2.0 OR MIT) | ingest |
| python-multipart | ≥0.0.6 | Apache-2.0 | ingest |
| beautifulsoup4 | ≥4.12.0 | MIT | ingest (HTML extraction) |
| lxml | ≥5.0.0 | BSD-3-Clause | ingest |
| openpyxl | ≥3.1.0 | MIT | ingest (xlsx parser) |
| msoffcrypto-tool | ≥5.0.0 | MIT | ingest (encrypted office docs) |
| click | ≥8.1.0 | BSD-3-Clause | enrich, cli |
| diskcache | ≥5.6.0 | Apache-2.0 | enrich (LLM result cache) |
| aiolimiter | ≥1.1.0 | MIT | enrich |
| mcp (Anthropic Model Context Protocol) | ≥1.0.0 | MIT | mcp |
| rich | ≥13.7.0 | MIT | cli |

### People graph (CM041)

| Package | Version | Licence | Used by |
|---|---|---|---|
| vobject | ≥0.9.6 | Apache-2.0 | contact_syncer (vCard parser) |
| phonenumbers | ≥8.13.0 | Apache-2.0 | contact_syncer, meeting_syncer, whatsapp_bridge |
| qdrant-client | ≥1.15,<2.0 | Apache-2.0 | contact_syncer, meeting_syncer, whatsapp_bridge |
| pyyaml | ≥6.0 | MIT | whatsapp_bridge |

### Conversation processing (CM048)

| Package | Version | Licence | Used by |
|---|---|---|---|
| httpx | ≥0.27,<1.0 | BSD-3-Clause | processor (Ollama client) |
| PyYAML | ≥6.0 | MIT | processor |

### Wiki (CM044)

| Package | Version | Licence | Used by |
|---|---|---|---|
| httpx | ≥0.27,<1.0 | BSD-3-Clause | wiki compiler |
| pyyaml | ≥6.0,<7.0 | MIT | wiki compiler |
| (transitive) mkdocs-material | latest | MIT | static-site theme [verify version-pin at build] |
| (transitive) mkdocs | latest | BSD-2-Clause | static-site engine |

### Voice interaction (CM045) – **post-launch only**

| Package | Version | Licence | Notes |
|---|---|---|---|
| sounddevice | ≥0.4.6 | MIT | OK |
| numpy | ≥1.24 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | OK (compound: BSD-3-Clause primary, vendored components carry the others) |
| httpx | ≥0.25 | BSD-3-Clause | OK |
| pyyaml | ≥6.0 | MIT | OK |
| **pynput** | **≥1.7.6** | **LGPL-3.0** | **🔴 see headline issue #1** |

### WhatsApp mining (CM047)

| Package | Version | Licence | Used by |
|---|---|---|---|
| requests | ≥2.31.0 | Apache-2.0 | mining scripts |
| qdrant-client | ≥1.9.0 | Apache-2.0 | mining scripts |

### Security module (HR015 ostler_security)

| Package | Version | Licence | Used by |
|---|---|---|---|
| cryptography | ≥46.0.1,<47.0.0 | Apache-2.0 OR BSD-3-Clause | key derivation, AES-GCM, TLS |
| pysqlcipher3 | ≥1.2.0,<2.0.0 | Zlib (Python wrapper); upstream SQLCipher is BSD-3-Clause-style with OpenSSL dependency – confirm OpenSSL terms when bundling | encrypted SQLite |
| onnxruntime | ≥1.18.0,<2.0.0 | MIT | OPF privacy classifier inference (`opf_filter.py`) |
| tokenizers | ≥0.20.0,<1.0.0 | Apache-2.0 | OPF tokeniser (HF Rust binding; used directly to avoid the full `transformers` dependency) |
| huggingface_hub | ≥0.25.0,<1.0.0 | Apache-2.0 | OPF model + tokenizer download from the pinned upstream revision |
| numpy | ≥1.24.0,<3.0.0 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | OPF inference (logits softmax / argmax) |

### Doctor / IT-guy diagnostic services (HR015)

| Package | Version | Licence | Used by |
|---|---|---|---|
| anthropic (SDK) | ≥0.40.0 | MIT | IT-guy-cloud (Claude API) |

### CM050 license generator (server-side, not shipped to user)

| Package | Version | Licence | Notes |
|---|---|---|---|
| cryptography | ≥42.0 | Apache-2.0 OR BSD-3-Clause | Build-time only (license-key signing) |
| click | ≥8.1 | BSD-3-Clause | Build-time only |

---

## Rust engine – Ostler Assistant daemon (the core engine)

The Ostler Home Hub is powered by the **Ostler Assistant** daemon, a
Rust binary that ships in the Hub installer as `OstlerAssistant.app`
(`Contents/MacOS/ostler-assistant`). It is a **soft-fork of ZeroClaw**
and is the single largest third-party component in the product. It was
absent from earlier drafts of this file; it is the primary attribution
obligation.

| Component | Version | Licence | Source |
|---|---|---|---|
| Ostler Assistant daemon (crate `zeroclawlabs`, ex-ZeroClaw) | v0.4.28 (release git tag; workspace `Cargo.toml` version field frozen at `0.4.1` – releases are tracked by git tag) | **MIT OR Apache-2.0** (dual) | github.com/zeroclaw-labs/zeroclaw (upstream) -> Ostler soft-fork |

**Copyright:** `Copyright 2025 ZeroClaw Labs` plus Ostler / Creative
Machines fork contributions. Dual-licensed MIT **or** Apache-2.0 at the
user's choice; contributors grant rights under both.

**Apache §4(d) NOTICE:** the upstream ships a `NOTICE` file. It is
reproduced verbatim at `LICENSES/NOTICES/ostler-assistant/NOTICE` and
installed to `~/.ostler/LICENSES/NOTICES/ostler-assistant/NOTICE`. It
also carries the attribution for the **Verifiable Intent** specification
(`src/verifiable_intent/` is a clean-room Rust reimplementation of the VI
open spec by *agent-intent*, Apache-2.0 – github.com/agent-intent/verifiable-intent).

### Statically-linked Rust crates

The daemon binary statically links its full Rust dependency tree  – 
**1,207 crates** as pinned in `Cargo.lock`. Every crate's licence is
constrained by an **enforced `cargo-deny` allow-list** (`deny.toml`,
`[licenses] allow = […]`, `unused-allowed-license = "allow"`), which
fails CI if any crate carries a licence outside the permissive set below.
This is a verified, machine-enforced statement – not a manual survey:

> **Allowed (and therefore the complete set of licences present in the
> tree):** MIT, Apache-2.0, Apache-2.0 WITH LLVM-exception, BSD-2-Clause,
> BSD-3-Clause, ISC, Unicode-3.0, Unicode-DFS-2016, OpenSSL, Zlib,
> MPL-2.0, CDLA-Permissive-2.0, 0BSD, BSL-1.0, CC0-1.0.

No GPL / LGPL / AGPL / SSPL is present – those licences are **denied** by
`deny.toml` and would fail the build. **MPL-2.0** (weak copyleft) is
permitted and may be present in a handful of transitive crates; the MPL
portions are source-available from their upstreams on request. The
authoritative per-crate list is `Cargo.lock`; the standard release
practice is to regenerate a `cargo-about` bundle at build time from it.

**Verified major direct crates** (licences read from the local crate
metadata / `Cargo.toml`, not guessed):

| Crate | Role | Licence |
|---|---|---|
| tokio | async runtime | MIT |
| serde / serde_json | serialisation | MIT OR Apache-2.0 |
| reqwest | HTTP client | MIT OR Apache-2.0 |
| hyper / hyper-util | HTTP core | MIT |
| axum | HTTP server (gateway) | MIT |
| rustls (+ rustls-webpki) | TLS | Apache-2.0 OR ISC OR MIT (webpki: ISC) |
| ring | crypto primitives | Apache-2.0 AND ISC |
| chacha20poly1305 / sha2 / hmac | crypto | Apache-2.0 OR MIT / MIT OR Apache-2.0 |
| clap / clap_complete | CLI parsing | MIT OR Apache-2.0 |
| ratatui / crossterm | TUI | MIT |
| chrono / chrono-tz | date-time | MIT OR Apache-2.0 |
| uuid / rand / regex | utilities | MIT OR Apache-2.0 |
| anyhow / thiserror | error handling | MIT OR Apache-2.0 |
| image | image decode (png/jpeg) | MIT OR Apache-2.0 |
| zip | archive | MIT |
| flate2 / tar | compression | MIT OR Apache-2.0 |
| rusqlite (bundled SQLite) | local store | MIT |
| lettre | SMTP (Apple Mail bridge) | MIT |
| async-imap | IMAP | MIT OR Apache-2.0 |
| mail-parser | email parsing | Apache-2.0 OR MIT |
| nostr-sdk | Nostr channel (optional) | MIT |
| toml / toml_edit | config | MIT OR Apache-2.0 |

---

## Swift packages (iOS – CM031)

Used by the iOS Companion app. All bundled with the App Store binary.
Versions from `Package.resolved`.

| Package | Version | Licence | Source |
|---|---|---|---|
| WhisperKit | 0.18.0 | MIT | github.com/argmaxinc/WhisperKit |
| FluidAudio | 0.14.1 | Apache-2.0 | github.com/FluidInference/FluidAudio |
| realm-swift | 10.54.6 | Apache-2.0 (incl. NOTICE – see headline #4) | github.com/realm/realm-swift |
| realm-core | 14.14.0 | Apache-2.0 (transitive of realm-swift) | github.com/realm/realm-core |
| llama.swift | 2.8931.0 | MIT | github.com/mattt/llama.swift |
| swift-transformers | 1.1.9 | Apache-2.0 | github.com/huggingface/swift-transformers |
| swift-jinja | 2.3.5 | Apache-2.0 | github.com/huggingface/swift-jinja |
| swift-collections | 1.4.1 | Apache-2.0 | github.com/apple/swift-collections |
| swift-crypto | 4.5.0 | Apache-2.0 | github.com/apple/swift-crypto |
| swift-asn1 | 1.7.0 | Apache-2.0 | github.com/apple/swift-asn1 |
| swift-argument-parser | 1.7.1 | Apache-2.0 | github.com/apple/swift-argument-parser |
| yyjson | 0.12.0 | MIT | github.com/ibireme/yyjson |

---

## Swift packages (macOS – CM042 RemoteCapture)

Used by the desktop call-recording companion. Bundled with the macOS
binary distributed via the Hub installer.

| Package | Version | Licence | Source |
|---|---|---|---|
| WhisperKit | 0.18.0 | MIT | github.com/argmaxinc/WhisperKit |
| swift-transformers | 1.1.9 | Apache-2.0 | github.com/huggingface/swift-transformers |
| swift-jinja | 2.3.5 | Apache-2.0 | github.com/huggingface/swift-jinja |
| swift-collections | 1.4.1 | Apache-2.0 | github.com/apple/swift-collections |
| swift-crypto | 4.3.1 | Apache-2.0 | github.com/apple/swift-crypto |
| swift-asn1 | 1.6.0 | Apache-2.0 | github.com/apple/swift-asn1 |
| swift-argument-parser | 1.7.1 | Apache-2.0 | github.com/apple/swift-argument-parser |
| yyjson | 0.12.0 | MIT | github.com/ibireme/yyjson |

---

## Node.js packages (Cloudflare Worker – CM050)

Used by the appcast server (hosted on Cloudflare Workers, not bundled
with the user product). Listed for completeness; users do not receive
these as part of the install.

| Package | Version | Licence | Notes |
|---|---|---|---|
| fast-xml-parser | ^5.7.1 | MIT | Sparkle appcast parsing |
| typescript | ^5.5.0 | Apache-2.0 | Build-time only |
| wrangler | ^4.0.0 | MIT OR Apache-2.0 | Build-time only (Cloudflare CLI) |
| vitest | ^4.1.5 | MIT | Test runner only |
| @cloudflare/vitest-pool-workers | ^0.14.9 | MIT | Test runner only |
| @cloudflare/workers-types | ^4.20240725.0 | MIT OR Apache-2.0 | Type defs only |
| @types/node | ^25.6.0 | MIT | Type defs only |

---

## Bundled fonts

The Ostler Assistant daemon ships web-UI fonts inside the app bundle at
`OstlerAssistant.app/Contents/Resources/web/dist/fonts/`. All three
families are under the **SIL Open Font License 1.1 (OFL-1.1)**. The full
OFL-1.1 text ships in that directory as `OFL.txt` and is also reproduced
at `LICENSES/OFL-1.1.txt`.

| Font | Version | Licence | Copyright | Source |
|---|---|---|---|---|
| Outfit | bundled at build | OFL-1.1 | Copyright 2021 The Outfit Project Authors (verified from shipped `OFL.txt`) | github.com/Outfitio/Outfit-Fonts |
| IBM Plex Sans | 3.005 | OFL-1.1 | Copyright 2018 IBM Corp. (verified from shipped font name-table) | github.com/IBM/plex |
| JetBrains Mono | bundled at build | OFL-1.1 | Copyright 2020 The JetBrains Mono Project Authors (upstream standard line – confirm on next refresh) | github.com/JetBrains/JetBrainsMono |

> **OFL compliance follow-up (human):** the shipped `OFL.txt` currently
> reproduces only Outfit's copyright header. OFL-1.1 §clause requires each
> font's own copyright + "Reserved Font Name" notice to travel with it.
> Append the IBM Plex Sans and JetBrains Mono copyright lines to the
> bundled `OFL.txt` (or ship a per-family header) before the next cut.

The **wiki** (CM044, MkDocs Material theme) also serves fonts and icon
assets bundled by MkDocs Material itself (Roboto, Apache-2.0; Material
Design Icons, Apache-2.0). These are pulled in transitively by the theme;
verify the exact set against the theme version pinned at wiki-image build.

---

## Bundled binaries / runtime services

These ship alongside the Python / Swift code and run as separate
processes managed by the Hub. The Hub installer pulls each from its
upstream release page or a bundled tarball.

| Component | Version | Licence | Distribution mode |
|---|---|---|---|
| Qdrant (vector DB) | latest pinned at install | Apache-2.0 | Bundled binary / Docker image |
| Oxigraph (RDF triple store) | latest pinned at install | Apache-2.0 OR MIT | Bundled binary / Docker image |
| Valkey (cache + message bus, replaces Redis) | `valkey/valkey:8-alpine` | BSD-3-Clause | Bundled Docker image; protocol-compatible with Redis |
| Ollama (local LLM runtime) | latest pinned at install | MIT | Bundled binary |
| Whisper STT (server-side) | latest pinned | MIT | Optional Docker image (CM042 prefers WhisperKit on-device) |
| Google Workspace CLI (`gws`) | v0.22.5 (SHA256-pinned per arch) | Apache-2.0 | Downloaded at install time from github.com/googleworkspace/cli releases; placed at /usr/local/bin/gws. Used by CM041 ical-server.py for Gmail + Google Calendar bridges. |

---

## Local model weights

Models lazy-downloaded on first use. The user is informed before
download. Each model carries its upstream licence; ours is to surface
the choice and reproduce the licence text.

| Model | Default version | Licence | Used by |
|---|---|---|---|
| Qwen 3.5 9B | qwen3.5:9b (Q4_0) | Apache-2.0 (Alibaba) | Marvin assistant (default) |
| Qwen 3.5 35B-A3B | qwen3.5:35b-a3b | Apache-2.0 (Alibaba) | enrichment / extraction |
| nomic-embed-text | latest | Apache-2.0 | embeddings |
| OpenAI Whisper (medium-v3-turbo) | via WhisperKit | MIT | transcription |
| OpenAI Privacy Filter (OPF) | `openai/privacy-filter` @ `7ffa9a04…29385b` (ONNX export) | Apache-2.0 (per upstream – see `OPF_INTEGRATION_SCOPING.md`) | privacy classifier (loaded via `onnxruntime` + `tokenizers`, **not** `transformers`/`torch`) |
| llama.cpp (via llama.swift) | bundled at app build | MIT | iOS on-device LLM runtime |

> Some users may swap in alternative local models (Llama, Gemma, DeepSeek)
> via Ollama. Those alternatives carry their own upstream licences which
> are not reproduced here – the user is responsible for accepting the
> chosen model's terms. The default-shipped models above are the only
> ones we attribute by default.

---

## Apple frameworks (iOS / macOS) – system-provided

The following are linked at runtime from the operating system, not
bundled or redistributed. No attribution required, listed for
completeness:

- ActivityKit, BackgroundTasks, AVFoundation, ScreenCaptureKit,
  CoreLocation, Contacts, EventKit, HealthKit, MusicKit, Network,
  Security, UIKit, SwiftUI, WidgetKit, WatchKit.

---

## Verification status (2026-04-28)

| Section | Manifest extracted | SPDX confidence | Action before launch |
|---|---|---|---|
| Python (CM019/041/044/045/047/048) | ✅ | high (verified 2026-04-28 against PyPI metadata) | torch retains [VERIFY] – bundled vendored components need NOTICE handling |
| Python (HR015 services) | ✅ | high (verified 2026-04-28) | pysqlcipher3 corrected to Zlib; SQLCipher OpenSSL bundling still needs review |
| Swift (CM031, CM042) | ✅ | high (verified 2026-04-28 against GitHub LICENSE files) | extract realm-core NOTICE file, append to bundle; FluidAudio corrected MIT -> Apache-2.0 |
| Node (CM050 worker) | ✅ | high (verified 2026-04-28 against npm registry) | not user-shipped, low priority |
| Bundled binaries | ✅ | high (well-known) | Oxigraph confirmed dual Apache-2.0 OR MIT; Valkey resolves headline #3 |
| Local models | ✅ | high | reproduce full default-model licence in installer |

The five headline issues at the top of this file are the actual launch
blockers. Everything else is mechanical verification work.

---

## Cross-references

- **Plan and rationale:** `OSS_LICENSE_ACKNOWLEDGEMENTS_PLAN.md`
- **OPF specifically:** `OPF_INTEGRATION_SCOPING.md`
- **Distribution surfaces (downstream of this file):**
  - iOS Acknowledgements view: CM031 (TODO, not yet built)
  - Hub installer flag: CM051 `ostler --licenses` (TODO)
  - Website page: `licenses.html` (TODO)
- **Pre-existing precedent:** Auvi / Auvi Trade iOS Acknowledgements
  (Andy's earlier MIT-attribution work, informal context only)
