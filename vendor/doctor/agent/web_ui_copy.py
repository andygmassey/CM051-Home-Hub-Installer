"""Customer-facing copy for the Doctor local diagnostic dashboard.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string the Doctor dashboard shows the customer.

The dashboard surfaces fall into four buckets:

1. ``run_local_diagnostics`` inline rule findings (title / detail /
   fix / fix_command). These mirror the catalogue shape in
   ``diagnostic_copy.py`` -- they live here rather than there because
   they are the dashboard's own legacy rule body, not the rule-engine
   rules. Future consolidation may merge the two.
2. Email-report body lines + section headers (the plain-text report
   the "Send by Email" button generates).
3. Mailto subject + body (the pre-populated email that opens in the
   user's mail client).
4. HTML page chrome -- titles, section headings, button labels,
   footer copy, help text. The HTML chunks themselves stay opaque:
   we lift the human-readable text that appears between tags, not
   the surrounding markup.

Conventions:
- British English throughout.
- No em-dashes (project brand rule). Existing en-dashes preserved
  verbatim where they appear in legacy markup (e.g. ``&ndash;``
  HTML entities in page titles).
- Apple-Restraint voice: observational, not punitive.
- HTML entities (``&ndash;``, ``&hellip;``, ``&#9888;``, etc.) are
  preserved verbatim in catalogue values because the rendered HTML
  must stay byte-identical to the pre-lift dashboard.
- Format-string placeholders use named ``.format()`` interpolation.

This module is imported by ``web_ui.py``. Adding a new string:
define the constant here, import and reference from the renderer
body; never inline.
"""

from __future__ import annotations


# ── run_local_diagnostics findings ───────────────────────────────────


DOCKER_NOT_RUNNING_TITLE = "Docker not running or no containers found"
DOCKER_NOT_RUNNING_DETAIL = (
    "Ostler needs Docker to run its services. Is Docker Desktop started?"
)
DOCKER_NOT_RUNNING_FIX = (
    "Open Docker Desktop from your Applications folder, wait for it to "
    "start, then refresh this page."
)
DOCKER_NOT_RUNNING_FIX_COMMAND = "open -a Docker"

CONTAINER_NOT_RUNNING_TITLE_FMT = "Container '{name}' is not running"
CONTAINER_NOT_RUNNING_DETAIL_FMT = "The {short_name} service is down."
CONTAINER_NOT_RUNNING_FIX = "Restart the container"
CONTAINER_NOT_RUNNING_FIX_COMMAND = "cd ~/.ostler && docker compose up -d"

CONTAINER_EXITED_TITLE_FMT = "Container '{name}' has exited"
CONTAINER_EXITED_DETAIL_FMT = (
    "Status: {status}. This container stopped – it may need restarting."
)
CONTAINER_EXITED_FIX = "Restart the container"
CONTAINER_EXITED_FIX_COMMAND_FMT = "docker restart {name}"

NO_OLLAMA_MODELS_FOUND_TITLE = "No Ollama models found"
NO_OLLAMA_MODELS_FOUND_DETAIL = (
    "Ostler needs at least the nomic-embed-text model for embeddings."
)
NO_OLLAMA_MODELS_FOUND_FIX = "Pull the embedding model"
NO_OLLAMA_MODELS_FOUND_FIX_COMMAND = "ollama pull nomic-embed-text"

EMBED_MODEL_MISSING_TITLE = "Embedding model (nomic-embed-text) not installed"
EMBED_MODEL_MISSING_DETAIL = (
    "You have Ollama models but not the one Ostler needs for vector embeddings."
)
EMBED_MODEL_MISSING_FIX = "Pull the embedding model"
EMBED_MODEL_MISSING_FIX_COMMAND = "ollama pull nomic-embed-text"

SERVICE_UNREACHABLE_TITLE_FMT = "Service '{name}' is unreachable"
SERVICE_UNREACHABLE_DETAIL_FMT = (
    "Cannot connect to {name}. The service may not be running."
)
SERVICE_UNREACHABLE_FIX_FMT = "Check if the {name} container is running"
SERVICE_UNREACHABLE_FIX_COMMAND_FMT = "docker ps | grep {name}"

SERVICE_UNHEALTHY_TITLE_FMT = "Service '{name}' is unhealthy (HTTP {status_code})"
SERVICE_UNHEALTHY_DETAIL_FMT = (
    "{name} is reachable but returned an error status."
)
SERVICE_UNHEALTHY_FIX_FMT = "Restart the {name} container"
SERVICE_UNHEALTHY_FIX_COMMAND_FMT = "docker restart {prefix}{name}"

