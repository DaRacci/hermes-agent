"""Protected-instruction approval fails closed at once, without asking anyone, where nobody can answer.

``hermes chat -q`` (how kanban spawns every worker), cron and unattended platforms can have the CLI approval
callback registered on the agent thread; a Kanban card attempt also runs as a managed worker that registers a
*gateway* notify callback for its own route. The gate used to ask either surface, block for the full approvals
timeout, then report "timed out" — which reads as a human ignoring a prompt nobody saw. The interactive
approve/deny paths are covered in test_file_write_safety.py; the real CLI modal in
tests/hermes_cli/test_cli_approval_ui.py.
"""

import json

import pytest


@pytest.fixture(autouse=True)
def _gate_on(monkeypatch):
    import tools.file_tools_write_guards as guards
    from tools.terminal_tool import set_approval_callback
    monkeypatch.setattr(guards, "_protected_instruction_config", lambda: (True, []))
    for name in ("HERMES_SINGLE_QUERY_SESSION", "HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM"):
        monkeypatch.delenv(name, raising=False)
    set_approval_callback(None)
    yield
    set_approval_callback(None)


@pytest.mark.parametrize("env", [
    {"HERMES_SINGLE_QUERY_SESSION": "1"},
    {"HERMES_CRON_SESSION": "1"},
    {"HERMES_SESSION_PLATFORM": "webhook"},
], ids=["single_query", "cron", "webhook"])
def test_registered_callback_is_never_asked_without_a_user(tmp_path, monkeypatch, env):
    from tools.terminal_tool import set_approval_callback
    from tools.file_tools import write_file_tool

    for name, value in env.items():
        monkeypatch.setenv(name, value)
    asked = []
    set_approval_callback(lambda command, description, **kw: asked.append(command) or "once")
    target = tmp_path / "SOUL.md"
    res = json.loads(write_file_tool(str(target), "content"))

    assert asked == []
    assert "no interactive user or gateway is present" in res["error"]
    assert "timed out" not in res["error"]
    assert not target.exists()


def test_kanban_worker_gateway_channel_refuses_at_once(tmp_path, monkeypatch):
    """A Kanban card attempt is a finite turn whose managed worker registers a gateway notify callback for
    its own route (agent/managed_worker.py). That callback writes to the owner's pipe; it is not a human.
    The gate must refuse on the headless fact instead of parking the request until ``approvals.timeout``."""
    import time

    import tools.approval as A
    from gateway.session_finite import finite_turn_scope
    from tools import approval_context
    from tools.file_tools import write_file_tool

    # A prompt nobody answers blocks for this long; a regression then fails in seconds, not minutes.
    monkeypatch.setattr(approval_context, "_get_approval_timeout", lambda: 3)
    session_key = "kanban-headless-protected-write"
    published = []
    token = approval_context.set_current_session_key(session_key)
    A.register_gateway_notify(session_key, published.append)
    target = tmp_path / "AGENTS.md"
    try:
        with finite_turn_scope(True):
            started = time.monotonic()
            res = json.loads(write_file_tool(str(target), "content"))
            elapsed = time.monotonic() - started
    finally:
        A.unregister_gateway_notify(session_key)
        approval_context.reset_current_session_key(token)

    assert published == []
    assert "no interactive user or gateway is present" in res["error"]
    assert "timed out" not in res["error"]
    assert elapsed < 2
    assert not target.exists()


def test_answerable_gateway_client_keeps_its_prompt(tmp_path, monkeypatch):
    """The headless refusal is keyed on who can answer, not on callback presence: an ``api_server`` turn
    registers a notify callback only when its client can resolve ``/approve``, so the prompt must survive."""
    import tools.approval as A
    from tools import approval_context
    from tools.file_tools import write_file_tool

    monkeypatch.setenv("HERMES_SESSION_PLATFORM", "api_server")
    session_key = "api-server-protected-write"
    prompts = []
    token = approval_context.set_current_session_key(session_key)

    def notify(approval_data):
        prompts.append(approval_data["command"])
        A.resolve_gateway_approval(session_key, "once")

    A.register_gateway_notify(session_key, notify)
    target = tmp_path / "CLAUDE.md"
    try:
        res = json.loads(write_file_tool(str(target), "content"))
    finally:
        A.unregister_gateway_notify(session_key)
        approval_context.reset_current_session_key(token)

    assert prompts == ["<write to CLAUDE.md>"]
    assert not res.get("error"), res
    assert target.read_text(encoding="utf-8") == "content"


@pytest.mark.parametrize("mode", ["approve", "deny"])
def test_single_query_mode_never_auto_approves_this_gate(tmp_path, monkeypatch, mode):
    """``approvals.single_query_mode`` governs the dangerous-command gate only: a protected-instruction write
    always needs a live human."""
    from tools import approval_context
    from tools.file_tools import write_file_tool
    from tools.terminal_tool import set_approval_callback

    monkeypatch.setenv("HERMES_SINGLE_QUERY_SESSION", "1")
    monkeypatch.setattr(approval_context, "_get_single_query_approval_mode", lambda: mode)
    asked = []
    set_approval_callback(lambda command, description, **kw: asked.append(command) or "once")
    target = tmp_path / "SOUL.md"
    res = json.loads(write_file_tool(str(target), "content"))

    assert asked == []
    assert "BLOCKED" in res["error"]
    assert not target.exists()
