"""Worker provenance is not a dependency edge or a transient runtime session."""
import json

import pytest

from hermes_state import SessionDB


def test_worker_create_is_refused_so_no_child_inherits_the_owner_channel(tmp_path, monkeypatch):
    """Fan-out is the orchestrator's call. A dispatcher-spawned worker reports the
    follow-up instead of filing it, so there is no worker-created child to inherit the
    owner card's durable session origin or its notify subscription."""
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc, kanban_db_notify as kn
    from tools import kanban_tools as kt

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    kb.init_db()
    with kbc.connect_closing() as conn:
        owner = kb.create_task(conn, title="owner", session_id="durable")
        kn.add_notify_sub(conn, task_id=owner, platform="discord", chat_id="chat",
                          user_id="user", notifier_profile="default", delivery_mode="notify",
                          delivery_metadata={"scope_id": "guild", "parent_chat_id": "forum"})
    monkeypatch.setenv("HERMES_KANBAN_TASK", owner)
    monkeypatch.setenv("HERMES_SESSION_ID", "ephemeral")

    result = json.loads(kt._handle_create({"title": "child", "assignee": "default"}))

    assert result.get("ok") is not True, result
    assert "orchestrator-only" in result["error"]
    with kbc.connect_closing() as conn:
        assert conn.execute("SELECT COUNT(*) FROM tasks").fetchone()[0] == 1
        assert kn.list_notify_subs(conn, owner)


def test_tool_subscription_captures_conversation_anchors(tmp_path, monkeypatch):
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc, kanban_db_notify as kn
    from tools import kanban_tools as kt
    from gateway.session_context import set_session_vars, clear_session_vars

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    kb.init_db()
    tokens = set_session_vars(platform="discord", chat_id="thread", chat_type="thread",
                             scope_id="guild", parent_chat_id="forum", profile="default")
    try:
        result = json.loads(kt._handle_create(dict(title="direct", assignee="default")))
    finally:
        clear_session_vars(tokens)
    assert result["ok"], result
    with kbc.connect_closing() as conn:
        metadata = kn.list_notify_subs(conn, result["task_id"])[0]["delivery_metadata"]
        assert metadata["scope_id"] == "guild"
        assert metadata["parent_chat_id"] == "forum"


@pytest.mark.parametrize(("session_id", "persisted"), [
    ("phantom-session", False),
    ("persisted-session", True),
])
def test_tool_create_only_stamps_persisted_ambient_session(tmp_path, monkeypatch, session_id, persisted):
    """Ambient worker ids are provenance only after their state.db row exists."""
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
    from tools import kanban_tools as kt
    from gateway.session_context import scoped_current_session_id

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    kb.init_db()
    state = SessionDB(db_path=tmp_path / "state.db")
    if persisted:
        state.create_session(session_id, source="cli")
    state.close()

    # Bound the way agent construction publishes it (ContextVar); a bare os.environ value is
    # masked once a surface has cleared its session vars, so it is not a stand-in here. The env
    # var is set too so the reporter's unverified-env path (the pre-fix stamping seam) is exercised.
    monkeypatch.setenv("HERMES_SESSION_ID", session_id)
    with scoped_current_session_id(session_id):
        result = json.loads(kt._handle_create({"title": "child", "assignee": "default"}))
    with kbc.connect_closing() as conn:
        task = kb.get_task(conn, result["task_id"])
    assert task.session_id == (session_id if persisted else None)


def test_tool_create_stamps_request_scoped_session_over_process_env(tmp_path, monkeypatch):
    """In a multi-session process os.environ holds the LAST agent built; the request-scoped
    binding names the conversation that actually ordered the card."""
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
    from tools import kanban_tools as kt
    from gateway.session_context import scoped_current_session_id

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    monkeypatch.setenv("HERMES_SESSION_ID", "other-session")
    kb.init_db()
    state = SessionDB(db_path=tmp_path / "state.db")
    for sid in ("other-session", "ordering-session"):
        state.create_session(sid, source="cli")
    state.close()

    with scoped_current_session_id("ordering-session"):
        result = json.loads(kt._handle_create({"title": "child", "assignee": "default"}))
    with kbc.connect_closing() as conn:
        assert kb.get_task(conn, result["task_id"]).session_id == "ordering-session"
