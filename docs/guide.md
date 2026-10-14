# claude-agents.nvim guide

Everything the [README](../README.md) leaves out except the agents view, which has [its own guide](agents.md). Every option and its default is in [`lua/claudecode/config.lua`](../lua/claudecode/config.lua), and the terminal's in [`lua/claudecode/terminal.lua`](../lua/claudecode/terminal.lua); this page names the ones worth knowing.

## Commands

```vim
:ClaudeCode [args]              " toggle the Claude terminal; args go to the CLI (--resume, --continue, ...)
:ClaudeCodeFocus                " jump to the terminal, or hide it when you are in it
:ClaudeCodeOpen [args] / :ClaudeCodeClose
:ClaudeCodeSelectModel          " pick a model, then open Claude with it
:'<,'>ClaudeCodeSend            " send the selection to Claude
:ClaudeCodeAdd {file} [from] [to]   " add a file, or some of its lines; % is the current buffer
:ClaudeCodeTreeAdd              " add the file(s) under the cursor in nvim-tree, neo-tree, oil, mini.files or netrw
:ClaudeCodeDiffAccept / :ClaudeCodeDiffDeny
:ClaudeCodeCloseAllDiffs        " close pending diffs; accepted ones are kept
:ClaudeCodeDiffToggleProvider   " native <-> unified, from the next diff on
:ClaudeCodeLiveCursor [preview|open|off]
:ClaudeCodePlanView [on|off]
:ClaudeCodeSessionRestore[!]    " with !, reopen every restored tab's Claude now
:ClaudeCodeStatus               " this tab's server and port; with those features on, conversation id and status
:ClaudeCodeStart / :ClaudeCodeStop   " the integration for the current tab
:ClaudeCodeToggleFileTracking   " stop or resume sending your file and selection
:checkhealth claudecode         " prerequisites, and every running instance's port and clients
```

The agents commands are in the [agents guide](agents.md). The plugin binds `<leader>aF` to `:ClaudeCodeToggleFileTracking` itself, and `<leader>aA` / `<leader>aR` when the agents view or session persistence are on.

## Setup

```lua
opts = {
  terminal_cmd = nil,        -- the claude binary, when it is not on your PATH ("~/.claude/local/claude")
  git_repo_cwd = false,      -- start Claude in the git root of the current file
  focus_after_send = false,  -- jump to the terminal after :ClaudeCodeSend
  log_level = "info",        -- "debug" when something misbehaves
}
```

For a fixed directory, `terminal.cwd = "~/src/app"`; to compute one, `terminal.cwd_provider = function(ctx) ... end`, handed `{ file, file_dir, cwd }`.

## Diffs

Claude's proposed edit opens as a diff. Write it (`:w`) to accept, close it (`:q`) to reject, and change it before writing if you want something slightly different.

