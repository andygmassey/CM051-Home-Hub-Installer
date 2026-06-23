# DESIGN: Adaptive first-run resource governor (v1.0.3)

Status: PROPOSED + core built (this PR). British English throughout.
Owner repo: CM051 (installer + tick wrappers). Composes with the
interactive-chat priority marker (ostler-assistant) already merged into
the tick wrappers.

---

## 1. The problem (measured)

On a fresh v1.0.2 install on a Mac Studio the machine hit a 1-minute load
average of ~37-40 immediately post-install and the whole Hub app became
unusable: dashboard "Load failed", Doctor diagnostics failed, chat WS
died with code 1006. The gateway `/health` took 4.5s. The daemon was
alive, just thrashing.

Root cause is a first-run process storm, NOT a runaway count of
concurrent LLM decodes. The single shared Ollama slot is already well
behaved (see section 2). The storm is a coincident spawn spike of heavy
background processes, all triggered within the same post-install minute,
on top of the Docker VM and macOS first-login Spotlight indexing.

If a 64GB Studio self-DOSes, an 8GB / 16GB floor machine will be far
worse and for far longer. The product must stay responsive on the floor
hardware. The interactive surfaces that matter on first run are People,
Wiki, and Chat; everything else can wait.

---

## 2. First-run enrichment orchestration map (end-to-end)

Verified by reading the three repos. Concurrency is already partially
bounded; the gap is hardware-blindness and the coincident spawn spike.

### 2.1 Who launches what, and when

| Producer | Repo | Launch trigger | Heavy work per run |
|---|---|---|---|
| 4x conversation-bundle feeds (whatsapp / imessage / email / spoken) | CM051 `vendor/*_source/bin/*-bundle-tick.sh` via LaunchAgents | `RunAtLoad=true` at install completion + `StartInterval=900` (15 min) | Python venv reads a YEAR of a local sqlite store, renders transcripts, then 1 pwg-convo LLM summary per new chat (~1 min each) |
| Wiki recompile | CM051 `wiki-recompile/bin/wiki-recompile-tick.sh` via LaunchAgent + a one-shot `nohup` kick after contact re-sync | `RunAtLoad` + daily + post-contact-sync kick | Full CM044 compile, up to ~800 LLM calls, `WIKI_LLM_WORKERS` parallel batches (shipped at 3) |
| Daemon cron catch-up | ostler-assistant `cron/scheduler.rs:89,149` | daemon startup, `catch_up_on_startup=true` | Fires ALL overdue agent jobs at once, bounded by `scheduler.max_concurrent` (default 4) |
| Daemon heartbeat | ostler-assistant `daemon/mod.rs:408` | `heartbeat.interval_minutes` if enabled | 2-phase agent LLM run |
| Docker VM | CM051 (lima/colima) | install | qdrant + oxigraph + redis, steady CPU |
| macOS first-login | OS | first login after a cold install | Spotlight / mdworker indexing the freshly-hydrated `~/Documents/Ostler` tree |

### 2.2 Concurrency that ALREADY exists (do not reimplement)

1. **Single-flight ingest lock** (`ingest-ollama.lock.d`, an atomic
   `mkdir`). All 4 bundle feeds AND the wiki recompile take the SAME
   lock, so at most ONE of them holds the model slot at a time. Reclaim
   is PID-liveness based (never time-based) so the multi-hour wiki
   backfill is never wrongly evicted. Source: each `*-bundle-tick.sh`
   and `wiki-recompile-tick.sh`.
2. **Interactive-chat priority yield** (`interactive-chat.active`
   marker, TTL 120s). The daemon touches the marker at the top of every
   agent turn (`agent.rs:1014`, covers Hub `/ws/chat` AND every
   iMessage/WhatsApp/email reply). Each tick yields the whole tick while
   the marker is fresh. Source: `interactive_marker.rs` + the yield
   block in each wrapper.
