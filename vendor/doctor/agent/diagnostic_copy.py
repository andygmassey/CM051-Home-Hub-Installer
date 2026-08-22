"""Customer-facing copy for Doctor diagnostic rules.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string Doctor's rule engine shows the customer.

Each rule in ``diagnostic_rules.py`` is a function that returns a
list of finding dicts. Title / detail / fix / fix_command strings
live here. Fix-command strings are technical shell commands and
stay verbatim across languages, but they live in this catalogue
anyway so the table-of-strings remains one stop.

Conventions:
- British English throughout.
- No em-dashes (project brand rule).
- Apple-Restraint voice: observational, not punitive.
- Titles are short noun phrases; detail is two short sentences.
- Format-string placeholders use named ``.format()`` interpolation
  so translators can re-order and re-label without touching the
  call site.
- The companion banner module is ``banner_copy.py`` (#259/#260
  banners). New banner-style entries can live there or here, but
  follow whichever is closer to the rule's call shape.

This module is imported by ``diagnostic_rules.py``. Adding a new
rule string: define the constant or factory here, import and
reference from the rule body.
"""

from __future__ import annotations


# ── check_first_install ──────────────────────────────────────────────


DOCKER_NOT_INSTALLED_TITLE = "Docker is not installed"
DOCKER_NOT_INSTALLED_DETAIL = (
    "Ostler uses Docker to run its database services. "
    "Docker Desktop is free for personal use."
)
DOCKER_NOT_INSTALLED_FIX = "Install Docker Desktop"
DOCKER_NOT_INSTALLED_FIX_COMMAND = "brew install --cask docker"

CONTAINERS_NOT_CREATED_TITLE = "Ostler containers not created yet"
CONTAINERS_NOT_CREATED_DETAIL = (
    "Docker is running but Ostler's services have not been started. "
    "Did the install script complete successfully?"
)
CONTAINERS_NOT_CREATED_FIX = "Start Ostler services"
CONTAINERS_NOT_CREATED_FIX_COMMAND = "cd ~/.ostler && docker compose up -d"

OLLAMA_NOT_INSTALLED_TITLE = "Ollama is not installed or not running"
OLLAMA_NOT_INSTALLED_DETAIL = (
    "Ostler needs Ollama to run AI models locally. "
    "Install it via Homebrew or from ollama.com."
)
OLLAMA_NOT_INSTALLED_FIX = "Install and start Ollama"
OLLAMA_NOT_INSTALLED_FIX_COMMAND = "brew install ollama && ollama serve &"

ALL_UNREACHABLE_TITLE = "All services unreachable despite Docker running"
ALL_UNREACHABLE_DETAIL = (
    "Docker is running but no services are responding. "
    "This usually means the containers exist but ports are not mapped, "
    "or the services crashed on startup."
)
ALL_UNREACHABLE_FIX = "Check container logs for errors"
ALL_UNREACHABLE_FIX_COMMAND = (
    "docker compose -f ~/.ostler/docker-compose.yml logs --tail=20"
)


# ── check_container_health ───────────────────────────────────────────


CONTAINER_RESTARTING_TITLE_FMT = "Container '{name}' is in a restart loop"
CONTAINER_RESTARTING_DETAIL_FMT = (
    "Status: {status}. The container keeps crashing and restarting. "
    "This is usually caused by a configuration error or missing data volume."
)
CONTAINER_RESTARTING_FIX = "Check the container logs for the error message"
CONTAINER_RESTARTING_FIX_COMMAND_FMT = "docker logs --tail=30 {name}"

CONTAINER_NEVER_STARTED_TITLE_FMT = (
    "Container '{name}' was created but never started"
)
CONTAINER_NEVER_STARTED_DETAIL = (
    "This container exists but has never run. Try starting it."
)
CONTAINER_NEVER_STARTED_FIX = "Start the container"
CONTAINER_NEVER_STARTED_FIX_COMMAND_FMT = "docker start {name}"

