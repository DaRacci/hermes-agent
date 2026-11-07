"""The injected kanban protocol must agree with the session's tool schema.

A dispatcher-spawned worker holds the reporting tools only. Telling it to fan out buys a failed
call on the exact path that once produced a five-card chain, and the model's fallback is
``hermes kanban create`` in the shell. The orchestration half therefore rides a session whose
schema actually carries ``kanban_create`` (an orchestrator profile working a decomposition card).
"""
from __future__ import annotations

from agent.prompt_builder import KANBAN_GUIDANCE, build_kanban_guidance

WORKER_NAMES = {
    "kanban_show", "kanban_complete", "kanban_block", "kanban_schedule",
    "kanban_request_review", "kanban_request_changes", "kanban_heartbeat",
    "kanban_comment", "kanban_attach", "kanban_attach_url", "kanban_attachments",
}
ORCHESTRATOR_NAMES = WORKER_NAMES | {"kanban_list", "kanban_create", "kanban_link", "kanban_unblock"}


def test_worker_guidance_never_points_at_a_routing_tool():
    guidance = build_kanban_guidance(WORKER_NAMES)

    for tool in ("`kanban_create`", "`kanban_link`", "`kanban_list`", "`kanban_unblock`", "created_cards"):
        assert tool not in guidance
    assert "`hermes kanban create`" in guidance, "the shell fallback must be forbidden by name"
    assert "summary or metadata" in guidance, "a worker must be told where follow-up work goes"


def test_worker_guidance_is_the_default_block():
    """``KANBAN_GUIDANCE`` is what a worker gets; the split must not change that contract."""
    assert build_kanban_guidance(WORKER_NAMES) == KANBAN_GUIDANCE
    assert build_kanban_guidance() == KANBAN_GUIDANCE


def test_orchestrator_guidance_carries_the_fan_out_playbook():
    guidance = build_kanban_guidance(ORCHESTRATOR_NAMES)

    assert "## Orchestrator mode" in guidance
    assert "`kanban_create`" in guidance
    assert "created_cards" in guidance
    assert "parents=[...]" in guidance
    assert "Do not assign follow-up work to yourself" in guidance


def test_both_halves_keep_the_reporting_and_ownership_rules():
    for names in (WORKER_NAMES, ORCHESTRATOR_NAMES):
        guidance = build_kanban_guidance(names)
        for tool in ("kanban_show", "kanban_complete", "kanban_block", "kanban_request_review",
                     "kanban_heartbeat", "kanban_comment"):
            assert tool in guidance
        assert "## Do NOT" in guidance
        assert "delegate_task" in guidance
