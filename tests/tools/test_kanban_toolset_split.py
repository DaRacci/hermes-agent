"""The kanban worker/orchestrator split is a capability boundary, not a convention.

A dispatcher-spawned worker reports on the card it was handed. It must not be able to
list, create, link or unblock cards: a "done" report that files a follow-up card becomes
a chain when the tool is one call away, and a human never chose that backlog.

`kanban` is the worker toolset; `kanban_orchestrator` is that surface plus board routing.
The routing tools register only in the orchestrator toolset, the dispatcher strips that
toolset from a worker's schema selection, and the handlers refuse a `HERMES_KANBAN_TASK`
caller as a last line of defence.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent.delegation_context import DELEGATED_CHILD_ENV_MARKER

ROUTING_TOOLS = frozenset({"kanban_list", "kanban_create", "kanban_link", "kanban_unblock"})
WORKER_TOOLS = frozenset({
    "kanban_show", "kanban_complete", "kanban_block", "kanban_schedule",
    "kanban_request_review", "kanban_request_changes", "kanban_heartbeat",
    "kanban_comment", "kanban_attach", "kanban_attach_url", "kanban_attachments",
})


@pytest.fixture
def home(tmp_path, monkeypatch):
    """An isolated profile home; the board lands under it."""
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("HERMES_PROFILE", "split-test")
    monkeypatch.delenv("HERMES_SESSION_ID", raising=False)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return home


@pytest.fixture
def task_id(home):
    """A claimed card on a real board, the way the dispatcher leaves one."""
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc

    kb._INITIALIZED_PATHS.clear()
    kb.init_db()
    with kbc.connect() as conn:
        tid = kb.create_task(conn, title="worker card", assignee="split-test")
        assert kb.claim_task(conn, tid) is not None
    return tid


@pytest.fixture
def worker(task_id, monkeypatch):
    """A dispatcher-spawned worker: task, run and claim pinned in the env.

    ``HERMES_DELEGATED_CHILD_CONTEXT`` must be absent: an inherited marker flips
    ``is_dispatcher_owned_worker_context()`` to False, the routing tools' check_fn then
    falls through to the profile opt-in, and the schema looks leaky when it is not.
    """
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc

    with kbc.connect() as conn:
        task = kb.get_task(conn, task_id)
        assert task is not None and task.current_run_id is not None
        run_id = task.current_run_id
    monkeypatch.setenv("HERMES_KANBAN_TASK", task_id)
    monkeypatch.setenv("HERMES_KANBAN_RUN_ID", str(run_id))
    monkeypatch.delenv(DELEGATED_CHILD_ENV_MARKER, raising=False)
    return task_id


@pytest.fixture
def orchestrator(task_id, monkeypatch):
    """The same board, seen by a chat session that routes cards (no task env)."""
    for var in ("HERMES_KANBAN_TASK", "HERMES_KANBAN_RUN_ID", "HERMES_KANBAN_CLAIM_LOCK"):
        monkeypatch.delenv(var, raising=False)
    return task_id


def _kanban_schema_names(selection, disabled=None):
    from model_tools import get_tool_definitions
    from tools.registry import invalidate_check_fn_cache

    invalidate_check_fn_cache()
    return {
        row["function"]["name"]
        for row in get_tool_definitions(selection, disabled_toolsets=disabled, quiet_mode=True,
                                        skip_tool_search_assembly=True)
        if row["function"]["name"].startswith("kanban_")
    }


def test_toolsets_split_board_routing_from_the_worker_surface():
    from toolsets import resolve_toolset

    worker = set(resolve_toolset("kanban", include_registry=False))
    orchestrator = set(resolve_toolset("kanban_orchestrator", include_registry=False))

    assert ROUTING_TOOLS.isdisjoint(worker)
    assert WORKER_TOOLS <= worker
    assert WORKER_TOOLS | ROUTING_TOOLS <= orchestrator
    # The routing tools stay in the shared core bundle on purpose: tool_search never
    # defers a core tool, and the codex-runtime MCP surface only exposes tools present
    # there. The worker boundary is the selection strip plus the env gate, not absence
    # from the bundle.
    assert ROUTING_TOOLS <= set(resolve_toolset("hermes-cli", include_registry=False))


def test_worker_schema_carries_reporting_tools_but_no_board_routing(worker):
    names = _kanban_schema_names(["file", "kanban_orchestrator"])

    assert WORKER_TOOLS <= names, "the worker's reporting path must be unchanged"
    assert ROUTING_TOOLS.isdisjoint(names), f"worker schema leaked {ROUTING_TOOLS & names}"


def test_worker_schema_strips_routing_tools_the_core_bundle_names(worker):
    """A dispatched worker runs the assignee's real cli selection: the core bundle plus
    `kanban_orchestrator` (`_resolve_worker_cli_toolsets`). There the four routing names
    arrive through `hermes-cli`, so only the check_fn removes them — the name-strip above
    never fires. Pin that half too."""
    names = _kanban_schema_names(["hermes-cli", "kanban_orchestrator"])

    assert WORKER_TOOLS <= names, "the worker's reporting path must be unchanged"
    assert ROUTING_TOOLS.isdisjoint(names), f"worker schema leaked {ROUTING_TOOLS & names}"


def test_orchestrator_schema_carries_board_routing(orchestrator):
    names = _kanban_schema_names(["file", "kanban_orchestrator"])

    assert WORKER_TOOLS | ROUTING_TOOLS <= names


def test_disabling_the_worker_toolset_turns_the_whole_workflow_off(home):
    """`kanban` is the subset a user disables; routing reaches the model through the
    core bundle, so the disable must expand to the orchestrator set too."""
    (home / "config.yaml").write_text("toolsets: [kanban]\n")

    assert ROUTING_TOOLS <= _kanban_schema_names(["hermes-cli", "kanban"])
    assert _kanban_schema_names(["hermes-cli", "kanban"], disabled=["kanban"]) == set()


def test_worker_create_and_link_are_refused_and_file_nothing(worker):
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    from tools.registry import registry

    created = json.loads(registry.dispatch(
        "kanban_create", {"title": "self-sustaining chain", "assignee": "split-test"}))
    assert created.get("ok") is not True
    assert "orchestrator-only" in created["error"]
    assert "completion summary" in created["error"]

    linked = json.loads(registry.dispatch(
        "kanban_link", {"parent_id": worker, "child_id": worker}))
    assert linked.get("ok") is not True
    assert "orchestrator-only" in linked["error"]

    with kbc.connect() as conn:
        assert [t.id for t in kb.list_tasks(conn) if t.title == "self-sustaining chain"] == []


def test_orchestrator_create_files_a_card(orchestrator):
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    from tools.registry import registry

    created = json.loads(registry.dispatch(
        "kanban_create", {"title": "orchestrated card", "assignee": "split-test"}))
    assert created["ok"] is True, created

    with kbc.connect() as conn:
        assert kb.get_task(conn, created["task_id"]).title == "orchestrated card"
