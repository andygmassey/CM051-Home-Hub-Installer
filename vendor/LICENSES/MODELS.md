# Local Model Licences

The default Ostler install ships these local models under their upstream
licences. The Hub downloads them lazy on first use, after informing the
user. This document satisfies headline issue #2 in
`../THIRD_PARTY_NOTICES.md`: lock the default-model choice and reproduce
the licence text accessibly.

## Default models

| Model | Role | Licence | Licence text |
|---|---|---|---|
| **Qwen 3.5 9B** | Default assistant model (instruction-tuned chat) | Apache-2.0 | `Apache-2.0.txt` (this directory) |
| Qwen 3.5 35B-A3B | Enrichment / extraction (heavier passes) | Apache-2.0 | `Apache-2.0.txt` |
| nomic-embed-text | Vector embeddings for semantic search | Apache-2.0 | `Apache-2.0.txt` |
| OpenAI Whisper (medium-v3-turbo via WhisperKit) | Speech-to-text | MIT | `MIT.txt` |
| OpenAI Privacy Filter (OPF) | Local PII redaction (pre-flight) | Apache-2.0 | `Apache-2.0.txt` |
| llama.cpp (via llama.swift) | iOS on-device inference runtime | MIT | `MIT.txt` |

## Default-model decision

**Default Ostler assistant model = Qwen 3.5 9B (Apache 2.0).** Per
project documentation: chosen for tool-calling fidelity at the size
class, runs in ~6.6 GB Q4 quantisation. The Apache 2.0 licence is
reproduced verbatim in `Apache-2.0.txt` in this directory; the user can
read it at any time via `bash install.sh --licenses` or by opening the
file directly.

## Alternative models (user-supplied, not redistributed by Ostler)

If a user pulls an alternative model via Ollama (Llama, Gemma, DeepSeek,
Mistral, etc.), they accept the upstream licence terms themselves. We do
not redistribute the weights; Ollama or the user's chosen runtime fetches
them. The licences below are NOT reproduced here for that reason, but we
flag them so users understand what they're agreeing to.

| Model family | Licence | Notes |
|---|---|---|
| Llama 2 / Llama 3 / Llama 4 | Llama Community Licence | Restrictive: forbids use by entities with >700M monthly active users without a separate licence from Meta. Read the full terms before commercial use. |
| Gemma | Gemma Terms of Use | Google-issued, restrictive in some commercial scenarios. Read the full terms at https://ai.google.dev/gemma/terms. |
| Mistral 7B / Mixtral / Codestral | Apache-2.0 (most), or Mistral Research Licence (some) | Check the specific weight file's licence notice. |
| DeepSeek V3 / R1 | MIT (model), but DeepSeek's API trains on inputs | If using via API rather than local weights, DeepSeek may train on data. Local weights are MIT. |

## How the licence text is presented to the user

1. **At install time:** the user is shown a one-line summary of the default
   model's licence and a path to read the full text.
2. **At runtime:** `bash install.sh --licenses` prints the catalogue and
   pointers; `cat ~/.ostler/LICENSES/Apache-2.0.txt` shows the text.
3. **In the iOS app:** Settings -> About -> Acknowledgements lists the
   models and their licences alongside the SPM dependencies.
4. **On the public website:** https://creativemachines.ai/ostler/licenses.html
   lists the same catalogue.

## Verification

The licence files in this directory are taken verbatim from the SPDX
licence list (https://github.com/spdx/license-list-data). They are stable
artefacts and considered authoritative in the free-software ecosystem.

If any model's upstream licence changes (rare, but happens; Redis is the
2024 cautionary tale), this catalogue must be updated and the affected
component re-verified. The source-of-truth for that flow is
`../THIRD_PARTY_NOTICES.md`; this file is a derived view.

## Cross-references

- Action plan: `../OSS_LICENSE_ACKNOWLEDGEMENTS_PLAN.md`
- Master catalogue: `../THIRD_PARTY_NOTICES.md`
- Per-licence-text folder: `./` (this directory)