CONTAINER_CRASHED_TITLE_FMT = "Container '{name}' crashed (non-zero exit)"
CONTAINER_CRASHED_DETAIL_FMT = (
    "Status: {status}. The container exited with an error."
)
CONTAINER_CRASHED_FIX = "Check the error message in the container logs"
CONTAINER_CRASHED_FIX_COMMAND_FMT = "docker logs --tail=30 {name}"

# The state the three rules above cannot express: not an unhealthy
# container, but NO container list at all. Measured on the Mini
# 2026-08-20 after a power cycle -- Colima was down, `docker ps` failed,
# and the collector returned an empty list. Each rule loops over that
# list, runs its body zero times, and contributes nothing, so a box with
# Qdrant, Oxigraph, Redis, Vane, wiki-site and store-proxy all gone
# rendered exactly like a healthy one.
#
# The detail carries the collector's own error text rather than a
# paraphrase, because the failure must name what was MEASURED. A guess
# here ("Docker may not be running") is the same mistake as reading
# colima's "lima not found" as a missing package when lima was installed
# and merely unreachable.
CONTAINER_ENGINE_UNREACHABLE_TITLE = (
    "The container stack could not be examined at all"
)
CONTAINER_ENGINE_UNREACHABLE_DETAIL_FMT = (
    "Listing containers failed: {error}. Every Ostler store runs as a "
    "container, so while this persists the wiki, search and knowledge "
    "graph are unavailable AND their health is unknown -- this card is "
    "reporting that nothing could be checked, not that nothing is wrong."
)
CONTAINER_ENGINE_UNREACHABLE_FIX = (
    "Start the container runtime, then confirm the stores come back"
)
CONTAINER_ENGINE_UNREACHABLE_FIX_COMMAND = (
    "/opt/homebrew/bin/colima start && /opt/homebrew/bin/docker ps"
)


# ── check_qdrant_health ──────────────────────────────────────────────


QDRANT_OVERLOADED_TITLE = "Qdrant is overloaded (503)"
QDRANT_OVERLOADED_DETAIL = (
    "Qdrant returned 503 Service Unavailable. This can happen during "
    "large imports or when the machine is low on RAM."
)
QDRANT_OVERLOADED_FIX = (
    "Wait a few minutes and try again. If persistent, restart Qdrant."
)
QDRANT_OVERLOADED_FIX_COMMAND_FMT = "docker restart {prefix}qdrant"


# ── check_oxigraph_health ────────────────────────────────────────────


OXIGRAPH_INTERNAL_ERROR_TITLE = "Oxigraph internal error (500)"
OXIGRAPH_INTERNAL_ERROR_DETAIL = (
    "Oxigraph returned a 500 error. This can happen if the database "
    "file is corrupted. Check the logs."
)
OXIGRAPH_INTERNAL_ERROR_FIX = "Check Oxigraph logs"
OXIGRAPH_INTERNAL_ERROR_FIX_COMMAND_FMT = "docker logs --tail=30 {prefix}oxigraph"


# ── check_import_readiness ───────────────────────────────────────────


IMPORT_BLOCKED_SERVICES_TITLE_FMT = (
    "Import pipeline blocked: {missing} not healthy"
)
IMPORT_BLOCKED_SERVICES_DETAIL_FMT = (
    "The import pipeline needs Qdrant, Oxigraph, and Ollama all running. "
    "Currently missing: {missing}."
)
IMPORT_BLOCKED_SERVICES_FIX = (
    "Start the missing services, then retry the import"
)
IMPORT_BLOCKED_SERVICES_FIX_COMMAND = "cd ~/.ostler && docker compose up -d"

IMPORT_BLOCKED_EMBED_TITLE = (
    "Import pipeline blocked: embedding model not installed"
)
IMPORT_BLOCKED_EMBED_DETAIL = (
    "All services are running, but the embedding model (nomic-embed-text) "
    "is not available in Ollama. The import pipeline needs it to create "
    "vector embeddings for search."
)
IMPORT_BLOCKED_EMBED_FIX = "Pull the embedding model, then retry the import"
IMPORT_BLOCKED_EMBED_FIX_COMMAND = "ollama pull nomic-embed-text"

