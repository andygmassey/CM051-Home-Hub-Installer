"""
Ostler Doctor – First Run Wizard

When Ostler Doctor detects that Ostler has never been fully set up
(no import has been run, services may be partially configured),
it shows a guided setup wizard instead of the normal dashboard.

The wizard walks through:
1. Docker check
2. Service startup
3. Ollama + model check
4. Import readiness verification
5. First import guidance

After the first successful import, the wizard is marked complete
and the normal dashboard is shown.
"""

from __future__ import annotations

import os
from pathlib import Path

from first_run_copy import (
    STEP1_TITLE,
    STEP1_DETAIL_NOT_RUNNING,
    STEP1_DETAIL_RUNNING_FMT,
    STEP1_ACTION_NOT_RUNNING,
    STEP1_ACTION_COMMAND_NOT_RUNNING,
    STEP2_TITLE,
    STEP2_DETAIL_COMPLETE,
    STEP2_DETAIL_PARTIAL_FMT,
    STEP2_DETAIL_NO_CONTAINERS,
    STEP2_DETAIL_WAITING_DOCKER,
    STEP2_ACTION_START_PARTIAL,
    STEP2_ACTION_START_NEEDED,
    STEP2_ACTION_BLOCKED,
    STEP2_ACTION_COMMAND,
    STEP3_TITLE,
    STEP3_DETAIL_COMPLETE_FMT,
    STEP3_DETAIL_PARTIAL_FMT,
    STEP3_DETAIL_NEEDED,
    STEP3_ACTION_PULL_EMBED,
    STEP3_ACTION_COMMAND_PULL_EMBED,
    STEP3_ACTION_INSTALL,
    STEP3_ACTION_COMMAND_INSTALL,
    STEP4_TITLE,
    STEP4_DETAIL_COMPLETE,
    STEP4_DETAIL_WAITING_FMT,
    STEP4_DETAIL_WAITING_EMBED,
    STEP4_ACTION_RUN_IMPORT,
    STEP4_ACTION_COMMAND_IMPORT,
    STEP4_ACTION_BLOCKED,
    WIZARD_TITLE_TAG,
    WIZARD_HEADING,
    WIZARD_SUBTITLE,
    WIZARD_REFRESH_LABEL,
    WIZARD_STEP_PREFIX,
    WIZARD_CLICK_TO_COPY,
    WIZARD_DONE_HEADING,
    WIZARD_DONE_BODY,
)
from status_collector import (
    SystemSnapshot,
    EXPECTED_OSTLER_SERVICES,
    detect_ostler_prefix,
    is_ostler_container,
)


OSTLER_DIR = Path.home() / ".ostler"
WIZARD_COMPLETE_FLAG = OSTLER_DIR / ".setup-complete"


def is_first_run() -> bool:
    """Check if this is the first run (setup wizard not completed)."""
    return not WIZARD_COMPLETE_FLAG.exists()


def mark_setup_complete() -> None:
    """Mark the setup wizard as complete."""
    WIZARD_COMPLETE_FLAG.parent.mkdir(parents=True, exist_ok=True)
    WIZARD_COMPLETE_FLAG.write_text("completed\n")


