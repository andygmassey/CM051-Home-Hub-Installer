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


# ── check_imessage_fda (CX-60) ───────────────────────────────────────


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