IMPORT_READY_TITLE = "System ready for import"
IMPORT_READY_DETAIL = (
    "All required services are healthy and the embedding model is available. "
    "You can run the import pipeline now."
)
IMPORT_READY_FIX_COMMAND = (
    "cd ~/.ostler/import-pipeline && source .venv/bin/activate && "
    "python -m contact_syncer.import_all --exports-dir ~/gdpr-exports/ --verbose"
)


# ── check_performance ────────────────────────────────────────────────


CRITICAL_DISK_TITLE_FMT = "Critical: only {free_gb:.1f} GB free on root"
CRITICAL_DISK_DETAIL = (
    "Less than 10 GB free. Docker and Ollama both need disk space to function. "
    "Services will start failing if this drops further."
)
CRITICAL_DISK_FIX = "Free up space – remove unused Docker images and Ollama models"
CRITICAL_DISK_FIX_COMMAND = (
    "docker system prune -f && "
    "echo '--- Ollama models ---' && ollama list && "
    "echo '--- Docker images ---' && docker images"
)

MANY_MODELS_TITLE_FMT = "{count} Ollama models installed ({total_gb:.0f} GB)"
MANY_MODELS_DETAIL = (
    "Ostler only needs 1-2 models. Consider removing unused ones to free disk space."
)
MANY_MODELS_FIX = "List models and remove unused ones"
MANY_MODELS_FIX_COMMAND = "ollama list"


# ── check_network_isolation ──────────────────────────────────────────


NO_INTER_SERVICE_TITLE = "No inter-service connectivity"
NO_INTER_SERVICE_DETAIL = (
    "None of the service-to-service network checks passed. "
    "This usually means Docker networking is broken or all containers "
    "are on different networks."
)
NO_INTER_SERVICE_FIX = "Recreate the Docker network"
NO_INTER_SERVICE_FIX_COMMAND = (
    "cd ~/.ostler && docker compose down && docker compose up -d"
)

CANNOT_REACH_TITLE_FMT = "{source} cannot reach {target}"
CANNOT_REACH_DETAIL_FMT = (
    "The {target} service is not reachable from {source}. "
    "This may affect import pipeline or API operations."
)
CANNOT_REACH_FIX_FMT = "Check if {target} is running"
CANNOT_REACH_FIX_COMMAND_FMT = "docker ps | grep {target}"


# ── check_ollama_models ──────────────────────────────────────────────


NO_OLLAMA_MODELS_TITLE = "No Ollama models installed"
NO_OLLAMA_MODELS_DETAIL = (
    "Ollama is running but no models are installed. Ostler needs "
    "at least a chat model and an embedding model."
)
NO_OLLAMA_MODELS_FIX = "Pull the recommended models"
NO_OLLAMA_MODELS_FIX_COMMAND = (
    "ollama pull qwen3.5:9b && ollama pull nomic-embed-text"
)

NO_EMBED_MODEL_TITLE = "No embedding model installed"
NO_EMBED_MODEL_DETAIL = (
    "Vector search requires an embedding model. Without it, imports "
    "will not be searchable."
)
NO_EMBED_MODEL_FIX = "Pull the embedding model"
NO_EMBED_MODEL_FIX_COMMAND = "ollama pull nomic-embed-text"

NO_CHAT_MODEL_TITLE = "No chat model installed"
NO_CHAT_MODEL_DETAIL = (
    "You have embedding models but no chat model. The assistant "
    "needs a chat model to answer questions."
)
NO_CHAT_MODEL_FIX = "Pull a chat model"
NO_CHAT_MODEL_FIX_COMMAND = "ollama pull qwen3.5:9b"