`diff_opts.provider` picks how it looks. `"unified"` shows the proposal in one buffer with the changes marked inline, and needs [unified.nvim](https://github.com/papricasix/unified.nvim). `"native"` is a side-by-side vimdiff. `"auto"`, the default, uses unified.nvim when it is installed. `diff_opts.layout` is `"vertical"`, `"horizontal"` or `"float"`; a float needs unified.nvim too, and is sized by the top-level `float` block.

A diff resolved somewhere else, for example from Claude's remote control on your phone, closes when the session that opened it disconnects. While it is still connected, `:ClaudeCodeCloseAllDiffs` clears the leftovers.

An auto-save plugin will accept every diff the moment it opens. Exclude diff buffers in its condition: they are the ones with `buftype` `acwrite`.

```lua
condition = function(buf)
  return vim.bo[buf].buftype ~= "acwrite"
end
```

## Terminal

`terminal.provider` decides where Claude runs:

- `"auto"` (default): [snacks.nvim](https://github.com/folke/snacks.nvim) when installed, otherwise `"native"`.
- `"native"`: a plain `:terminal` split, `terminal.split_side` and `terminal.split_width_percentage` wide.
- `"external"`: another terminal application, with `terminal.provider_opts.external_terminal_cmd = "alacritty -e %s"` (or `"... --working-directory %s -e %s"` for cwd and command, or a function that is handed the claude command and returns the whole command line, as a string or a list).
- `"none"`: nothing is opened. Start `claude` yourself and connect it with `/ide`.
- A table of your own functions; [`lua/claudecode/terminal/native.lua`](../lua/claudecode/terminal/native.lua) shows what it must provide.

With snacks, `terminal.snacks_win_opts` is handed to `Snacks.terminal.open()`, so a floating Claude is:

```lua
terminal = {
  snacks_win_opts = { position = "float", width = 0.9, height = 0.9 },
}
```

## Live cursor

Follows Claude through your files: each file it reads or edits is shown with the lines it touched highlighted, and with unified.nvim an edit shows as a real inline diff. `mode = "preview"` shows them in one split of their own and leaves your windows alone; `"open"` loads them into your editor window instead. It stays out of the way of a file you are reviewing a diff for, and a Claude in another tab never previews in yours.

```lua
live_cursor = { enabled = true, mode = "preview" }
```

## Plan view

When Claude finishes a plan in plan mode, the plan opens as a markdown document in the editor window closest to the terminal. Accepting or rejecting it in the terminal puts that window back the way it was.

```lua
plan = { enabled = true }
```

## Terminal links

On by default. Clicking a file path in Claude's terminal opens it in the editor window next to the terminal, at the line it names; `gf` on a path does the same. Clicks anywhere else go to Claude as before. `terminal_links = { enabled = false }` turns it off, and `click = false` keeps only `gf`.

## Per-tab status

For one Claude per tab: each tab is `busy`, `waiting` (for you: a permission prompt, a question, a plan), `done` (finished, not looked at yet), `idle` or `none`, ready for your tabline.

```lua
status = { enabled = true }

local status = require("claudecode.status")
status.get_state(tab) -- "busy" | "waiting" | "done" | "idle" | "none"
status.icon(tab), status.hl_group(tab) -- the glyph and highlight for that state
```

Every change fires `User ClaudeCodeStatusChanged`. `icons = { busy = status.SPINNER }` animates a working tab with the CLI's own spinner. It costs two hook calls per tool call (before and after), which is why it is off by default.

## Session persistence

Restoring a Neovim session resumes each tab's conversation, the next time you open that tab's Claude. `:ClaudeCodeSessionRestore!` (`<leader>aR`) reopens all of them at once. Conversations you ended yourself stay ended, and a tab whose Claude you never spoke to opens a fresh one.

- `session_persistence = "global"` works with `:mksession`, persistence.nvim and mini.sessions, once `vim.opt.sessionoptions:append("globals")` is set.
- `session_persistence = "external"` leaves storage to your session manager. For resession.nvim: `require("resession").setup({ extensions = { claudecode = {} } })`. For auto-session, return `require("claudecode.session_state").encode()` from `save_extra_data` and hand it back to `.restore(data)` in `restore_extra_data`.

With the agents view, also call `require("claudecode.session_state").prepare_save()` from your session manager's pre-save hook (auto-session's `pre_save_cmds`, resession's `pre_save` hook, persistence.nvim's `User PersistenceSavePre`). Otherwise a view still open when you quit is saved with the session, agents' terminals included, and reopening the session starts them again.

## Troubleshooting

- **Claude does not connect:** `:checkhealth claudecode`, then `:ClaudeCodeStatus`. The lock file it connects through is in `~/.claude/ide/` (or `$CLAUDE_CONFIG_DIR/ide/`).
- **`claude` not found:** set `terminal_cmd` to the path `which claude` prints.
- **Terminal misbehaves with snacks:** try `terminal.provider = "native"`.
- **Anything else:** `log_level = "debug"` and read `:messages`.

## Development

[DEVELOPMENT.md](../DEVELOPMENT.md) covers the toolchain and the tests (`mise run all` before a commit). The [protocol](protocol.md) page documents the WebSocket protocol Claude Code speaks to editors, and [architecture](architecture.md) how the plugin is put together.
