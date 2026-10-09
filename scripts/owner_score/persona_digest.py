#!/usr/bin/env python3
"""Render persona.json as a CONTEXT.md-shaped digest.

Purpose: a throwaway test workspace (never a customer's) can be given this file
as ~/.zeroclaw/workspace/CONTEXT.md, the owner cheat sheet the daemon injects
into every system prompt (ostler-assistant crates/zeroclaw-runtime/src/agent/
prompt.rs IdentitySection -> system_prompt::inject_workspace_file), so the 80
questions have something to be answered from without a seeded graph.
Heading shape follows scripts/generate_pwg_context.py in ostler-assistant.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def render(persona):
    out = ["# Personal Context", "",
           "Synthetic owner: %s. Facts as of %s." % (persona["owner"], persona["as_of"]), ""]
    for title, lines in persona["sections"].items():
        out.append("## " + title)
        out.extend("- " + l for l in lines)
        out.append("")
    return "\n".join(out).rstrip() + "\n"


if __name__ == "__main__":
    p = json.load(open(os.path.join(HERE, "persona.json")))
    sys.stdout.write(render(p))