MODEL_TOO_LARGE_TITLE_FMT = "Model '{name}' may be too large for your Mac"
MODEL_TOO_LARGE_DETAIL_FMT = (
    "Model size: {size_gb:.1f} GB. Your Mac has {ram_total_gb:.0f} GB RAM. "
    "Models larger than ~70% of your RAM will cause swapping and slow inference."
)
MODEL_TOO_LARGE_FIX = "Consider a smaller model"
MODEL_TOO_LARGE_FIX_COMMAND_FMT = "ollama rm {name} && ollama pull qwen3.5:9b"


# ── check_redis_health ───────────────────────────────────────────────


REDIS_UNREACHABLE_TITLE = "Cache / message-bus container is unreachable"
REDIS_UNREACHABLE_DETAIL = (
    "The Redis-compatible cache and Streams message bus is unreachable. "
    "Without it, conversation processing, wiki updates, and real-time "
    "notifications will not work."
)
REDIS_UNREACHABLE_FIX = "Restart the cache container"
REDIS_UNREACHABLE_FIX_COMMAND_FMT = "docker restart {prefix}redis"


# ── check_gateway_health ─────────────────────────────────────────────


GATEWAY_BAD_GATEWAY_TITLE_FMT = "Gateway returned {status_code}"
GATEWAY_BAD_GATEWAY_DETAIL = (
    "The API gateway is up but cannot reach backend services. "
    "This usually means Qdrant or Oxigraph is down."
)
GATEWAY_BAD_GATEWAY_FIX = "Restart all services"
GATEWAY_BAD_GATEWAY_FIX_COMMAND = "cd ~/.ostler && docker compose restart"

GATEWAY_UNREACHABLE_TITLE = "API gateway is not running"
GATEWAY_UNREACHABLE_DETAIL = (
    "The Ostler API gateway is not responding. The wiki, search, "
    "and AI assistant all depend on it."
)
GATEWAY_UNREACHABLE_FIX = "Start the gateway"
GATEWAY_UNREACHABLE_FIX_COMMAND = "cd ~/.ostler && docker compose up -d gateway"


# ── check_memory_pressure ────────────────────────────────────────────


CRITICAL_MEMORY_TITLE_FMT = "Very high memory usage ({used_pct:.0f}%)"
CRITICAL_MEMORY_DETAIL_FMT = (
    "Only {avail_gb:.1f} GB of {total_gb:.0f} GB "
    "is available. macOS will start swapping heavily, making AI inference "
    "extremely slow. Close other apps or use a smaller model."
)
CRITICAL_MEMORY_FIX = "Check what is using memory"
CRITICAL_MEMORY_FIX_COMMAND = "top -l 1 -o MEM | head -20"

HIGH_MEMORY_TITLE_FMT = "High memory usage ({used_pct:.0f}%)"
HIGH_MEMORY_DETAIL_FMT = (
    "{avail_gb:.1f} GB available of {total_gb:.0f} GB. "
    "If you notice slow AI responses, memory pressure may be the cause."
)
HIGH_MEMORY_FIX = "Monitor memory usage"
HIGH_MEMORY_FIX_COMMAND = "vm_stat | head -10"

LOW_RAM_TITLE_FMT = (
    "Only {ram_total_gb:.0f} GB RAM (minimum recommended: 16 GB)"
)
LOW_RAM_DETAIL = (
    "Ostler works best with 16 GB or more. With less RAM, you are "
    "limited to smaller models and may experience slower inference."
)


# ── check_gdpr_export_age ────────────────────────────────────────────


STALE_IMPORT_TITLE_FMT = "Last import was {days} days ago"
STALE_IMPORT_DETAIL = (
    "Your knowledge graph has not been updated with new GDPR exports "
    "in over 3 months. Your contacts and connections may be stale. "
    "Consider requesting fresh exports from LinkedIn, Facebook, etc."
)
STALE_IMPORT_FIX = "Re-run the import with updated exports"
STALE_IMPORT_FIX_COMMAND = (
    "ostler-import --exports-dir ~/gdpr-exports/ --verbose"
)


# ── check_docker_resources ───────────────────────────────────────────


