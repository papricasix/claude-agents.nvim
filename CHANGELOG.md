# Changelog

## [Unreleased]

### Added

- OpenCode as the agent instead of Claude Code, or next to it. `backend = "opencode"` makes plain launches run [OpenCode](https://opencode.ai) (2.0 or newer); a launch profile with `backend = "opencode"` (with an optional `provider/model` and agent) runs it for the launches you pick it for, and a built-in `OpenCode` profile is offered when it is installed. The terminal, your selection and `:ClaudeCodeSend`/`Add`/`TreeAdd`, per-tab status, the live cursor, session persistence and the agents view work with it; its edits open as diffs you accept with `:w` and reject with `:q` (`opencode.review_edits`, on by default, never lets an agent edit where its own rules refuse), and the plan view shows the plans its plan agent writes. The agents view lists Claude's and OpenCode's conversations together, OpenCode's marked `◇`, and resumes each in the CLI that holds it. A busy OpenCode tab or agent shows OpenCode's own spinner (`status.opencode_icons` to change it). `:ClaudeCodeSelectModel` picks from OpenCode's models for an OpenCode tab. In the agents view, where `<C-p>` switches sessions, an OpenCode agent's command palette is `ctrl+x p` (`opencode.agent_keybinds`). `:checkhealth` reports OpenCode and its background service. See the [guide](docs/guide.md#opencode) for what differs.
- `command_aliases = true` also names every command without `ClaudeCode`: `:Agent`, `:AgentSend`, `:Agents`, `:AgentNew`, and so on.
- A diff says who wants the change and how to answer it (`:w accept · :q reject`) at the top of the proposal, or in a float's border, and an agent's diff that opens in another tab is announced with the tab it is in.

### Fixed

- Answering an agent's diff left its terminal in normal mode, so the next keys meant for the agent failed with `E21: Cannot make changes`. Focus now goes back to the terminal you were typing in, in insert mode, and from the tab where you answered an agent's diff back to the agent.
- A connection to the editor that was refused printed `handle … is already closing` errors.
- `agents.resume_mode = "fork"` started a brand new conversation, with the session id typed in as its first message, instead of a copy of the session: `--fork-session` was passed without the `--resume` it belongs to.

## [1.2.1] - 2026-10-16

### Fixed

- A subagent that is waiting for a background command of its own to finish is shown as running in Tasks, not as done while its command is still going.
- `<C-\><C-n>` leaves an agent's terminal again. The agents view's `<C-n>` (next session) took its second key, so you stayed in terminal mode.
- `<Tab>` moves on to the next pane from an agent's terminal too, once you are out of terminal mode, as the help says it does anywhere in the view.

### Changed

- The README leads with the agents view and shows its Tasks pane live: subagents, a background build and a monitor followed as they work. The editor's live cursor and `:w` clips are now one.

## [1.2.0] - 2026-10-15

### Added

- Launch profiles: start each Claude on your subscription or on an API key. `:ClaudeCodeProfile` picks one for a tab's Claude, and `ga`/`gi` in the agents view start or resume a session under one. A running Claude switches by restarting with its conversation carried on, and a resumed conversation goes back to the profile it last ran under. The key stays in the OS keychain (macOS Keychain, Secret Service on Linux, Credential Manager on Windows) and Claude Code fetches it itself, so it is never in your config, Neovim's environment or the environment of the commands Claude runs. `:checkhealth` says whether it is stored. Sessions run on an API key are marked `$`. Reading the key from Windows' Credential Manager has not been tested on Windows yet.

### Fixed

- A `--settings` of your own in `terminal_cmd` or `:ClaudeCode` arguments was dropped on every launch: the plugin's hook settings were passed as a second `--settings`, which replaces the first. They are merged into one now.
- A Claude started with `:ClaudeCode` or `:ClaudeCodeFocus` was not recognised as the tab's: closing it did not forget its conversation for session persistence, and status showed nothing until its first hook.
- A turn that ended in an API error (a rate limit, no credit, a rejected key) left the tab and the agent shown as busy for good.

## [1.1.2] - 2026-10-15

### Fixed

- Claude Code 2.1.300 writes a record of each API request into the conversation's transcript, and the agents view read those as part of the conversation: every tool call appeared twice in Activity, the copy without a time (`--:--`) and marked as running for ever. They are skipped now.
- Subagents run in print mode (`claude -p`, the SDK) are read correctly: their calls finish, their background shells and monitors appear in Tasks, and their results no longer count as something the user typed.
- A call refused by a permission rule or by auto mode is drawn as declined (`⊘`), like one you turned down, not as a failure.
- Subagents are listed in Tasks in the order they were started, and two agents started one after the other no longer swap places in Sessions.
- With `status` off, an agent's bullet no longer stays on busy for good.
- An edit shows in the counts, Activity and Changes as soon as its tool finishes, also while the CLI holds back writing it or the agent waits on a permission prompt.
- The panes repaint when Neovim or a window is resized, and in a narrow pane a row's text is cut rather than pushing its time, counts or status mark past the edge.
- `getCurrentSelection` names a review diff's proposal by the file it changes, also before anything has been selected.

### Changed

- The README's demo clips are recorded in a small Rust project.

## [1.1.1] - 2026-10-15

### Fixed

- Claude's hooks never reached Neovim since 1.0.0: the module rename left the hook script's path pointing inside `live_cursor.lua`, so per-tab status, the agents view's state and spinners, the live cursor and the plan view received nothing.

## [1.1.0] - 2026-10-15

### Changed

- The plan view (`plan`) and per-tab status (`status`) are on by default. Per-tab status runs a short hook before and after every tool call; `status = { enabled = false }` and `plan = { enabled = false }` switch them off. With status on, the agents view follows its agents through those hooks instead of polling their transcripts.
- The README's install snippet lists every optional feature, commented out, so turning one on or off is a matter of uncommenting a line.

## [1.0.0] - 2026-10-15

The first release of claude-agents.nvim, a fork of [claudecode.nvim](https://github.com/coder/claudecode.nvim) 0.3.0. The commands and the options are unchanged: point the plugin spec at `papricasix/claude-agents.nvim` and keep the rest.

### Added

- **Agents view** (`agents = { enabled = true }`, `<leader>aA`, `:ClaudeCodeAgents`): several Claudes on one project in one tab, each with its own connection to Neovim, so a diff or a file reaches the agent that asked. Every conversation the project has had, read from Claude Code's own transcripts, with what it changed (Changes), everything it did (Activity) and the subagents, background shells, monitors and workflow runs it started (Tasks). `<CR>` opens an edit, a file as the session changed it, a command's output or a subagent's transcript; `.` diffs against git `HEAD` or svn `BASE`. Search across conversations, checkpoints, flags, numbered follow-ups, git worktrees and rewinds. See [docs/agents.md](docs/agents.md).
- **Live cursor** (`live_cursor`): follows Claude through the files it reads and edits, showing each edit as an inline diff.
- **Plan view** (`plan`): plan mode's plan opens as a document in the editor.
- **Terminal links**, on by default: file paths in Claude's terminal open in Neovim when clicked, or with `gf`.
- **Per-tab status** (`status`): busy, waiting, done or idle for each tab's Claude, for tablines, with the CLI's own spinner and a `User ClaudeCodeStatusChanged` event.
- **Session persistence** (`session_persistence`): restoring a Neovim session resumes each tab's conversation; works with `:mksession`, persistence.nvim, mini.sessions, auto-session and resession.
- **Inline diffs** with [unified.nvim](https://github.com/papricasix/unified.nvim) (`diff_opts.provider`, `:ClaudeCodeDiffToggleProvider`), and diffs in a floating window (`diff_opts.layout = "float"`).
- `:checkhealth claude_agents`: the prerequisites, and every running instance with its port, lock file and clients.
- `:ClaudeCodeToggleFileTracking` (`<leader>aF`) stops or resumes sending your file and selection.
- Claude Fable in the model picker.

### Changed

- The Lua module is `claude_agents` (`require("claude_agents")`), so lazy.nvim finds it from the plugin's name. `require("claudecode")` and `require("claudecode.<module>")` still work and return the same modules, with a one-time warning to rename them. Commands, highlight groups, events and options keep their `ClaudeCode` names.
- Neovim 0.10 or newer is required (clickable terminal links need 0.11).
- Diffs open next to the Claude terminal, in the tab that owns it, and give the window back when they close. An accepted diff stays on screen until Claude has written the file, so the old text never flashes back.
- The MCP tools answer in the shapes the VS Code extension sends (`getDiagnostics` with LSP ranges and severity names), and a diff's proposal buffer is reported to Claude as the file it changes.
- Launch hooks run through Neovim's own binary, so they need no `nvim` on `PATH` and behave the same on macOS, Linux and native Windows.

### Fixed

- `openFile` opened files in whichever tab came first; it now uses the requesting Claude's tab. `closeAllDiffTabs` from one Claude no longer closes another Claude's pending diff.
- `terminal.cwd` and `cwd_provider` were ignored.
- A `$` in a path added with `:ClaudeCodeAdd` was expanded as an environment variable.
- Starting failed when another editor held the chosen port; lock files left by crashed editors are now swept.
- Windows: hook quoting, CRLF files in diffs, `file://` links, finding a project's conversations, and the spinner drawn with the emoji font.

### Removed

- The AI release-notes workflow and its configuration (`.github/workflows/release-notes.yaml`, `communique.toml`); release notes are written by hand.

### From upstream claudecode.nvim, after 0.3.0

By [Coder](https://github.com/coder/claudecode.nvim) and its contributors, merged into this fork:

- `:ClaudeCodeCloseAllDiffs`, and pending diffs closed when the Claude that opened them disconnects ([#248](https://github.com/coder/claudecode.nvim/issues/248))
- Diffs open when the Claude terminal is the only window ([#231](https://github.com/coder/claudecode.nvim/issues/231))
- `terminal.fix_streamed_paste`, a workaround for Neovim < 0.12.2 truncating large pastes into the terminal ([#161](https://github.com/coder/claudecode.nvim/issues/161))
- Auth tokens from the OS random source, lock files readable only by you, malformed WebSocket frames closing the connection, the Snacks Explorer excluded from editor windows, and a modernised model picker

---

Releases before 1.0.0 are upstream claudecode.nvim's own.

## [0.3.0] - 2025-09-15

### Features

- External terminal provider to run Claude in a separate terminal ([#102](https://github.com/coder/claudecode.nvim/pull/102))
- Terminal provider APIs: implement `ensure_visible` for reliability ([#103](https://github.com/coder/claudecode.nvim/pull/103))
- Working directory control for Claude terminal ([#117](https://github.com/coder/claudecode.nvim/pull/117))
- Support function values for `external_terminal_cmd` for dynamic commands ([#119](https://github.com/coder/claudecode.nvim/pull/119))
- Add `"none"` terminal provider option for external CLI management ([#130](https://github.com/coder/claudecode.nvim/pull/130))
- Shift+Enter keybinding for newline in terminal input ([#116](https://github.com/coder/claudecode.nvim/pull/116))
- `focus_after_send` option to control focus after sending to Claude ([#118](https://github.com/coder/claudecode.nvim/pull/118))
- Snacks: `snacks_win_opts` to override `Snacks.terminal.open()` options ([#65](https://github.com/coder/claudecode.nvim/pull/65))
- Terminal/external quality: CWD support, stricter placeholder parsing, and `jobstart` CWD (commit e21a837)

- Diff UX redesign with horizontal layout and new tab options ([#111](https://github.com/coder/claudecode.nvim/pull/111))
- Prevent diff on dirty buffers ([#104](https://github.com/coder/claudecode.nvim/pull/104))
- `keep_terminal_focus` option for diff views ([#95](https://github.com/coder/claudecode.nvim/pull/95))
- Control behavior when rejecting “new file” diffs ([#114](https://github.com/coder/claudecode.nvim/pull/114))

- Add Claude Haiku model + updated type annotations ([#110](https://github.com/coder/claudecode.nvim/pull/110))
- `CLAUDE_CONFIG_DIR` environment variable support ([#58](https://github.com/coder/claudecode.nvim/pull/58))
- `PartialClaudeCodeConfig` type for safer partial configs ([#115](https://github.com/coder/claudecode.nvim/pull/115))
- Generalize format hook; add floating window docs (commit 7e894e9)
- Add env configuration option; fix `vim.notify` scheduling ([#21](https://github.com/coder/claudecode.nvim/pull/21))

- WebSocket authentication (UUID tokens) for the server ([#56](https://github.com/coder/claudecode.nvim/pull/56))
- MCP tools compliance aligned with VS Code specs ([#57](https://github.com/coder/claudecode.nvim/pull/57))

- Mini.files integration and follow-up touch-ups ([#89](https://github.com/coder/claudecode.nvim/pull/89), [#98](https://github.com/coder/claudecode.nvim/pull/98))

### Bug Fixes

- Wrap ERROR/WARN logging in `vim.schedule` to avoid fast-event context errors ([#54](https://github.com/coder/claudecode.nvim/pull/54))
- Native terminal: do not wipe Claude buffer on window close ([#60](https://github.com/coder/claudecode.nvim/pull/60))
- Native terminal: respect `auto_close` behavior ([#63](https://github.com/coder/claudecode.nvim/pull/63))
- Snacks integration: fix invalid window with `:ClaudeCodeFocus` ([#64](https://github.com/coder/claudecode.nvim/pull/64))
- Debounce update on selection for stability ([#92](https://github.com/coder/claudecode.nvim/pull/92))

### Documentation

- Update PROTOCOL.md with complete VS Code tool specs; streamline README ([#55](https://github.com/coder/claudecode.nvim/pull/55))
- Convert configuration examples to collapsible sections; add community extensions ([#93](https://github.com/coder/claudecode.nvim/pull/93))
- Local and native binary installation guide ([#94](https://github.com/coder/claudecode.nvim/pull/94))
- Auto-save plugin note and fix ([#106](https://github.com/coder/claudecode.nvim/pull/106))
- Add AGENTS.md and improve config validation notes (commit 3e2601f)

### Refactors & Development

- Centralize type definitions in dedicated `types.lua` module ([#108](https://github.com/coder/claudecode.nvim/pull/108))
- Devcontainer with Nix support; follow-up simplification ([#112](https://github.com/coder/claudecode.nvim/pull/112), [#113](https://github.com/coder/claudecode.nvim/pull/113))
- Add Neovim test fixture configs and helper scripts (commit 35bb60f)
- Update Nix dependencies and documentation formatting (commit a01b9dc)
- Debounce/Claude hooks refactor (commit e08921f)

### New Contributors

- @alvarosevilla95 — first contribution in [#60](https://github.com/coder/claudecode.nvim/pull/60)
- @qw457812 — first contribution in [#64](https://github.com/coder/claudecode.nvim/pull/64)
- @jdurand — first contribution in [#89](https://github.com/coder/claudecode.nvim/pull/89)
- @marcinjahn — first contribution in [#102](https://github.com/coder/claudecode.nvim/pull/102)
- @proofer — first contribution in [#98](https://github.com/coder/claudecode.nvim/pull/98)
- @ehaynes99 — first contribution in [#106](https://github.com/coder/claudecode.nvim/pull/106)
- @rpbaptist — first contribution in [#92](https://github.com/coder/claudecode.nvim/pull/92)
- @nerdo — first contribution in [#78](https://github.com/coder/claudecode.nvim/pull/78)
- @totalolage — first contribution in [#21](https://github.com/coder/claudecode.nvim/pull/21)
- @TheLazyLemur — first contribution in [#18](https://github.com/coder/claudecode.nvim/pull/18)
- @nabekou29 — first contribution in [#58](https://github.com/coder/claudecode.nvim/pull/58)

### Full Changelog

- <https://github.com/coder/claudecode.nvim/compare/v0.2.0...v0.3.0>

## [0.2.0] - 2025-06-18

### Features

- **Diagnostics Integration**: Added comprehensive diagnostics tool that provides Claude with access to LSP diagnostics information ([#34](https://github.com/coder/claudecode.nvim/pull/34))
- **File Explorer Integration**: Added support for oil.nvim, nvim-tree, and neotree with @-mention file selection capabilities ([#27](https://github.com/coder/claudecode.nvim/pull/27), [#22](https://github.com/coder/claudecode.nvim/pull/22))
- **Enhanced Terminal Management**:
  - Added `ClaudeCodeFocus` command for smart toggle behavior ([#40](https://github.com/coder/claudecode.nvim/pull/40))
  - Implemented auto terminal provider detection ([#36](https://github.com/coder/claudecode.nvim/pull/36))
  - Added configurable auto-close and enhanced terminal architecture ([#31](https://github.com/coder/claudecode.nvim/pull/31))
- **Customizable Diff Keymaps**: Made diff keymaps adjustable via LazyVim spec ([#47](https://github.com/coder/claudecode.nvim/pull/47))

### Bug Fixes

- **Terminal Focus**: Fixed terminal focus error when buffer is hidden ([#43](https://github.com/coder/claudecode.nvim/pull/43))
- **Diff Acceptance**: Improved unified diff acceptance behavior using signal-based approach instead of direct file writes ([#41](https://github.com/coder/claudecode.nvim/pull/41))
- **Syntax Highlighting**: Fixed missing syntax highlighting in proposed diff view ([#32](https://github.com/coder/claudecode.nvim/pull/32))
- **Visual Selection**: Fixed visual selection range handling for `:'\<,'\>ClaudeCodeSend` ([#26](https://github.com/coder/claudecode.nvim/pull/26))
- **Native Terminal**: Implemented `bufhidden=hide` for native terminal toggle ([#39](https://github.com/coder/claudecode.nvim/pull/39))

### Development Improvements

- **Testing Infrastructure**: Moved test runner from shell script to Makefile for better development experience ([#37](https://github.com/coder/claudecode.nvim/pull/37))
- **CI/CD**: Added Claude Code GitHub Workflow ([#2](https://github.com/coder/claudecode.nvim/pull/2))

## [0.1.0] - 2025-06-02

### Initial Release

First public release of claudecode.nvim - the first Neovim IDE integration for
Claude Code.

#### Features

- Pure Lua WebSocket server (RFC 6455 compliant) with zero dependencies
- Full MCP (Model Context Protocol) implementation compatible with official extensions
- Interactive terminal integration for Claude Code CLI
- Real-time selection tracking and context sharing
- Native Neovim diff support for code changes
- Visual selection sending with `:ClaudeCodeSend` command
- Automatic server lifecycle management

#### Commands

- `:ClaudeCode` - Toggle Claude terminal
- `:ClaudeCodeSend` - Send visual selection to Claude
- `:ClaudeCodeOpen` - Open/focus Claude terminal
- `:ClaudeCodeClose` - Close Claude terminal

#### Requirements

- Neovim >= 0.8.0
- Claude Code CLI
