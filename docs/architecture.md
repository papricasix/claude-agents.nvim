# Architecture

The map of the plugin, for reading the code. The repository is claude-agents.nvim; the Lua module is still `claudecode`, and every path below is under `lua/claudecode/` unless it says otherwise. [CLAUDE.md](../CLAUDE.md) has the reasoning and the measurements behind each piece.

## Three channels

Claude Code reaches Neovim three ways, and every feature rides one or more of them.

```text
claude (CLI)
 ├── WebSocket + MCP ─────▶ server/ ─▶ tools/ ─▶ diff.lua, open_file, ...
 │   ◀── selection_changed, at_mentioned
 ├── hooks ───────────────▶ scripts/live_cursor_hook.lua ── RPC ──▶ live_cursor.dispatch
 └── transcripts (.jsonl) ◀── agents/transcript.lua ──▶ agents_view
```

- **The IDE protocol**: the WebSocket and MCP protocol the VS Code extension speaks. Claude calls tools in Neovim, and Neovim tells Claude what you have selected. This is the core the fork inherited from upstream.
- **Hooks**: the protocol carries editor actions only, never what Claude is doing. Features that need to know inject Claude Code hooks when they launch Claude.
- **Transcripts**: what a conversation did, including one that ran outside Neovim, is read from the CLI's own store on disk.

## The core

- **Server** (`server/`): a WebSocket server in pure `vim.loop`, RFC 6455. `tcp.lua` listens on 127.0.0.1 only, `handshake.lua` upgrades the connection and checks the token in `x-claude-code-ide-authorization`, `frame.lua` parses frames, `client.lua` tracks connections, and `utils.lua` has SHA-1 and base64 in Lua. `server/init.lua` dispatches JSON-RPC to the tools.
- **Lock files** (`lockfile.lua`): each server writes `~/.claude/ide/<port>.lock` (`$CLAUDE_CONFIG_DIR/ide/` when set) with its token and workspace folders. A Claude the plugin launches is told the port through `CLAUDE_CODE_SSE_PORT` and reads the token from the lock; one started elsewhere finds Neovim through it with `/ide`. Locks left by a crashed Neovim are swept at setup.
- **MCP tools** (`tools/`): one file per tool, registered in `tools/init.lua`. A tool without a schema (`close_tab`) is internal and never offered to Claude. Each answers `{ content = { { type = "text", text = <JSON> } } }`.
- **Selection** (`selection.lua`): sends `selection_changed`, debounced, as you move. `:ClaudeCodeSend`, `:ClaudeCodeAdd` and `:ClaudeCodeTreeAdd` send `at_mentioned`; `integrations.lua` reads the files under the cursor in a file explorer.
- **Diffs** (`diff.lua`): `openDiff` holds the tool call open (its handler runs in a coroutine) until you write the proposal (`FILE_SAVED`) or close it (`DIFF_REJECTED`). The native provider is a vimdiff across two windows, the unified provider one buffer with inline marks from unified.nvim; `diff_opts.provider = "auto"` picks unified when it loads.
- **Terminal** (`terminal.lua`, `terminal/`): builds the `claude` command and its environment (the port, the hook settings, the session flags) and hands it to a provider: `snacks.lua`, `native.lua`, `external.lua` or `none.lua`. A provider holds one terminal per tabpage.

`init.lua` holds setup, the commands and the instance registry, and `config.lua` every default and the validation of your options.

## Instances

Every Claude gets a server of its own, with its own port, token and lock file. A tab's own Claude is registered as `tab:<tabpage>`; in agents mode each agent is `agent:<session id>` (`start_agent_instance`). `require("claudecode").instances` holds them by id, and `tab_instance` points from a tabpage to its own one.

Before the server dispatches a message it records who sent it in `request_context.lua`, and tool handlers read that (`request_context.tab()`, `.session_id()`) to decide where a diff or a file belongs. That is how one agent's `closeAllDiffTabs` leaves a sibling's pending diff alone. The value is per message, so a handler that yields reads it first.

## The hook side channel

`live_cursor.build_launch_injection` writes a settings file and adds `--settings <file>` to the launch command, leaving your own settings untouched. It registers only the events the enabled features need.

The hook command is Neovim's own binary (`vim.v.progpath`) running `scripts/live_cursor_hook.lua` with `--headless -u NONE -l`, so no shell tools are involved and Windows behaves like everything else. The script reads the event JSON from stdin, connects to the running Neovim's RPC socket (`CLAUDECODE_NVIM_SERVER`, set at launch) and calls `live_cursor.ingest`, stamped with the tab Claude was launched in (`CLAUDECODE_NVIM_TAB`) and, for an agent, its launch (`CLAUDECODE_AGENT_ID`). `live_cursor.dispatch` then hands the event to each consumer:

| Module              | Feature             | What it takes from the hooks                                                                                    |
| ------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `status.lua`        | Per-tab status      | Every lifecycle event, folded into busy, waiting, done, idle                                                    |
| `agents_view.lua`   | Agents              | Live state when `agents.source` resolves to hooks; `SessionStart` always, since `/clear` swaps the conversation |
| `session_state.lua` | Session persistence | The conversation id each event carries, correcting the `--session-id` it launched with                          |
| `plan_view.lua`     | Plan view           | `ExitPlanMode`                                                                                                  |
| `live_cursor.lua`   | Live cursor         | `PreToolUse` for the file tools                                                                                 |

The plan view and the live cursor open windows, so they stand down for an event from an agent. Every hook event starts a headless Neovim, which is why these features are opt-in, and they only work for a Claude the plugin launched. An interrupted turn fires no hook at all, so `interrupt_watch.lua` tails the transcript for the CLI's interrupt marker instead.

## The agents view

`agents_view.lua` owns the tab: the layout, the keys and the redraw loop. Its source of truth is the CLI's transcript store, `~/.claude/projects/<slug>/<id>.jsonl`, where the slug is the project directory with every non-alphanumeric character turned into `-` (long paths are cut and hashed). Counts, titles, activity and subagents all come from there, which is why conversations from other editors show up and nothing is lost on a restart. Live updates come from polling each transcript's mtime (`agents.poll_ms`) or from the hooks above.

Agents run in `agents/registry.lua`, not in the terminal providers: one terminal buffer per agent, hidden rather than closed, so switching is a buffer swap and the agent you leave keeps working.

| `agents/`                                                            | What it does                                                                    |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `transcript.lua`                                                     | Finds and folds transcripts, reading only what was appended since the last fold |
| `model.lua`                                                          | The view-model: rows, selection, order, per-conversation state, no window API   |
| `render.lua`, `fade.lua`                                             | Painting the panes, and the colours derived from your theme                     |
| `registry.lua`                                                       | The agents' terminals, keyed by conversation                                    |
| `subagents.lua`                                                      | The Tasks pane: subagents, background shells, monitors, workflow runs           |
| `file_view.lua`, `patch.lua`                                         | A file as the session left it, rebuilt from the transcript's hunks              |
| `tool_view.lua`, `tools.lua`, `ansi.lua`                             | A tool call and its output, per-tool labels, terminal colours as extmarks       |
| `subagent_view.lua`, `shell_view.lua`, `workflow_view.lua`           | Floats for a subagent's transcript, a shell's output, a workflow run            |
| `git.lua`                                                            | Status letters, and the `HEAD` (svn `BASE`) baseline for `.`                    |
| `search.lua`                                                         | The `gf` search over conversations                                              |
| `checkpoints.lua`, `flags.lua`                                       | Checkpoints and flags, stored under `stdpath("cache")`                          |
| `float.lua`, `confirm.lua`, `input.lua`, `help.lua`, `sort_menu.lua` | The small windows                                                               |

## Floats and window routing

Every "where does this file go" question is answered by `diff.resolve_target_window`: the editor window closest to the Claude terminal, else the main editor window. A tab can declare `t:claudecode_layout_owner` to forbid splits; the agents tab does, so a diff or a file from an agent lands in a float.

A window that is not for editing (the live cursor's preview, the plan view's host, every agents pane, every float) carries the window variable `claudecode_live_preview` and is never picked as a target.

`float.lua` draws the cascading floats: newest on top, titled with the path, one stack shared by agent floats and `diff_opts.layout = "float"`. `agents/float.lua` wraps it with the agents geometry and the agent's name.

## Everything else

- `terminal_links.lua`: file paths in Claude's terminal open in Neovim, from the OSC 8 links Claude prints (a `TermRequest` autocmd, no hooks).
- `health.lua`: `:checkhealth claudecode`.
- `utils.lua`, `logger.lua`, `cwd.lua`, `visual_commands.lua`, `types.lua`: helpers and type definitions.
- `plugin/claudecode.lua`: the version guard and the optional `vim.g.claudecode_auto_setup`; the commands are created by `setup()`.
- `lua/resession/extensions/claudecode.lua`: the resession.nvim extension for session persistence.

## Where to look next

- [CLAUDE.md](../CLAUDE.md): the deep reference, every rule and why it holds.
- [protocol.md](protocol.md): the wire protocol Claude Code speaks to editors.
- [DEVELOPMENT.md](../DEVELOPMENT.md): the toolchain and the tests (`mise run all` before a commit).