HIGH_CPU_TITLE_FMT = "Container '{name}' using {cpu_percent:.0f}% CPU"
HIGH_CPU_DETAIL = (
    "This container is consuming a lot of CPU. This could indicate "
    "an active import running, or a stuck process."
)
HIGH_CPU_FIX = "Check what the container is doing"
HIGH_CPU_FIX_COMMAND_FMT = "docker logs --tail=10 {name}"

HIGH_MEM_CONTAINER_TITLE_FMT = "Container '{name}' using {mem_mb:.0f} MB RAM"
HIGH_MEM_CONTAINER_DETAIL = (
    "This container is using over 4 GB of RAM. "
    "For Qdrant this may be normal with large datasets, "
    "but for other services it could indicate a memory leak."
)
HIGH_MEM_CONTAINER_FIX = "Restart the container if not importing"
HIGH_MEM_CONTAINER_FIX_COMMAND_FMT = "docker restart {name}"


# ── check_service_versions ───────────────────────────────────────────


OLLAMA_OLD_TITLE_FMT = "Ollama version {version} is quite old"
OLLAMA_OLD_DETAIL = (
    "Newer versions of Ollama have better performance and model support. "
    "Consider upgrading."
)
OLLAMA_OLD_FIX = "Upgrade Ollama"
OLLAMA_OLD_FIX_COMMAND = "brew upgrade ollama"


# ── check_imessage_fda ───────────────────────────────────────────────


IMESSAGE_FDA_TITLE = "iMessage needs Full Disk Access"
IMESSAGE_FDA_DETAIL = (
    "The Ostler assistant cannot read your Messages history yet. "
    "macOS requires you to grant Full Disk Access to the assistant "
    "binary before it can open ~/Library/Messages/chat.db. Open System "
    "Settings, drag ~/.ostler/bin/ostler-assistant into the Full Disk "
    "Access list, then restart the assistant. This card disappears on "
    "its own once the assistant can read Messages."
)
IMESSAGE_FDA_FIX = "Open System Settings to Full Disk Access"
# x-apple.systempreferences URL scheme opens the Privacy & Security
# pane and selects Full Disk Access on macOS 13+. Older macOS falls
# back to the Privacy & Security top-level pane, which is acceptable.
IMESSAGE_FDA_FIX_COMMAND = (
    "open 'x-apple.systempreferences:com.apple.preference.security?"
    "Privacy_AllFiles'"
)
# Secondary instruction shown alongside the deep-link: how to restart
# the assistant once FDA has been granted, so the card can clear.
IMESSAGE_FDA_RESTART_HINT = (
    "After granting access, restart the assistant: "
    "launchctl kickstart -k gui/$(id -u)/"
    "com.creativemachines.ostler.assistant"
)


# ── check_imessage_capture_stalled ───────────────────────────────────
#
# Distinct from check_imessage_fda: that rule fires on the install-time
# probe signal; this one fires on the RUNTIME evidence that the iMessage
# capture bundle is actually crash-looping. Before Full Disk Access is
# granted, every capture tick logs
# ``sqlite3.OperationalError: unable to open database file`` to
# ``~/.ostler/logs/imessage-bundle.err`` -- the capture is silently stalled
# and no messages are being read. This surfaces that as an actionable card.


IMESSAGE_CAPTURE_STALLED_TITLE = (
    "iMessage capture stalled: waiting for Full Disk Access"
)
IMESSAGE_CAPTURE_STALLED_DETAIL = (
    "Ostler's iMessage capture is retrying but cannot open your Messages "
    "database yet, so no messages are being read. macOS blocks access until "
    "you grant Full Disk Access to the assistant. Grant it and the capture "
    "resumes on its own; this card clears once Messages can be read."
)
IMESSAGE_CAPTURE_STALLED_FIX = "Open System Settings to Full Disk Access"
# Same remedial action as the install-time card: the FDA deep-link. Kept as
# its own catalogue entry so the two call sites stay decoupled, but pointed
# at the shared command so there is one deep-link string to maintain.
IMESSAGE_CAPTURE_STALLED_FIX_COMMAND = IMESSAGE_FDA_FIX_COMMAND