DISK_NEARLY_FULL_TITLE_FMT = (
    "Disk nearly full ({percent_used}% used on {mount_point})"
)
DISK_NEARLY_FULL_DETAIL_FMT = "Only {free_gb:.1f} GB free. Services may crash."
DISK_NEARLY_FULL_FIX = (
    "Free up disk space – check Docker images and Ollama models"
)
DISK_NEARLY_FULL_FIX_COMMAND = "docker system prune -f && ollama list"

DISK_GETTING_FULL_TITLE_FMT = (
    "Disk getting full ({percent_used}% used on {mount_point})"
)
DISK_GETTING_FULL_DETAIL_FMT = "{free_gb:.1f} GB free. Keep an eye on this."

NETWORK_FAIL_TITLE_FMT = "Network: {source} cannot reach {target}"
NETWORK_FAIL_DETAIL_FMT = (
    "The connection from {source} to {target} failed."
)
NETWORK_FAIL_FIX_FMT = "Check that {target} is running"

DOCKER_VERSION_OLD_TITLE_FMT = "Docker version {version} is old"
DOCKER_VERSION_OLD_DETAIL = (
    "Docker 24+ is recommended. Older versions may have compose "
    "compatibility issues."
)
DOCKER_VERSION_OLD_FIX = "Update Docker Desktop"
DOCKER_VERSION_OLD_FIX_COMMAND = "brew upgrade --cask docker"

OLLAMA_CONSIDER_UPDATE_TITLE_FMT = "Ollama {version} – consider updating"
OLLAMA_CONSIDER_UPDATE_DETAIL = (
    "Newer Ollama versions have better model support and performance."
)
OLLAMA_CONSIDER_UPDATE_FIX = "Update Ollama"
OLLAMA_CONSIDER_UPDATE_FIX_COMMAND = "brew upgrade ollama"

OLLAMA_MODELS_DISK_USE_TITLE_FMT = "Ollama models using {total_gb:.0f} GB of disk"
OLLAMA_MODELS_DISK_USE_DETAIL = (
    "You have a lot of models downloaded. Consider removing ones you "
    "do not use."
)
OLLAMA_MODELS_DISK_USE_FIX = "List models and remove unused ones"
OLLAMA_MODELS_DISK_USE_FIX_COMMAND = "ollama list"

PORT_CONFLICT_TITLE_FMT = (
    "Possible port conflict: '{name}' may conflict with {service}"
)
PORT_CONFLICT_DETAIL_FMT = (
    "Container '{name}' ({image}) is running and might be using port {port}."
)
PORT_CONFLICT_FIX = "Check if this container conflicts with Ostler services"
PORT_CONFLICT_FIX_COMMAND_FMT = "docker port {name}"

QDRANT_NO_EMBED_MODEL_TITLE = "Qdrant is running but no embedding model available"
QDRANT_NO_EMBED_MODEL_DETAIL = (
    "You will not be able to import data until Ollama has the "
    "nomic-embed-text model."
)
QDRANT_NO_EMBED_MODEL_FIX = "Pull the embedding model"
QDRANT_NO_EMBED_MODEL_FIX_COMMAND = "ollama pull nomic-embed-text"

ALL_HEALTHY_TITLE = "Everything looks healthy"
ALL_HEALTHY_DETAIL = (
    "All services running, disk OK, network OK. Nice one."
)


# ── _format_report (plain-text email report) ─────────────────────────


REPORT_HEADER = "Ostler Doctor – Diagnostic Report"
REPORT_GENERATED_LABEL = "Generated:"
REPORT_HOST_OS_LABEL = "Host OS:"
REPORT_DOCKER_LABEL = "Docker:"
REPORT_OLLAMA_LABEL = "Ollama:"
REPORT_SECTION_SERVICES = "Services"
REPORT_SECTION_CONTAINERS = "Docker containers"
REPORT_SECTION_MODELS = "Ollama models"
REPORT_SECTION_DISK = "Disk usage"
REPORT_SECTION_FINDINGS = "Diagnostic findings"
REPORT_SECTION_NOTES = "Notes from user"
REPORT_NOTES_PLACEHOLDER = (
    "(Add your description of the issue here before sending.)"
)
REPORT_FIX_LABEL = "Fix:"