def get_wizard_steps(snapshot: SystemSnapshot) -> list[dict]:
    """Determine wizard step statuses from current system state."""
    steps = []

    # Step 1: Docker
    docker_ok = snapshot.docker_version is not None
    steps.append({
        "number": 1,
        "title": STEP1_TITLE,
        "status": "complete" if docker_ok else "needed",
        "detail": (
            STEP1_DETAIL_RUNNING_FMT.format(version=snapshot.docker_version)
            if docker_ok else STEP1_DETAIL_NOT_RUNNING
        ),
        "action": None if docker_ok else STEP1_ACTION_NOT_RUNNING,
        "action_command": None if docker_ok else STEP1_ACTION_COMMAND_NOT_RUNNING,
    })

    # Step 2: Ostler services. Detect the deployment's container-name
    # prefix dynamically so we work for productised installs (ostler-)
    # and the dev compose setup (pwg-).
    prefix = detect_ostler_prefix(snapshot)
    ostler_running = any(
        is_ostler_container(c) and c.state == "running"
        for c in snapshot.docker_containers
    )
    expected = {f"{prefix}{svc}" for svc in EXPECTED_OSTLER_SERVICES}
    running = {c.name for c in snapshot.docker_containers if c.state == "running"}
    services_ok = expected.issubset(running)

    if services_ok:
        steps.append({
            "number": 2,
            "title": STEP2_TITLE,
            "status": "complete",
            "detail": STEP2_DETAIL_COMPLETE,
            "action": None,
            "action_command": None,
        })
    elif ostler_running:
        missing = expected - running
        steps.append({
            "number": 2,
            "title": STEP2_TITLE,
            "status": "partial",
            "detail": STEP2_DETAIL_PARTIAL_FMT.format(
                missing=", ".join(m.replace(prefix, "") for m in missing),
            ),
            "action": STEP2_ACTION_START_PARTIAL,
            "action_command": STEP2_ACTION_COMMAND,
        })
    else:
        steps.append({
            "number": 2,
            "title": STEP2_TITLE,
            "status": "needed" if docker_ok else "blocked",
            "detail": (
                STEP2_DETAIL_NO_CONTAINERS if docker_ok
                else STEP2_DETAIL_WAITING_DOCKER
            ),
            "action": (
                STEP2_ACTION_START_NEEDED if docker_ok
                else STEP2_ACTION_BLOCKED
            ),
            "action_command": STEP2_ACTION_COMMAND if docker_ok else None,
        })

    # Step 3: Ollama + embedding model
    ollama_ok = snapshot.ollama_version is not None
    has_embed = any("nomic-embed" in m.name for m in snapshot.ollama_models)

    if ollama_ok and has_embed:
        steps.append({
            "number": 3,
            "title": STEP3_TITLE,
            "status": "complete",
            "detail": STEP3_DETAIL_COMPLETE_FMT.format(
                version=snapshot.ollama_version,
            ),
            "action": None,
            "action_command": None,
        })
    elif ollama_ok and not has_embed:
        steps.append({
            "number": 3,
            "title": STEP3_TITLE,
            "status": "partial",
            "detail": STEP3_DETAIL_PARTIAL_FMT.format(
                version=snapshot.ollama_version,
            ),
            "action": STEP3_ACTION_PULL_EMBED,
            "action_command": STEP3_ACTION_COMMAND_PULL_EMBED,
        })
    else:
        steps.append({
            "number": 3,
            "title": STEP3_TITLE,
            "status": "needed",
            "detail": STEP3_DETAIL_NEEDED,
            "action": STEP3_ACTION_INSTALL,
            "action_command": STEP3_ACTION_COMMAND_INSTALL,
        })

    # Step 4: Service health
    healthy_names = {s.name for s in snapshot.services if s.status == "healthy"}
    required = {"qdrant", "oxigraph", "ollama"}
    all_healthy = required.issubset(healthy_names)

    if all_healthy and has_embed:
        steps.append({
            "number": 4,
            "title": STEP4_TITLE,
            "status": "complete",
            "detail": STEP4_DETAIL_COMPLETE,
            "action": STEP4_ACTION_RUN_IMPORT,
            "action_command": STEP4_ACTION_COMMAND_IMPORT,
        })
    else:
        missing_svc = required - healthy_names
        steps.append({
            "number": 4,
            "title": STEP4_TITLE,
            "status": "blocked",
            "detail": (
                STEP4_DETAIL_WAITING_FMT.format(
                    missing=", ".join(missing_svc),
                )
                if missing_svc else STEP4_DETAIL_WAITING_EMBED
            ),
            "action": STEP4_ACTION_BLOCKED,
            "action_command": None,
        })

    return steps