# ── check_last_upgrade ───────────────────────────────────────────────
#
# The (B-lite) upgrade audit-trail row. Reads the durable, reboot-
# surviving upgrade result the Hub records in preferences.json and
# tells the customer, in plain terms, how the last update went.
#
# The success detail deliberately carries no capital "T" or "Z" so a
# malformed timestamp can never leak an ISO string (2026-07-27T...Z)
# into the reassurance line.

LAST_UPGRADE_SUCCESS_TITLE_FMT = "Ostler updated to v{version}"
LAST_UPGRADE_SUCCESS_DETAIL_FMT = (
    "Last update applied {applied}. "
    "Assistant and services have been reconciled and are running normally."
)
# Shown when the recorded timestamp cannot be parsed, so the applied-time
# clause is omitted rather than printing a half-formed value.
LAST_UPGRADE_SUCCESS_DETAIL_NO_TIME = (
    "Assistant and services have been reconciled and are running normally."
)

LAST_UPGRADE_FAILED_TITLE = "Last Ostler update didn't finish"
LAST_UPGRADE_FAILED_DETAIL = (
    "The most recent update did not complete, so your previous (working) "
    "version of Ostler is still running. Nothing was lost. The Doctor logs "
    "have the details if you want to see what stopped it."
)
LAST_UPGRADE_FAILED_FIX = (
    "You can try the update again later. If it keeps stopping, the Doctor "
    "logs (in this window) show where."
)

LAST_UPGRADE_ROLLED_BACK_TITLE = "Ostler update was rolled back"
LAST_UPGRADE_ROLLED_BACK_DETAIL_FMT = (
    "Your previous Ostler is running. Version {version} did not install, so "
    "the working version was restored automatically. Nothing was lost."
)
LAST_UPGRADE_ROLLED_BACK_FIX = (
    "No action is needed. You can try updating again later from Settings."
)


# ---------------------------------------------------------------------------
# Conversation dispatch failures (2026-08-08)
#
# Doctor read this log for exactly ONE signature -- the pre-FDA SQLite crash.
# A bundle that ticks happily while every dispatch exits rc=1 was therefore
# invisible, and Doctor said "Everything looks healthy" beside a 37KB error
# log. Doctor was not lying; it was reporting on the only thing it checked.
#
# Silence and failure are different states. This copy is for the second.
# ---------------------------------------------------------------------------
CONVO_DISPATCH_FAILING_TITLE = "Some conversations could not be processed"
CONVO_DISPATCH_FAILING_DETAIL = (
    "Ostler is reading your messages, but {n} recent {noun} failed while being "
    "summarised and {have} been skipped. Those conversations will not appear in "
    "your wiki or answers until they are retried. Everything else is unaffected."
)
CONVO_DISPATCH_FAILING_FIX = "Show the error log"
CONVO_DISPATCH_FAILING_FIX_COMMAND = "open ~/.ostler/logs/imessage-bundle.err"


# ── A diagnostic rule that crashed ──────────────────────────────────────────
#
# Shown when run_all_rules catches an exception from a rule. Worded for a
# customer, not an operator: they do not care which Python symbol raised,
# they care that a check they are relying on did not happen. The rule name
# is still included because it is the one thing that makes a support report
# actionable, and it is a function name, never customer data.
RULE_CRASHED_TITLE_FMT = "One health check could not run ({rule})"
RULE_CRASHED_DETAIL_FMT = (
    "The {rule} check stopped with an internal error ({error_type}), so its "
    "result is unknown. This is not a report that something is wrong with "
    "your Mac, and it is not a report that everything is fine either: that "
    "particular check simply did not complete. Every other check on this "
    "page ran normally."
)
RULE_CRASHED_FIX = "Send this report so we can fix the check"
RULE_CRASHED_FIX_COMMAND = "open ~/.ostler/logs/doctor.err"