# ── _build_mailto (email subject + body) ─────────────────────────────


MAILTO_SUBJECT_FMT = "Ostler support request (v{version}, {today})"
MAILTO_BODY_INTRO = (
    "Hi Ostler support,\n\n"
    "I could use a hand with something. Here is my diagnostic report:\n\n"
)
MAILTO_BODY_OUTRO = "\n\nThanks,\n"


# ── render_dashboard (main /doctor page) ─────────────────────────────


DASHBOARD_TITLE_TAG = "Ostler Doctor &ndash; Diagnostics"
DASHBOARD_HEADING = "&#129658; Ostler Doctor"
DASHBOARD_SUBTITLE_FMT = "Diagnostic dashboard &ndash; {hostname}"
DASHBOARD_HOSTNAME_UNKNOWN = "unknown host"

DASHBOARD_BTN_REFRESH = "&#8635; Refresh"
DASHBOARD_BTN_AUTO_ON = "Auto: ON"
DASHBOARD_BTN_AUTO_OFF = "Auto: OFF"
DASHBOARD_BTN_EMAIL = "&#9993; Send by Email"
DASHBOARD_BTN_EMAIL_PREPARING = "Preparing…"
DASHBOARD_BTN_EMAIL_TITLE = (
    "Open your email client with the diagnostic report ready to send "
    "to support"
)

DASHBOARD_LAST_CHECKED_JUST_NOW = "Last checked: just now"
DASHBOARD_LAST_CHECKED_PREFIX = "Last checked: "
DASHBOARD_LAST_CHECKED_SUFFIX = "s ago"

DASHBOARD_SECTION_FINDINGS = "Diagnostic Findings"
DASHBOARD_SECTION_SERVICES = "Services"
DASHBOARD_SECTION_CONTAINERS = "Docker Containers"
DASHBOARD_SECTION_MODELS = "Ollama Models"
DASHBOARD_SECTION_DISK = "Disk Usage"
DASHBOARD_SECTION_HELP = "Need help?"

DASHBOARD_NO_CONTAINERS = "No containers found"
DASHBOARD_NO_MODELS = "No models found"

DASHBOARD_HELP_PARAGRAPH_1 = (
    "Everything Ostler Doctor sees stays on this Mac. If something is "
    "not working and you want a human to take a look, the "
    "<strong>Send by Email</strong> button at the top of this page "
    "will open your email client with the diagnostic report pre-populated. "
    "You can review it, add your notes, and send when you are ready."
)
DASHBOARD_HELP_PARAGRAPH_2 = (
    "Prefer to self-diagnose? Every finding above has a suggested fix "
    "command you can copy and run. You can also paste the report into "
    "any AI assistant you already use."
)

DASHBOARD_FIX_LABEL_FMT = "Suggested fix ({risk} risk):"
DASHBOARD_FIX_NOTE = (
    "Copy and paste this into Terminal. Ostler Doctor never runs "
    "commands for you."
)

DASHBOARD_META_FMT = (
    "Snapshot taken: {timestamp}Z &ndash; "
    "OS: {os_version} &ndash; "
    "Docker: {docker_version} &ndash; "
    "Ollama: {ollama_version}"
    " &ndash; <a href=\"/doctor/history\">History</a>"
)
DASHBOARD_META_OS_UNKNOWN = "unknown"
DASHBOARD_META_DOCKER_NONE = "not detected"
DASHBOARD_META_OLLAMA_NONE = "not detected"

DASHBOARD_IMPORT_EVERNOTE_LINK = (
    ' &ndash; <a href="/import-evernote">Import Evernote</a>'
)

DASHBOARD_ALERT_REPORT_FAIL = (
    "Could not prepare report. Please try again."
)
DASHBOARD_ALERT_REPORT_ERROR_FMT = "Could not prepare report: "


# ── render_history (/doctor/history page) ────────────────────────────