def render_wizard(snapshot: SystemSnapshot, steps: list[dict]) -> str:
    """Render the first-run wizard as HTML."""
    steps_html = ""
    for step in steps:
        status_color = {
            "complete": "#5cb579",
            "partial": "#d4a052",
            "needed": "#d96666",
            "blocked": "#4a4540",
        }.get(step["status"], "rgba(236,232,221,0.40)")

        status_icon = {
            "complete": "&#10003;",
            "partial": "&#9888;",
            "needed": "&#9679;",
            "blocked": "&#8211;",
        }.get(step["status"], "?")

        action_html = ""
        if step.get("action_command"):
            action_html = f"""
            <div style="margin-top:12px;background:#0a0908;border:1px solid var(--border);border-radius:6px;padding:12px 16px;">
                <div style="font-size:0.78rem;color:var(--text-muted);margin-bottom:4px;">{step['action']}</div>
                <code style="font-family:'SF Mono',monospace;font-size:0.82rem;color:var(--amber-light);cursor:pointer;user-select:all;"
                      onclick="navigator.clipboard.writeText(this.textContent).then(()=>this.style.color='#5cb579')"
                >{step['action_command']}</code>
                <div style="font-size:0.68rem;color:var(--text-faint);margin-top:4px;">{WIZARD_CLICK_TO_COPY}</div>
            </div>"""
        elif step.get("action"):
            action_html = f'<div style="margin-top:8px;font-size:0.85rem;color:var(--text-muted);">{step["action"]}</div>'

        steps_html += f"""
        <div style="display:flex;gap:16px;align-items:flex-start;margin-bottom:32px;opacity:{'1' if step['status'] != 'blocked' else '0.5'};">
            <div style="width:36px;height:36px;border-radius:50%;background:{status_color};display:flex;align-items:center;justify-content:center;font-size:0.9rem;color:white;flex-shrink:0;margin-top:2px;">{status_icon}</div>
            <div style="flex:1;">
                <div style="font-size:1rem;font-weight:600;margin-bottom:4px;">{WIZARD_STEP_PREFIX} {step['number']}: {step['title']}</div>
                <div style="font-size:0.88rem;color:var(--text-secondary);">{step['detail']}</div>
                {action_html}
            </div>
        </div>"""

    all_complete = all(s["status"] == "complete" for s in steps)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{WIZARD_TITLE_TAG}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap');
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        :root {{
            /* Ostler dark palette (mirrors apple_style.css). The wizard
               shares the dashboard's tokens so the welcome -> dashboard
               transition feels seamless. */
            --bg: #0d0b08;
            --bg-card: #1a1612;
            --bg-elevated: #221c16;
            --border: rgba(236, 232, 221, 0.16);
            --border-subtle: rgba(236, 232, 221, 0.08);
            --text-primary: #ECE8DD;
            --text-secondary: rgba(236, 232, 221, 0.74);
            --text-muted: rgba(236, 232, 221, 0.50);
            --text-faint: rgba(236, 232, 221, 0.32);
            /* The wizard already references --amber via inline styles.
               Rebind to oxblood so the wording stays the same but the
               surface reads brand-true. */
            --amber: #C84545;
            --amber-light: #E26A6A;
            --amber-glow: rgba(200, 69, 69, 0.18);
            --font-display: 'Outfit', -apple-system, system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', -apple-system, system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        body {{
            font-family: var(--font-body);
            background: var(--bg);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }}
        .wizard {{ max-width: 600px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.7rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 6px;
            color: var(--text-primary);
        }}
        h2 {{
            font-family: var(--font-display);
            font-weight: 600;
            letter-spacing: -0.01em;
        }}
        .subtitle {{
            font-family: var(--font-mono);
            color: var(--text-muted);
            font-size: 0.78rem;
            letter-spacing: 0.04em;
            margin-bottom: 48px;
        }}
        .refresh {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            margin-top: 20px;
            padding: 10px 18px;
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 999px;
            color: var(--text-secondary);
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.82rem;
            cursor: pointer;
            text-decoration: none;
            transition: border-color 0.18s, color 0.18s, background 0.18s, transform 0.18s, box-shadow 0.18s;
        }}
        .refresh:hover {{
            border-color: var(--amber);
            color: var(--text-primary);
            background: var(--bg-elevated);
            transform: translateY(-1px);
            box-shadow: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
        }}
        .done-box {{
            background: var(--amber-glow);
            border: 1px solid var(--amber);
            border-radius: 12px;
            padding: 28px;
            text-align: center;
            margin-top: 36px;
            box-shadow: 0 1px 2px rgba(0,0,0,0.40), 0 8px 24px rgba(0,0,0,0.32);
        }}
        .done-box h2 {{
            font-family: var(--font-display);
            font-size: 1.15rem;
            font-weight: 600;
            color: var(--amber-light);
            margin-bottom: 10px;
            letter-spacing: -0.005em;
        }}
        .done-box p {{
            font-family: var(--font-body);
            font-size: 0.92rem;
            color: var(--text-secondary);
            line-height: 1.55;
        }}
        a:focus-visible {{
            outline: 2px solid var(--amber);
            outline-offset: 2px;
        }}
        code {{
            font-family: var(--font-mono);
            font-size: 0.82rem;
        }}
    </style>
</head>
<body>
    <div class="wizard">
        <h1>{WIZARD_HEADING}</h1>
        <div class="subtitle">{WIZARD_SUBTITLE}</div>

        {steps_html}

        {f'<div class="done-box"><h2>{WIZARD_DONE_HEADING}</h2><p>{WIZARD_DONE_BODY}</p></div>' if all_complete else ''}

        <a href="/doctor" class="refresh">{WIZARD_REFRESH_LABEL}</a>
    </div>
</body>
</html>"""