# ── Ingest sources that were killed, or that ran and brought nothing in ─────
#
# install.sh writes ~/.ostler/state/hydrate/<source>.done per source. Nothing
# read them until v1.0.37, so a source killed by the 90s watchdog produced no
# customer-visible signal at all: the Doctor said "Everything looks healthy"
# while people search and browsing had ingested literally nothing.
INGEST_KILLED_TITLE_FMT = "{source} did not finish importing"
INGEST_KILLED_DETAIL_FMT = (
    "The {source} import stopped before it completed{timeout_clause}, so those "
    "items are not searchable and will not appear in your wiki or answers. "
    "Nothing else was affected, and nothing has been lost from the original "
    "app: re-running the import picks it up again."
)
INGEST_KILLED_FIX = "Re-run the import for this source"
INGEST_KILLED_FIX_COMMAND = "open ~/.ostler/logs/install.log"

INGEST_EMPTY_TITLE_FMT = "{source} finished but brought nothing in"
INGEST_EMPTY_DETAIL_FMT = (
    "The {source} import reported success and then recorded zero items "
    "({payload}). That is not necessarily wrong, since you may simply have "
    "nothing there yet, but it is worth knowing: a source that imports nothing "
    "looks identical to a source that worked, and Ostler will have no {source} "
    "material to draw on."
)
INGEST_EMPTY_FIX = "Check whether this source has data to import"
INGEST_EMPTY_FIX_COMMAND = "open ~/.ostler/logs/install.log"

# A source that RAN and found no input. This is a healthy outcome and it had
# no copy at all until HR015 #580, which is why it was being rendered with
# INGEST_KILLED_*: four warnings on a clean box telling the customer imports
# had "stopped before completing" when they had run fine and found nothing.
#
# install.sh distinguishes these itself. _hydrate_sentinel_record_no_data
# writes status=no_data with the reason in detail, and its own comment calls
# the condition transient and explicitly not a failure. The Doctor now says
# the same thing the installer already believed.
INGEST_NO_INPUT_TITLE_FMT = "{source} had nothing to import yet"
INGEST_NO_INPUT_DETAIL_NO_APP_FMT = (
    "Ostler looked for {source} and did not find it installed, so there was "
    "nothing to bring in. This is not a problem and nothing failed. If you do "
    "use {source}, install it and run the import again and Ostler will pick "
    "it up."
)
INGEST_NO_INPUT_DETAIL_NO_EXPORT_FMT = (
    "Ostler looked for your {source} export and it was not there yet, so "
    "there was nothing to bring in. This is not a problem and nothing "
    "failed. Exports can take a while to arrive; once yours lands, run the "
    "import again."
)
INGEST_NO_INPUT_DETAIL_FMT = (
    "The {source} import ran and found nothing to bring in. This is not a "
    "problem and nothing failed. It is worth knowing only because Ostler "
    "will have no {source} material to draw on until there is something "
    "there."
)
INGEST_NO_INPUT_FIX = "Nothing to do unless you expected data here"
INGEST_NO_INPUT_FIX_COMMAND = "open ~/.ostler/logs/install.log"


# ---------------------------------------------------------------------------
# Scheduled-agent health (#595 layer 2, 2026-08-22)
#
# THE DEFECT THIS COPY EXISTS FOR.
#
# On .228 (published v1.0.38) com.ostler.fda-rerun -- the ONLY recurring
# ingest for contacts, calendar, iMessage, WhatsApp, browsing and notes --
# exited 1 on every hourly tick for days. The graph froze completely. No log
# reader, no Doctor card and no human ever said so, while the product went on
# telling the customer it was "still loading in the background".
#
# The missing module was the proximate cause and is fixed. The DEFECT is the
# silence: a scheduled agent could die on every tick forever and no surface
# named it. This copy is that surface.
#
# THREE STATES, NEVER CONFLATED. "Never ran" and "ran and succeeded" must not
# read the same -- that exact conflation is #810, and the box-walk gate that
# inherited it wrote `${ec:-0}`, turning an unloaded label's empty string into
# a clean exit 0 and going GREEN on a box where the bundle was not installed
# at all. So each state below gets its own title, and healthy emits nothing.