HISTORY_TITLE_TAG = "Ostler Doctor &ndash; History"
HISTORY_HEADING = "&#128736; Ostler Doctor &ndash; History"
HISTORY_SUBTITLE_FMT = (
    "Last {count} snapshots (most recent first) &ndash; "
    "<a href=\"/doctor\">Back to dashboard</a>"
)
HISTORY_EMPTY = (
    "No history yet. Ostler Doctor starts recording snapshots when the "
    "dashboard loads."
)
HISTORY_COL_TIMESTAMP = "Timestamp"
HISTORY_COL_SERVICES = "Services"
HISTORY_COL_CONTAINERS = "Containers"
HISTORY_COL_FINDINGS = "Findings"
HISTORY_RUNNING_FMT = "{running}/{total} running"
HISTORY_WAS_FMT = "(was {prev})"
HISTORY_CRITICAL_FMT = "{count} critical"
HISTORY_WARNING_FMT = "{count} warning"
HISTORY_ALL_CLEAR = "all clear"


# ── _render_import_evernote_page (/import-evernote) ──────────────────


EVERNOTE_TITLE_TAG = "Ostler Doctor &ndash; Import Evernote"
EVERNOTE_HEADING = "Import Evernote"
EVERNOTE_SUBTITLE = (
    "CM024 Knowledge import &ndash; "
    "<a href=\"/doctor\">Back to dashboard</a>"
)

EVERNOTE_SECTION_SOURCE = "Source file"
EVERNOTE_INTRO_HTML = (
    "Paste the path to an Evernote export "
    "<code style=\"font-family:var(--font-mono);font-size:0.82rem;"
    "background:var(--ostler-ink-deep);padding:0.05rem 0.3rem;"
    "border-radius:3px;color:var(--ostler-accent-warm)\">.enex</code> "
    "file. Ostler converts the notes into searchable knowledge stored "
    "in the personal wiki. The import runs in the background and "
    "survives closing this tab."
)
EVERNOTE_LABEL_PATH = "Path to .enex file"
EVERNOTE_PLACEHOLDER_PATH = "/Users/you/Downloads/MyNotes.enex"
EVERNOTE_HELP_TIP_HTML = (
    "Tip: drag the file from Finder into a Terminal window to get the "
    "absolute path. Or use <code>~/Downloads/file.enex</code> &mdash; "
    "the tilde is expanded for you."
)
EVERNOTE_BTN_START = "Start import"
EVERNOTE_BTN_STARTING = "Starting…"

EVERNOTE_SECTION_STATUS = "Import status"
EVERNOTE_SECTION_LOG_TAIL = "Log tail"
EVERNOTE_PILL_STARTING = "starting"
EVERNOTE_WAITING_FIRST_LOG = "Waiting for first log output&hellip;"
EVERNOTE_BTN_IMPORT_ANOTHER = "Import another"

EVERNOTE_META_FOOTER_HTML = (
    "Imports land in <code style=\"font-family:var(--font-mono);"
    "font-size:0.7rem\">~/.ostler/data/knowledge-staging/</code> "
    "&ndash; the wiki compiler picks them up on the next rebuild."
)

EVERNOTE_ERROR_NO_PATH = "Please paste the path to a .enex file."
EVERNOTE_ERROR_JOB_NOT_FOUND = "Job not found. Reload the page."
EVERNOTE_ERROR_STATUS_FAIL_PREFIX = "Status check failed: "
EVERNOTE_ERROR_NETWORK_PREFIX = "Network error: "
EVERNOTE_ERROR_IMPORT_FAIL_FMT = "Import failed to start (HTTP {status})"
"""Used JS-side: kept here as the canonical reference for the
``'Import failed to start (HTTP ' + status + ')'`` JS concatenation
at the ``showError(body.error || ...)`` call site. Not imported by
Python directly -- the JS source still composes the string at run
time. Future cleanup can lift the JS side to a window-injected
constant."""

EVERNOTE_STATUS_JOB_FMT = "job {job_id}"
EVERNOTE_STATUS_STARTED_FMT = "started {ts}Z"
EVERNOTE_STATUS_FINISHED_FMT = "finished {ts}Z"
EVERNOTE_STATUS_EXIT_FMT = "exit {code}"
"""The four status-meta strings above are composed JS-side inside the
``renderStatus(state)`` function via direct string concatenation
(``'job ' + state.job_id``, etc). They are catalogued here as the
canonical English reference but the JS source still owns the runtime
composition. Future cleanup can lift the JS side to a
window-injected constants block at the top of the rendered template."""


# ── Console banner (printed at __main__) ─────────────────────────────


CONSOLE_RUNNING_FMT = (
    "\n  Ostler Doctor is running at http://localhost:{port}/doctor\n"
)


# ── FastAPI app title ────────────────────────────────────────────────


APP_TITLE = "Ostler Doctor – Local Dashboard"
