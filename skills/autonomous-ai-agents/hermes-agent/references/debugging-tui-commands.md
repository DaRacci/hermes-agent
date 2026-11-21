# Debugging Hermes TUI Slash Commands

## Overview

Hermes slash commands span three layers — Python command registry, tui_gateway JSON-RPC bridge, and the Ink/TypeScript frontend. When a command misbehaves (missing from autocomplete, works in CLI but not TUI, config persists but UI doesn't update), the bug is almost always one layer being out of sync with another.

## Architecture

```
Python backend (hermes_cli/commands.py)     <- canonical COMMAND_REGISTRY
       │
       ▼
TUI gateway (tui_gateway/server.py)         <- slash.exec / command.dispatch
       │
       ▼
TUI frontend (ui-tui/src/app/slash/)        <- local handlers + fallthrough
```

Command definitions must be registered consistently across Python and TypeScript to work properly. The Python `COMMAND_REGISTRY` is the source of truth for: CLI dispatch, gateway help, Telegram BotCommand menu, Slack subcommand map, and autocomplete data shipped to Ink.

## Investigation Steps

1. **Check if the command exists in the TUI frontend:**
   ```bash
   search_files --pattern "/commandname" --file_glob "*.ts" --path ui-tui/
   search_files --pattern "/commandname" --file_glob "*.tsx" --path ui-tui/
   ```

2. **Examine the TUI command definition:**
   ```bash
   read_file ui-tui/src/app/slash/commands/core.ts
   search_files --pattern "commandname" --path ui-tui/src/app/slash/commands --target files
   ```

3. **Check if the command exists in the Python backend:**
   ```bash
   search_files --pattern "CommandDef" --file_glob "*.py" --path hermes_cli/
   search_files --pattern "commandname" --path hermes_cli/commands.py --context 3
   ```

4. **Examine the gateway implementation:**
   ```bash
   search_files --pattern "complete.slash|slash.exec" --path tui_gateway/
   ```

## Fix: Missing Command Autocomplete

1. Add a `CommandDef` entry to `COMMAND_REGISTRY` in `hermes_cli/commands.py`:
   ```python
   CommandDef("commandname", "Description of the command", "Session",
              cli_only=True, aliases=("alias",),
              args_hint="[arg1|arg2|arg3]",
              subcommands=("arg1", "arg2", "arg3")),
   ```

2. Pick `cli_only` vs gateway availability carefully:
   - `cli_only=True` — only in the interactive CLI/TUI
   - `gateway_only=True` — only in messaging platforms
   - neither — available everywhere

3. Ensure `subcommands` matches the expected tab-completion options.

4. If the command runs server-side, add a handler in `HermesCLI.process_command()` in `cli.py` (the method body now lives in `hermes_cli/cli_*_mixin.py`).

5. For gateway-available commands, add a handler in `gateway/run.py`.

## Common Issues

1. **Command shows in TUI but not in autocomplete** — The command is defined in the TUI codebase but missing from `COMMAND_REGISTRY`. Autocomplete data ships from Python.

2. **Command shows in autocomplete but doesn't work** — Check the command handler in `tui_gateway/server.py` and the frontend handler in `ui-tui/src/app/createSlashHandler.ts`. Local TUI handlers take precedence over gateway dispatch.

3. **Command persists config but doesn't apply live** — For TUI-local commands, updating `config.set` is not enough. Also patch the relevant nanostore state immediately (usually `patchUiState(...)`) and pass any new state through rendering components.

4. **Gateway dispatch silently ignores the command** — The gateway only dispatches commands in `GATEWAY_KNOWN_COMMANDS` (derived from `COMMAND_REGISTRY`).

## Debugging Tactics

- **Python side hangs:** use the `python-debugpy` skill to break inside `_SlashWorker.exec` or the command handler.
- **Ink side not reacting:** use the `node-inspect-debugger` skill to break in `app.tsx`'s slash dispatch.
- **Registry mismatch:** compare the canonical `COMMAND_REGISTRY` entry against the TUI's local command list side-by-side.

## Verification

After fixing:
1. Rebuild the TUI: `npm --prefix ui-tui run build` (the package script shells out to `scripts/build/tui.mjs`)
2. Run the TUI and test the command
3. Type `/` and verify the command appears in autocomplete with the expected description and args hint
4. Execute the command and confirm expected behavior fires
5. If the command is also gateway-available, test from a messaging platform or run `scripts/run_tests.sh tests/gateway/`

## Pitfalls

- Don't forget to set the appropriate category for the command in `CommandDef` ("Session", "Configuration", "Tools & Skills", "Info", "Exit")
- Make sure any aliases are properly registered in the `aliases` tuple
- `cli_only=True` commands won't work in gateway/messaging platforms
- After adding live UI state, search every consumer of the old prop/helper and thread the new state through all render paths
- Rebuild the TUI before testing — `tsx watch` mode may lag on first launch
