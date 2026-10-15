# claude-agents.nvim guide

Everything the [README](../README.md) leaves out except the agents view, which has [its own guide](agents.md). Every option and its default is in [`lua/claude_agents/config.lua`](../lua/claude_agents/config.lua), and the terminal's in [`lua/claude_agents/terminal.lua`](../lua/claude_agents/terminal.lua); this page names the ones worth knowing.

## Commands

```vim
:ClaudeCode [args]              " toggle the Claude terminal; args go to the CLI (--resume, --continue, ...)
:ClaudeCodeFocus                " jump to the terminal, or hide it when you are in it
:ClaudeCodeOpen [args] / :ClaudeCodeClose
:ClaudeCodeSelectModel          " pick a model, then open Claude with it
:ClaudeCodeProfile [name]       " start this tab's Claude on your subscription or an API key, or switch it
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
:checkhealth claude_agents      " prerequisites, and every running instance's port and clients
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

## Subscription or API key

Each Claude can run on your Claude subscription or on an API key, chosen per launch by a launch profile. Plain launches (`:ClaudeCode`, `a` in the agents view) are left as they are: Claude Code decides, which means your subscription unless an API key is in your environment.

`:ClaudeCodeProfile` opens a menu of profiles for this tab's Claude (`:ClaudeCodeProfile API key` picks one directly). It starts the Claude under that profile, or switches a running one by restarting it with its conversation carried on, asking first when it is busy. In the agents view, `ga` starts a new agent under a profile and `gi` resumes or switches a session. A conversation goes back to the profile it last ran under whenever it is resumed. The plugin binds no key for it; `{ "<leader>ap", "<cmd>ClaudeCodeProfile<cr>" }` is one.

Two profiles exist out of the box, `subscription` and `API key`. The key lives in your OS keychain, not in your config or Neovim's environment, and the plugin never reads it: Claude Code fetches it itself through a helper the plugin hands it, so the commands Claude runs cannot read it either. Store it once, in a terminal; each tool asks for it with hidden input:

- macOS: `security add-generic-password -U -s claudecode.nvim -a default -w`
- Linux: `secret-tool store --label='claudecode.nvim API key (default)' service claudecode.nvim account default`
- Windows: `cmdkey /generic:claudecode.nvim/default /user:claudecode.nvim /pass` (not yet tested on Windows)

`:checkhealth claude_agents` says whether it is there. Create the key in a Console workspace with a monthly spend limit, so a leaked key costs at most that. A key that belongs to the whole organisation rather than one workspace needs `workspace = "wrkspc_…"` on its profile.

```lua
profiles = {
  default = nil, -- what plain launches use: nil leaves them alone, or a profile name
  list = {
    { name = "subscription", key = "s", auth = "subscription" },
    { name = "API key", key = "a", auth = "api", keychain = "default" },
    { name = "API · Opus", key = "o", auth = "api", model = "opus",
      api_key_cmd = "op read op://Private/Anthropic/credential" },
  },
}
```

`keychain` names the entry (the `default` in the commands above). `api_key_cmd` is any command that prints the key. A profile can also carry `args` and `env`. Sessions run on an API key are marked `$` in the agents view, and `require("claude_agents.profiles").of_tab()` names the current tab's profile for a tabline. While a Claude runs on an API key, Claude Code switches off your claude.ai connectors.

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
- A table of your own functions; [`lua/claude_agents/terminal/native.lua`](../lua/claude_agents/terminal/native.lua) shows what it must provide.

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

On by default. When Claude finishes a plan in plan mode, the plan opens as a markdown document in the editor window closest to the terminal. Accepting or rejecting it in the terminal puts that window back the way it was. `plan = { enabled = false }` turns it off.

## Terminal links

On by default. Clicking a file path in Claude's terminal opens it in the editor window next to the terminal, at the line it names; `gf` on a path does the same. Clicks anywhere else go to Claude as before. `terminal_links = { enabled = false }` turns it off, and `click = false` keeps only `gf`.

## Per-tab status

On by default. For one Claude per tab: each tab is `busy`, `waiting` (for you: a permission prompt, a question, a plan), `done` (finished, not looked at yet), `idle` or `none`, ready for your tabline.

```lua
local status = require("claude_agents.status")
status.get_state(tab) -- "busy" | "waiting" | "done" | "idle" | "none"
status.icon(tab), status.hl_group(tab) -- the glyph and highlight for that state
```

Every change fires `User ClaudeCodeStatusChanged`. `icons = { busy = status.SPINNER }` animates a working tab with the CLI's own spinner. It runs two short hook calls per tool call (before and after); `status = { enabled = false }` saves them.

## Session persistence

Restoring a Neovim session resumes each tab's conversation, the next time you open that tab's Claude. `:ClaudeCodeSessionRestore!` (`<leader>aR`) reopens all of them at once. Conversations you ended yourself stay ended, and a tab whose Claude you never spoke to opens a fresh one.

- `session_persistence = "global"` works with `:mksession`, persistence.nvim and mini.sessions, once `vim.opt.sessionoptions:append("globals")` is set.
- `session_persistence = "external"` leaves storage to your session manager. For resession.nvim: `require("resession").setup({ extensions = { claudecode = {} } })`. For auto-session, return `require("claude_agents.session_state").encode()` from `save_extra_data` and hand it back to `.restore(data)` in `restore_extra_data`.

With the agents view, also call `require("claude_agents.session_state").prepare_save()` from your session manager's pre-save hook (auto-session's `pre_save_cmds`, resession's `pre_save` hook, persistence.nvim's `User PersistenceSavePre`). Otherwise a view still open when you quit is saved with the session, agents' terminals included, and reopening the session starts them again.

## Troubleshooting

- **Claude does not connect:** `:checkhealth claude_agents`, then `:ClaudeCodeStatus`. The lock file it connects through is in `~/.claude/ide/` (or `$CLAUDE_CONFIG_DIR/ide/`).
- **`claude` not found:** set `terminal_cmd` to the path `which claude` prints.
- **Terminal misbehaves with snacks:** try `terminal.provider = "native"`.
- **Anything else:** `log_level = "debug"` and read `:messages`.

## Development

[DEVELOPMENT.md](../DEVELOPMENT.md) covers the toolchain and the tests (`mise run all` before a commit). The [protocol](protocol.md) page documents the WebSocket protocol Claude Code speaks to editors, and [architecture](architecture.md) how the plugin is put together.
