"""Shared fakes for the update-reprocess tests (Ollama + Qdrant + Oxigraph).

The LLM answers from the transcript in the prompt and counts its calls;
Qdrant is a dict of points; Oxigraph is a REAL pyoxigraph store, so the
retraction under test is real SPARQL against real data. ``handle`` takes
an httpx.Request so the same fake backs an in-process MockTransport AND
the HTTP server the CLI subprocess test talks to.
"""
from __future__ import annotations

import json
import re

import httpx
import pyoxigraph

LINE_RE = re.compile(r"^\[(\d\d:\d\d)\] ([A-Za-z]+): (.+)$", re.M)


class Fakes:
    """Ollama + Qdrant + Oxigraph behind one httpx MockTransport."""

    def __init__(self) -> None:
        self.store = pyoxigraph.Store()
        self.points: dict = {}
        self.llm_calls = 0
        self.store_writes = 0
        self.todo_texts: list[str] | None = None  # override bundle todos
        self.sensitivity = "normal"  # classifier verdict the fake returns

    # LLM ---------------------------------------------------------------
    def _answer(self, prompt: str) -> str:
        lines = LINE_RE.findall(prompt)
        last = lines[-1][2] if lines else "nothing"
        if "# Prompt 01" in prompt:
            return json.dumps({
                "setting": "work", "shape": "one-on-one", "stakes": "medium",
                "confidence": 0.9, "reasoning": "fake",
                "sensitivity": {"level": self.sensitivity, "categories": [], "reasoning": ""},
                "review_before_ingest": False, "processing_depth": "full",
                "hints_used": "none",
                "suggested_type_slug": "work_one-on-one_medium",
            })
        if "# Prompt 02" in prompt:
            from src.enrichment_validation import expected_headings_for
            return "\n".join(
                f"## {h}\n\n- Latest: {last}\n"
                for h in expected_headings_for("02_enrich_work_one-on-one")
            )
        if "# Prompt 05" in prompt:
            return json.dumps({"facts": [
                {"text": f"{who} said: {msg}", "type": "fact",
                 "subject": "user" if who == "Me" else "other:riley",
                 "domain": "work", "confidence": "stated",
                 "privacy_level": "L1", "signal_strength": "medium",
                 "temporal": False, "evidence": msg}
                for (_t, who, msg) in lines
            ]})
        if "You analyse a conversation transcript" in prompt:
            todos = self.todo_texts
            if todos is None:
                todos = [m for (_t, w, m) in lines if w == "Me" and "I will" in m]
            return json.dumps({
                "overall_summary": f"{len(lines)} messages; last: {last}",
                "topics": [{"name": "Project Sync",
                            "points": [m for (_t, _w, m) in lines]}],
                "todos": [{"text": t, "owner": "user"} for t in todos],
            })
        return json.dumps({})

    # Transport ---------------------------------------------------------
    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        body = request.content
        if path == "/api/generate":
            self.llm_calls += 1
            prompt = json.loads(body).get("prompt", "")
            return httpx.Response(200, json={"response": self._answer(prompt)})
        if path == "/api/embed":
            return httpx.Response(200, json={"embeddings": [[0.1] * 8]})
        if path.endswith("/points") and request.method == "PUT":
            self.store_writes += 1
            for p in json.loads(body)["points"]:
                self.points[p["id"]] = p
            return httpx.Response(200, json={"status": "ok"})
        if path.endswith("/points/delete"):
            self.store_writes += 1
            must = json.loads(body)["filter"]["must"]

            def matches(p):
                for m in must:
                    v = p["payload"].get(m["key"])
                    if "value" in m["match"] and v != m["match"]["value"]:
                        return False
                    if "any" in m["match"] and v not in m["match"]["any"]:
                        return False
                return True

            for pid in [k for k, p in self.points.items() if matches(p)]:
                del self.points[pid]
            return httpx.Response(200, json={"status": "ok"})
        if path.endswith("/points/search") or path.endswith("/points/query"):
            return httpx.Response(200, json={"result": []})
        if path == "/store":
            self.store_writes += 1
            graph = request.url.params.get("graph")
            self.store.load(
                body, format=pyoxigraph.RdfFormat.TURTLE,
                to_graph=pyoxigraph.NamedNode(graph) if graph else None,
            )
            return httpx.Response(204)
        if path == "/update":
            self.store_writes += 1
            self.store.update(body.decode())
            return httpx.Response(204)
        if path == "/query":
            ct = request.headers.get("content-type", "")
            if request.method == "GET":
                q = request.url.params.get("query", "")
            elif "sparql-query" in ct:
                q = body.decode()
            else:
                from urllib.parse import parse_qs
                q = parse_qs(body.decode()).get("query", [""])[0]
            res = self.store.query(q, use_default_graph_as_union=True)
            out = (res.serialize(format=pyoxigraph.QueryResultsFormat.JSON)
                   if hasattr(res, "serialize") else b'{"boolean": true}')
            return httpx.Response(200, content=out,
                                  headers={"content-type": "application/sparql-results+json"})
        return httpx.Response(200, json={"result": {}})

    # Read-backs --------------------------------------------------------
    def qdrant_fact_texts(self) -> list[str]:
        return sorted(p["payload"]["text"] for p in self.points.values()
                      if p["payload"].get("point_type") == "fact")

    def oxigraph_fact_texts(self) -> list[str]:
        q = "SELECT ?t WHERE { ?f a <urn:ostler:Fact> ; <urn:ostler:text> ?t }"
        return sorted(r["t"].value for r in
                      self.store.query(q, use_default_graph_as_union=True))

    def topic_mentions(self) -> int:
        q = ("SELECT ?m WHERE { ?m a <https://schema.ostler.ai/ontology#TopicMention> }")
        return len(list(self.store.query(q, use_default_graph_as_union=True)))
