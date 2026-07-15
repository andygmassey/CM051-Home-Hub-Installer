"""Step 4 verification: the backfill rule + dry-run safety.

The graph SELECT is mocked with fixtures so the test is hermetic. We assert:
- the deterministic type+source -> level mapping (private -> L1, public -> L2),
- private-channel nodes NEVER get L2,
- unknown provenance fails closed to L1,
- dry-run writes nothing,
- the planner is the single source (uses privacy_model.level_for).
"""
from __future__ import annotations

from unittest.mock import patch

import pytest

from contact_syncer import backfill_privacy as bf
from contact_syncer import privacy_model as pm


# Fixture rows keyed by rdf_type, mimicking _select_untagged output.
FIXTURE = {
    "PersonFact": [
        {"node": "u#fact_a", "type": "PersonFact", "source": "user_asserted"},
        {"node": "u#fact_b", "type": "PersonFact", "source": "linkedin_recommendation"},
        {"node": "u#fact_c", "type": "PersonFact", "source": ""},  # unknown
    ],
    "RelationshipSignal": [
        {"node": "u#sig_a", "type": "RelationshipSignal", "source": "whatsapp_contact"},
        {"node": "u#sig_b", "type": "RelationshipSignal", "source": "twitter_synced_contact"},
        {"node": "u#sig_c", "type": "RelationshipSignal", "source": "facebook_friend"},
        {"node": "u#sig_d", "type": "RelationshipSignal", "source": "linkedin_messaging"},
    ],
}


def _fake_select(oxigraph_url, rdf_type, limit):
    rows = FIXTURE.get(rdf_type, [])
    return rows[: limit] if limit else rows


class TestPlan:
    def test_plan_assigns_canonical_levels(self):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select):
            plan = bf.plan_backfill("http://x")
        by_node = {r["node"]: r["level"] for r in plan}
        # Private channels -> L1.
        assert by_node["u#fact_a"] == "L1"  # user_asserted
        assert by_node["u#sig_a"] == "L1"   # whatsapp
        assert by_node["u#sig_d"] == "L1"   # linkedin message content
        # Public / social -> L2.
        assert by_node["u#fact_b"] == "L2"  # linkedin recommendation
        assert by_node["u#sig_b"] == "L2"   # twitter
        assert by_node["u#sig_c"] == "L2"   # facebook friend
        # Unknown provenance fails closed to private.
        assert by_node["u#fact_c"] == "L1"

    def test_no_private_channel_is_ever_publishable(self):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select):
            plan = bf.plan_backfill("http://x")
        for r in plan:
            if pm._matches_any(r["source"].lower(), pm.PRIVATE_CHANNEL_SOURCE_MARKERS):
                assert r["level"] not in pm.PUBLISHABLE_LEVELS, r

    def test_summary_counts(self):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select):
            plan = bf.plan_backfill("http://x")
        counts = bf.summarise(plan)
        assert counts["total"] == 7
        assert counts["L1"] == 4  # user_asserted, whatsapp, linkedin_msg, unknown
        assert counts["L2"] == 3  # rec, twitter, fb

    def test_deterministic(self):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select):
            p1 = bf.plan_backfill("http://x")
            p2 = bf.plan_backfill("http://x")
        assert p1 == p2


class TestDryRunSafety:
    def test_main_dry_run_does_not_apply(self, capsys):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "apply_backfill") as ap:
            rc = bf.main(["--graph-endpoint", "http://x"])
        assert rc == 0
        ap.assert_not_called()
        out = capsys.readouterr().out
        assert "DRY RUN" in out
        assert "REVIEW FLAG" in out

    def test_main_apply_calls_writer(self, capsys):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "_apply_chunk") as chunk:
            rc = bf.main(["--graph-endpoint", "http://x", "--apply"])
        assert rc == 0
        chunk.assert_called_once()
        # The chunk SPARQL must contain L1 for the whatsapp node.
        sent = chunk.call_args[0][1]
        nodes = {r["node"]: r["level"] for r in sent}
        assert nodes["u#sig_a"] == "L1"

    def test_apply_backfill_chunks(self):
        plan = [{"node": f"u#n{i}", "level": "L1"} for i in range(450)]
        with patch.object(bf, "_apply_chunk") as chunk:
            written = bf.apply_backfill("http://x", plan, chunk_size=200)
        assert written == 450
        assert chunk.call_count == 3  # 200 + 200 + 50


