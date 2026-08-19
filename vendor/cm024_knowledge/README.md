# CM024 - Personal Knowledge Backends

The knowledge store for the Personal AI system. Provides semantic search over personal knowledge from multiple sources.

## Knowledge Sources

| Source | Collection | Status | Records |
|--------|------------|--------|---------|
| **Evernote Notes** | `evernote_knowledge` | Active | 117K+ vectors |
| **Email Correspondence** | `email_knowledge` | Planned | ~2K threads |

## Quick Start

### Evernote Knowledge

```bash
# 1. Convert ENEX to Obsidian markdown
python -m src.cli convert data/evernote-export/*.enex -o data/obsidian-vault/evernote

# 2. Embed notes into Qdrant (using TrueNAS Ollama)
python -m src.cli embed data/obsidian-vault/evernote -v

# 3. Query via backend adapter
python -c "from src.api.backend_adapter import EvernoteBackend; print(EvernoteBackend().query('machine learning'))"
```

### Email Knowledge (Planned)

```bash
# Extract knowledge from email correspondence
python -m src.cli extract-email-knowledge --source gmail --privacy-level 4

# See docs/EMAIL_KNOWLEDGE_DESIGN.md for full design
```

## Features

- **Semantic Search**: Find knowledge by meaning, not just keywords
- **Privacy Filtering**: Query respects compartment levels (L0-L5)
- **Multi-Source**: Unified search across Evernote notes and email threads
- **Provenance Tracking**: Know which source answered your question

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│   Evernote ENEX     │     │  Email MBOX/EMLX    │
└─────────┬───────────┘     └─────────┬───────────┘
          │                           │
          ▼                           ▼
┌─────────────────────┐     ┌─────────────────────┐
│  Parse → Markdown   │     │  Thread → Summarize │
│  Classify → Chunk   │     │  (LLM extraction)   │
└─────────┬───────────┘     └─────────┬───────────┘
          │                           │
          ▼                           ▼
┌─────────────────────┐     ┌─────────────────────┐
│  evernote_knowledge │     │   email_knowledge   │
│    (Qdrant)         │     │     (Qdrant)        │
└─────────┬───────────┘     └─────────┬───────────┘
          │                           │
          └───────────┬───────────────┘
                      ▼
           ┌─────────────────────┐
           │  CM023 Synthesis    │
           │  Layer (queries)    │
           └─────────────────────┘
```

## Storage

| Store | Purpose |
|-------|---------|
| `data/obsidian-vault/evernote/` | Markdown files (Evernote) |
| Qdrant `evernote_knowledge` | Evernote vectors (384-dim) |
| Qdrant `email_knowledge` | Email thread vectors (planned) |
| SQLite `data/metadata.db` | Note/thread metadata |

## Related Projects

- **CM022** - Personal AI (parent project)
- **CM023** - Synthesis Layer (queries this backend)
- **CM019** - Personal World Graph (preferences backend)
- **CM002** - Wearable Assistant (memories backend)

## Status

### Evernote Knowledge
**Phase: Embedding Complete**
- 11,090 notes parsed from 27GB ENEX export (13 files)
- 10,906 markdown files created
- 117,000+ vectors in Qdrant (all-minilm, 384-dim)
- Backend adapter working with CM023

### Email Knowledge
**Phase: Design**
- Design document created: `docs/EMAIL_KNOWLEDGE_DESIGN.md`
- ~2,500 correspondence emails identified
- LLM-based thread summarization planned
- Estimated effort: 8-12 hours

## CLI Commands

| Command | Description |
|---------|-------------|
| `convert` | Parse ENEX files to Obsidian markdown |
| `embed` | Generate embeddings and store in Qdrant |
| `count` | Count notes in ENEX files |
| `sample` | Show sample notes from ENEX |
| `stats` | Show statistics about ENEX files |

## Changelog

### 2026-01-20
- Expanded scope: Evernote Knowledge → Personal Knowledge Backends
- Added Email Knowledge design (`docs/EMAIL_KNOWLEDGE_DESIGN.md`)
- Fixed Ollama embedder API (`/api/embed` not `/api/embeddings`)
- Fixed Qdrant client API (`query_points` not deprecated `search`)
- Updated CLI defaults for the Ollama host (localhost:11434, override via OSTLER_OLLAMA_URL)
- Changed embedding model to all-minilm (384-dim, matches existing vectors)
- Completed embedding: 117,000+ vectors

### 2026-01-17
- Full ENEX parsing pipeline (streaming XML for 2GB+ files)
- Markdown writer with YAML frontmatter
- Privacy classifier (heuristic-based)
- Semantic chunker for embedding
- Qdrant integration with compartment filtering
- Ollama embedder with remote server support
- Progress monitor script
- CM023 Synthesis Layer backend adapter

See `CLAUDE.md` for detailed requirements and architecture.