3. **Off-peak read-window throttle** (#598). Outside 01:00-06:00 the
   tick shrinks `--since-days` so daytime ticks stay light; overnight
   drains the full window. Source: the off-peak block in each wrapper.
4. **In-daemon Ollama admission gate** (`ollama_gate.rs`, `Semaphore(1)`
   with foreground/background priority). All IN-PROCESS daemon LLM calls
   serialise to one, background yields to foreground. NOTE: this gate
   does NOT cover the external tick processes; they coordinate via the
   filesystem lock above.
5. **Ollama serve plist**: `OLLAMA_NUM_PARALLEL=2`,
   `OLLAMA_KEEP_ALIVE=-1` (`install.sh` ~5868). Reserves a second decode
   slot for chat and keeps the model resident.

### 2.3 The actual gap (why the Studio still thrashed)

The LLM decode path is well bounded. What is NOT bounded:

* **Coincident spawn spike.** All 4 bundle agents + wiki recompile have
  `RunAtLoad=true`, so at install completion they ALL start their Python
  interpreters, open their venvs, and begin reading a year of sqlite in
  the same instant. The single-flight lock makes 4 of the 5 yield BEFORE
  the LLM call, but only AFTER each has already spawned a Python process
  and begun (or attempted) its sqlite read/render. Five fat Python
  processes plus the wiki compiler's parallel workers plus Docker plus
  Spotlight = the load-37 spike. The lock serialises the SUMMARY, not the
  spawn.
* **Hardware-blindness.** `WIKI_LLM_WORKERS=3` and `OLLAMA_NUM_PARALLEL=2`
  are fixed regardless of tier. On a 16GB Mini or a (hypothetical) 8GB
  Air the same parallelism is far heavier relative to capacity.
* **No system-load backpressure.** Nothing reads `loadavg` before doing
  non-essential enrichment. The off-peak gate is clock-based, not
  load-based, so a daytime install storms at full daytime parallelism.

The governor closes exactly these three gaps and reuses 1-5 untouched.

---

## 3. Hardware detection (REUSE + extend)

There is no standalone `ostler-model-fit.sh` in any repo today. The
hardware-fit logic that the brief calls "REUSE-4" is the inline RAM-tier
model selection in `install.sh`:

* RAM: `RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))` (line ~1725).
* Hard floor: `install.sh` ALREADY hard-fails below 16GB
  (`ERR-02-PREREQ-RAM-LOW`, line ~1726). So the shipped product floor is
  ALREADY 16GB, not 8GB.
* Model by RAM (line ~3953): `>=48GB` -> `qwen3.6:35b-a3b`;
  `>=24GB` -> `qwen3.5:9b`; else (16-23GB) -> `gemma4:e2b`.

This design adds **core-count detection** and packages the whole thing
as a sourced library, `lib/ostler-resource-tier.sh`, installed to
`~/.ostler/lib/ostler-resource-tier.sh` (the exact pattern already used
for `ostler-detect-exports.sh`). Both `install.sh` and the tick wrappers
source it, so the tier policy is defined ONCE.

Core detection:
* Total cores: `sysctl -n hw.ncpu`.
* Performance cores (Apple Silicon): `sysctl -n hw.perflevel0.physicalcpu`
  (absent on Intel -> falls back to physical cores `hw.physicalcpu`).

---

## 4. Hardware tiers and per-tier first-run policy

| Tier | Trigger | Enrich concurrency | Non-essential on first run | Enrichment model | Loadavg ceiling (per-core 1-min) | NUM_PARALLEL | WIKI_LLM_WORKERS |
|---|---|---|---|---|---|---|---|
| FLOOR | RAM < 16GB OR P-cores <= 4, AND the detection-failure fallback (e.g. an 8GB Air, were the 16GB prereq ever lowered) | 1 (fully sequenced) | DEFER all | gemma4:e2b | 1.5 | 1 | 1 |
| LOW | RAM 16-31GB. This is the LOWEST SUPPORTED machine (install.sh hard-fails < 16GB), so the floor that ships today is LOW, not FLOOR. e.g. Mini M4 16GB, M1 Pro | 2 | DEFER all | qwen3.5:9b | 2.0 | 2 | 2 |
| HIGH | RAM >= 32GB (Studio) | 4 | allow (current behaviour) | qwen3.6:35b-a3b or qwen3.5:9b | 3.0 | 2 | 3 |

Notes:
* "Enrich concurrency" is the cap the bundle feeds + wiki recompile
  collectively respect ON TOP OF the existing single-flight lock. At
  FLOOR it stays 1 (the lock already gives this); the new value
  additionally drives the load-gate and the spawn stagger.
* The **loadavg ceiling** is per-core (1-min loadavg divided by total
  cores). If the normalised load is ABOVE the ceiling, a non-essential
  tick defers this run (the watermark means nothing is lost; it retries
  next StartInterval). This is the system-load backpressure that was
  missing. Essential first-run work (containers, core graph/people
  hydrate, wiki compile) is NOT gated by this.
* **num_ctx for ENRICHMENT only**: the bundle/summary path may run at a
  reduced num_ctx on FLOOR to cut KV-cache RAM, via
  `OSTLER_ENRICH_NUM_CTX` passed only to the pwg-convo summary, NEVER to
  the interactive chat (chat keeps `OLLAMA_NUM_CTX=32768` to avoid the
  known agent-prompt-truncation bug). This is scoped as a follow-up
  (section 8) because pwg-convo would need to honour the env var.
* The tier values are env-overridable for testing and for an operator
  who wants to opt out: `OSTLER_TIER`, `OSTLER_ENRICH_CONCURRENCY`,
  `OSTLER_DEFER_NONESSENTIAL`, `OSTLER_LOADAVG_CEILING`.

---

## 5. Essential vs deferrable on first run

First impression = People + Wiki + Chat working. Sequence:

1. ESSENTIAL, runs eagerly: containers healthy -> core graph/people
   hydrate (metadata FACTS only) -> wiki compile (so People + Wiki render).
   Chat is always essential and always wins the slot (interactive
   marker).
2. DEFERRABLE, gated behind the defer flag + the load gate: the 4
   conversation-bundle feeds (deep body reads + per-chat AI summaries),
   the daily-brief / heartbeat enrichment, any non-visible-yet bundle.

On FLOOR and LOW tiers the defer flag is SET, so the deferrable work does
not even attempt to run while first-run load is high; it drips in only
once the normalised loadavg falls under the tier ceiling AND no
interactive turn is active. On HIGH the defer flag is unset (current
behaviour), because a 32GB+ Studio can absorb it once the spawn spike is
staggered.

---

## 6. Composition with the interactive-chat marker

The interactive-chat priority yield already exists in every wrapper
(written by a separate worktree, already merged). The governor's
load-gated and deferred jobs ALSO respect that marker: the yield block
runs first (so a fresh chat turn skips the tick outright), then the
governor's defer/load gate runs, then the single-flight lock. Order in
each wrapper:

```
interactive-chat yield  ->  governor defer + load gate  ->  off-peak
window clamp  ->  single-flight lock  ->  reader/render/summary
```

The governor adds NO new lock and does NOT touch the marker; it only
reads loadavg and the tier flags. Fail-safe at every step.

---

## 7. The 8GB question: RECOMMENDATION

**Recommendation: keep the floor at 16GB for v1.0.3. Do NOT support 8GB.**

Numbers (Apple Silicon, unified memory, measured + first-principles):

RAM budget on an 8GB M1 Air during first-run:
* macOS resident + WindowServer + first-login Spotlight: ~2.5-3.5GB
  under indexing load.
* Docker/lima VM running qdrant + oxigraph + redis: ~1.5-2GB resident
  (oxigraph + qdrant each hold working sets; redis small).
* Ollama model weights: gemma4:e2b ~= 5GB on disk, ~2.5-3GB resident
  quantised, PLUS KV cache. A single 32768-context KV cache for a small
  model is hundreds of MB to ~1GB; `OLLAMA_NUM_PARALLEL=2` doubles the KV
  cache.

Sum at idle-after-install: ~2.5 (macOS) + 1.5 (VM) + 3 (model) = ~7GB
before ANY enrichment, on an 8GB machine. That leaves under ~1GB of
headroom, so the moment the conversation feeds spawn their Python
interpreters (each 150-400MB) and Ollama grows its KV cache for a summary
the machine goes to swap. On Apple Silicon, swap thrash on a saturated
8GB box is exactly the load-37 failure mode, only worse and permanent
because there is no headroom to recover into. Even fully sequenced
(concurrency 1) the resident floor alone leaves no room for a usable
interactive chat alongside the VM and the model.

16GB is the realistic floor: ~2.5 (macOS) + 1.5 (VM) + 3 (model) = ~7GB
resident, leaving ~9GB for KV caches, the Python enrichment process,
Spotlight, and chat headroom. That is why `install.sh` already enforces
16GB. The governor makes 16GB GOOD (no storm) rather than merely allowed.

If 8GB support is ever required it would need: gemma at reduced num_ctx
for BOTH chat and enrichment (which reintroduces the agent-prompt
truncation risk for chat), `OLLAMA_NUM_PARALLEL=1` (chat queues behind
any background decode), enrichment fully deferred to a manual/overnight
batch, and very likely a smaller embedded vector store. That is a
distinct "8GB low-power mode" project, not a tweak. Deferred.

---

## 8. Build plan and what ships in this PR

BUILT in this PR (CM051, installer/script-only, NO daemon rebuild):

1. `lib/ostler-resource-tier.sh` -- the hardware-tier detector. Emits
   `OSTLER_TIER`, `OSTLER_ENRICH_CONCURRENCY`,
   `OSTLER_DEFER_NONESSENTIAL`, `OSTLER_LOADAVG_CEILING`. Fail-safe: if
   detection fails it falls back to the CONSERVATIVE (FLOOR) tier, never
   the unbounded storm.
2. Install of that lib to `~/.ostler/lib/ostler-resource-tier.sh` in
   `install.sh` (mirrors the detect-exports install), and per-tier
   `WIKI_LLM_WORKERS` / `OLLAMA_NUM_PARALLEL` selection from it.
3. A **governor gate** in each `*-bundle-tick.sh` and in
   `wiki-recompile-tick.sh`: source the tier lib, and if the job is
   non-essential AND (`OSTLER_DEFER_NONESSENTIAL` is set OR the
   normalised loadavg exceeds `OSTLER_LOADAVG_CEILING`), yield this tick.
   This replaces the unbounded spawn behaviour with a hardware-scaled,
   load-aware one while keeping the existing lock + marker + off-peak
   gates intact. Fail-safe: a missing lib or unreadable loadavg proceeds
   exactly as today (never wedges background work).
4. Tests proving floor caps to 1 and defers; 16GB-class caps to 2; high
   unrestricted; detection-failure falls back to the conservative cap;
   non-essential jobs run once load drops.

FOLLOW-UPS (scoped, not in this PR):
* `OSTLER_ENRICH_NUM_CTX` honoured by pwg-convo for the summary path
  only (reduce enrichment KV cache on FLOOR without touching chat's 32k).
  Needs a CM048/pwg-convo change.
* Per-tier `scheduler.max_concurrent` and `catch_up_on_startup` defer for
  the daemon cron catch-up (ostler-assistant `cron/scheduler.rs`). This
  is the one piece that needs a DAEMON REBUILD. Recommend the daemon read
  the same tier flags (it can shell out to the lib or sysctl directly) and
  set `catch_up_on_startup=false` on FLOOR/LOW first boot.
* RunAtLoad stagger: replace simultaneous `RunAtLoad=true` on all 5
  agents with a small per-agent `StartInterval` offset / a launchd
  `ThrottleInterval`, so the spawn spike is spread over the first few
  minutes even before the load gate engages. Plist-only, no rebuild.

### Rebuild matrix

| Change | Repo | Needs daemon rebuild? |
|---|---|---|
| tier detector lib + install wiring | CM051 | No (installer/script only) |
| governor gate in tick wrappers | CM051 | No |
| per-tier NUM_PARALLEL / WIKI_LLM_WORKERS | CM051 | No |
| enrich num_ctx | CM048 pwg-convo | No (pipeline script) |
| cron catch-up tier defer | ostler-assistant | YES |
| RunAtLoad stagger | CM051 plists | No |