class TestStartupBackfill:
    """The idempotent, observable startup/install entrypoint."""

    def test_stamps_untagged_to_visible_default_and_applies(self, caplog):
        caplog.set_level("INFO")
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "_apply_chunk") as chunk:
            result = bf.run_startup_backfill("http://x", apply=True)
        assert result["status"] == "applied"
        assert result["total"] == 7
        assert result["applied"] == 7
        # Visible default only: NEVER stamps L3 (body-suppressed).
        assert "L3" not in result["by_level"]
        assert result["by_level"]["L1"] == 4
        assert result["by_level"]["L2"] == 3
        chunk.assert_called_once()

    def test_apply_false_plans_but_writes_nothing(self):
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "apply_backfill") as ap:
            result = bf.run_startup_backfill("http://x", apply=False)
        assert result["status"] == "planned"
        assert result["applied"] == 0
        ap.assert_not_called()

    def test_no_untagged_is_a_noop(self):
        with patch.object(bf, "_select_untagged", return_value=[]), \
             patch.object(bf, "apply_backfill") as ap:
            result = bf.run_startup_backfill("http://x", apply=True)
        assert result["status"] == "clean"
        assert result["total"] == 0
        assert result["applied"] == 0
        ap.assert_not_called()  # nothing to write

    def test_rerun_after_apply_is_noop(self):
        """Idempotency: once tagged, the graph SELECT returns nothing, so a
        second startup run writes nothing (mirrors FILTER NOT EXISTS)."""
        # First boot: untagged rows present -> applies.
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "_apply_chunk"):
            first = bf.run_startup_backfill("http://x", apply=True)
        assert first["status"] == "applied"
        # Second boot: everything now tagged -> SELECT empty -> no-op.
        with patch.object(bf, "_select_untagged", return_value=[]), \
             patch.object(bf, "apply_backfill") as ap:
            second = bf.run_startup_backfill("http://x", apply=True)
        assert second["status"] == "clean"
        ap.assert_not_called()

    def test_observability_counts_would_be_hidden_nodes(self, caplog):
        caplog.set_level("WARNING")
        with patch.object(bf, "_select_untagged", side_effect=_fake_select), \
             patch.object(bf, "_apply_chunk"):
            result = bf.run_startup_backfill("http://x", apply=True)
        # The dropped-fact count is surfaced (not silent).
        assert result["total"] == 7
        msg = " ".join(r.getMessage() for r in caplog.records)
        assert "HIDDEN as unknown-privacy" in msg
        assert "7" in msg

    def test_graph_error_is_fail_safe(self):
        def _boom(*a, **k):
            raise RuntimeError("oxigraph down")
        with patch.object(bf, "_select_untagged", side_effect=_boom):
            result = bf.run_startup_backfill("http://x", apply=True)
        assert result["status"] == "error"
        assert result["applied"] == 0

    def test_refuses_when_private_channel_plans_publishable(self):
        """Guards against a future rule bug leaking private content."""
        leaky = [{"node": "u#leak", "type": "PersonFact",
                  "source": "whatsapp"}]
        with patch.object(bf, "_select_untagged",
                          side_effect=lambda u, t, l: leaky if t == "PersonFact" else []), \
             patch.object(pm, "level_for", return_value="L2"), \
             patch.object(bf, "apply_backfill") as ap:
            result = bf.run_startup_backfill("http://x", apply=True)
        assert result["status"] == "refused"
        ap.assert_not_called()


class TestCountUntagged:
    def test_aggregates_per_type_total(self):
        with patch.object(bf, "_count_untagged",
                          side_effect=lambda u, t: {"PersonFact": 12,
                                                    "RelationshipSignal": 4196}[t]):
            counts = bf.count_untagged("http://x")
        assert counts["PersonFact"] == 12
        assert counts["RelationshipSignal"] == 4196
        assert counts["total"] == 4208