SCHEDULED_AGENT_FAILING_TITLE_FMT = (
    "Background updates for {feeds} have been failing"
)
SCHEDULED_AGENT_FAILING_DETAIL_FMT = (
    "{label} is the scheduled job that refreshes {feeds}. It has failed "
    "every time the Doctor has looked since {since} -- {ticks} runs, the "
    "most recent exiting with code {code}. While it keeps failing nothing "
    "new is being added from those sources, so anything that looks like it "
    "is 'still loading' has in fact stopped."
)
SCHEDULED_AGENT_FAILING_FIX = (
    "The job's own error log says why it is exiting. Open it, then restart "
    "the job. If it fails again straight away the error log will name the "
    "cause -- send it with the support report from this window."
)
SCHEDULED_AGENT_FAILING_FIX_COMMAND_FMT = (
    "tail -50 ~/.ostler/logs/{logname}.err; "
    "launchctl kickstart -k gui/$(id -u)/{label}"
)

# NEVER-RAN. Deliberately a different title, different severity and a
# different fix from FAILING, because it is a different fault: the job is
# registered and launchd has simply never started it. Reporting this as
# healthy is the #810 conflation; reporting it as failing would be a lie in
# the other direction, since nothing has failed yet.
SCHEDULED_AGENT_NEVER_RAN_TITLE_FMT = (
    "A background job for {feeds} has never run"
)
SCHEDULED_AGENT_NEVER_RAN_DETAIL_FMT = (
    "{label} refreshes {feeds}. launchd reports it has run zero times, and "
    "the Doctor has been watching it since {since} -- well past the {every} "
    "it is scheduled for. This is not the same as running successfully with "
    "nothing to do: it has not started at all, so those sources have never "
    "been refreshed since Ostler was installed."
)
SCHEDULED_AGENT_NEVER_RAN_FIX = (
    "Start the job once by hand. If it then runs on its own schedule the "
    "problem was the initial trigger; if it never appears again, its plist "
    "is not being honoured."
)

# NOT LOADED. "An unloaded agent is not a healthy one" -- the header of the
# box-walk gate that learned this the hard way.
SCHEDULED_AGENT_NOT_LOADED_TITLE_FMT = (
    "The background job for {feeds} is not registered"
)
SCHEDULED_AGENT_NOT_LOADED_DETAIL_FMT = (
    "launchd has no record of {label} at all, so nothing is scheduled to "
    "refresh {feeds}. An agent that is not loaded is not a healthy one -- it "
    "will never run, and no amount of waiting will change that."
)
SCHEDULED_AGENT_NOT_LOADED_FIX = (
    "Re-register the job from its plist. If the plist is missing, the "
    "installer did not finish this step and re-running the installer will "
    "restore it."
)
SCHEDULED_AGENT_NOT_LOADED_FIX_COMMAND_FMT = (
    "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/{label}.plist"
)

# CANNOT-RUN. We could not look. This must never be reported as "we looked
# and it was fine" -- the same discipline the runtime-ready check applies at
# install time, and the same reason run_all_rules turns a crashed rule into a
# finding rather than swallowing it.
SCHEDULED_AGENT_UNKNOWN_TITLE_FMT = (
    "Could not check the background job for {feeds}"
)
SCHEDULED_AGENT_UNKNOWN_DETAIL_FMT = (
    "The Doctor asked launchd about {label} and could not get a usable "
    "answer ({why}). This is not a report that the job is healthy -- it is a "
    "report that its health is unknown."
)
SCHEDULED_AGENT_UNKNOWN_FIX = (
    "Re-open this page. If it keeps saying this, include the support report "
    "from this window when you get in touch."
)
SCHEDULED_AGENT_UNKNOWN_FIX_COMMAND_FMT = (
    "launchctl print gui/$(id -u)/{label}"
)
