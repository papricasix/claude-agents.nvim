# claude-agents.nvim guide

Everything the [README](../README.md) leaves out except the agents view, which has [its own guide](agents.md). Every option and its default is in [`lua/claude_agents/config.lua`](../lua/claude_agents/config.lua), and the terminal's in [`lua/claude_agents/terminal.lua`](../lua/claude_agents/terminal.lua); this page names the ones worth knowing.

## Commands

```vim
:ClaudeCode [args]              " toggle the Claude terminal; args go to the CLI (--resume, --continue, ...)
:ClaudeCodeFocus                " jump to the terminal, or hide it when you are in it
:ClaudeCodeOpen [args] / :ClaudeCodeClose
:ClaudeCodeSelectModel          " pick a model, then open Claude with it (OpenCode: switch a running one)
:ClaudeCodeProfile [name]       " start this tab's Claude on a profile (subscription, API key, OpenCode), or switch it
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

With `command_aliases = true` every command also gets a name without `ClaudeCode` in it: `:Agent`, `:AgentSend`, `:AgentAdd`, `:AgentProfile`, `:AgentDiffAccept`, `:Agents`, `:AgentNew`, `:AgentsFlag`, and so on (`ClaudeCode` becomes `Agent`, and `AgentAgent` becomes `Agent`). A name another plugin already uses is left to it.

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

## OpenCode

The plugin can run [OpenCode](https://opencode.ai) instead of Claude Code, or next to it. `backend = "opencode"` makes every plain launch OpenCode; a profile with `backend = "opencode"` runs OpenCode for the launches you pick it for, whatever the default. When OpenCode is installed, a built-in `OpenCode` profile (key `o`) is in the profile menu, so `:ClaudeCodeProfile OpenCode`, or `ga` in the agents view, starts one without any setup.

```lua
opts = {
  backend = "opencode",   -- plain launches run OpenCode; "claude" (the default) runs Claude Code
  opencode = {
    cmd = "opencode",     -- the executable, when it is not on your PATH
    start_service = "view", -- "launch": the agents view never starts OpenCode's service
    review_edits = true,  -- review OpenCode's edits as diffs in Neovim
  },
  profiles = {
    list = {
      { name = "subscription", key = "s", auth = "subscription" },
      { name = "OpenCode", key = "o", backend = "opencode" },
      { name = "OpenCode · plan", key = "p", backend = "opencode",
        model = "anthropic/claude-sonnet-4-5", agent = "plan" },
    },
  },
}
```

An OpenCode profile takes a `model` as OpenCode names it (`provider/model`, as `opencode models` lists them), an OpenCode `agent`, and `args` and `env`; `auth` and the key fields are Claude's. A conversation always continues in the CLI that holds it: resuming an OpenCode session runs OpenCode, a Claude one runs Claude, and picking a profile on the other backend for a running conversation starts a new one there instead.

What works the same: the terminal, your selection and `:ClaudeCodeSend` / `:ClaudeCodeAdd` / `:ClaudeCodeTreeAdd` (OpenCode shows the selection under its prompt and sends it with your next message), per-tab status, the live cursor, session persistence, the agents view, and edits as diffs you accept with `:w` and reject with `:q`. `:ClaudeCodeSelectModel` lists the models OpenCode offers and switches a running OpenCode to the one you pick.

What is different:

- **Edits are reviewed through OpenCode's permissions.** For each session it launches the plugin asks OpenCode to ask before an edit; the request opens as a diff in Neovim, and OpenCode's own prompt shows it too, so either answers it. An agent that may not edit somewhere (the plan agent outside its plan folder, a read-only subagent, a `deny` in your OpenCode config) still may not: only edits that would have gone through unasked are asked about. If you change the proposal before `:w`, your version is written and OpenCode is told so. `opencode.review_edits = false` leaves OpenCode to its own rules.
- **The plan view shows the plan files** OpenCode's plan agent writes (`~/.opencode/plan/`), until its next tool call. There is nothing to accept: OpenCode's plan agent asks nothing.
- **Status comes from OpenCode's event stream**, not from hooks, so nothing extra runs per tool call. A busy OpenCode tab or agent shows OpenCode's own spinner, the braille snake `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`; `status.opencode_icons` sets OpenCode's icons as `status.icons` sets Claude's.
- **Only conversations the plugin launched are followed.** A session you start inside OpenCode with `/new` is not tied to the tab.
- **No clickable paths** in its terminal: OpenCode prints none. `<S-CR>` inserts a newline as it does for Claude.
- **In the agents view, OpenCode's command palette is `ctrl+x p`**, not `ctrl+p`: there `<C-n>`/`<C-p>` switch sessions even inside an agent's terminal, so OpenCode would never see `ctrl+p`. Only the OpenCode agents the view launches are changed, and only while `<C-p>` is a session key; its lists keep the arrow keys. `opencode.agent_keybinds` sets other OpenCode keys for those agents (`{ ["command.palette.show"] = "ctrl+y" }`, any id from OpenCode's keybind list), or `false` leaves them all as they are.
- **In the agents view, OpenCode shows no session tabs**: the Sessions pane already lists the conversations, and OpenCode keeps one set of tabs per directory, so every agent of a project would show all the others as its tabs. Only the agents the view launches are changed; `opencode.agent_tabs = true` leaves them to your `cli.json`.
- **Of the plugin's own tools, only [opening files](#opening-files) is offered to OpenCode**; diagnostics are not, OpenCode has its own.

OpenCode runs a background service that every OpenCode client shares; the plugin talks to it too, and the agents view lists OpenCode's conversations only while it runs. An OpenCode launch starts it (`opencode service start`), and so does the agents view when it opens in a directory the plugin has launched OpenCode in, so they are listed after a login too. With `opencode.start_service = "launch"` only a launch does, and the view says `◇ OpenCode stopped · gO starts it` instead; `gO`, or `:ClaudeCodeOpencodeStart`, starts it anywhere. A service you switched off (`opencode service set disabled true`) is never started: OpenCode's terminals then run on private servers the plugin cannot reach, and the view and `:checkhealth claude_agents` say how to switch it back on.

OpenCode's terminal connects back to Neovim without the token Claude Code sends (it only sends one when it finds the editor by scanning lock files). The plugin lets exactly one such connection in for each OpenCode it launches, on the loopback interface, never from a web page (browsers announce themselves with an `Origin` header), and offers it nothing but your selection and @ mentions.

## Diffs

Claude's proposed edit opens as a diff. Write it (`:w`) to accept, close it (`:q`) to reject, and change it before writing if you want something slightly different. The proposal says so at its top (in a float, in its border), and answering it takes you back to the terminal you were typing in. An agent's diff that opens in another tab is announced with the tab it is in.

`diff_opts.provider` picks how it looks. `"unified"` shows the proposal in one buffer with the changes marked inline, and needs [unified.nvim](https://github.com/papricasix/unified.nvim). `"native"` is a side-by-side vimdiff. `"auto"`, the default, uses unified.nvim when it is installed. `diff_opts.layout` is `"vertical"`, `"horizontal"` or `"float"`; a float needs unified.nvim too, and is sized by the top-level `float` block.

A diff resolved somewhere else, for example from Claude's remote control on your phone, closes when the session that opened it disconnects. While it is still connected, `:ClaudeCodeCloseAllDiffs` clears the leftovers.

An auto-save plugin will accept every diff the moment it opens. Exclude diff buffers in its condition: they are the ones with `buftype` `acwrite`.

```lua
condition = function(buf)
  return vim.bo[buf].buftype ~= "acwrite"
end
```

Edits Claude makes with shell commands (`sed -i`, a script) never pass through a diff. With `bash_changes` (on by default) every launch asks Claude Code (2.1.300 or newer) to record what each Bash command changed: it shows that diff under the command, and the agents view counts those files in [Changes](agents.md#changes-and-activity). A `bashEditDiffEnabled` of your own in Claude Code's settings is left as it is.

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

## Opening files

On by default. Ask Claude to open a file — "open the parser", "show me a.lua and b.lua side by side", "open it in a float" — and it opens here: in a new tab after the one Claude runs in, unless you name another place. Several files open together in one tab, side by side, stacked or in a grid (four files: 2×2); `split` and `vsplit` put each beside the editor window next to the terminal, and no other window changes size. A file already on screen is jumped to instead of opened again, unless you asked for a float or a split. A line or range Claude names puts the cursor there, and the range stays highlighted until you move.

```lua
open_files = {
  enabled = true,
  layout = "tab",       -- "tab" | "float" | "split" | "vsplit": where files go unless you say
  focus = true,         -- false: open without moving your cursor (or say "in the background")
  server_name = "nvim", -- Claude calls the tool mcp__nvim__open_files
}
```

Claude asks before each call, like any MCP tool; "don't ask again" allows it for the project. A float takes the cursor whatever `focus` says, and `q` closes it. In the agents view a tab opens next to the view, and a split becomes a tab. OpenCode is offered the same tool (`nvim-<id>_open_files`) and, like its other MCP tools, calls it without asking.

## Per-tab status

On by default. For one Claude per tab: each tab is `busy`, `waiting` (for you: a permission prompt, a question, a plan), `done` (finished, not looked at yet), `idle` or `none`, ready for your tabline.

```lua
local status = require("claude_agents.status")
status.get_state(tab) -- "busy" | "waiting" | "done" | "idle" | "none"
status.icon(tab), status.hl_group(tab) -- the glyph and highlight for that state
```

Every change fires `User ClaudeCodeStatusChanged`. `icons = { busy = status.SPINNER }` animates a working tab with the CLI's own spinner. It runs two short hook calls per tool call (before and after); `status = { enabled = false }` saves them. A tab running OpenCode is drawn with `opencode_icons` where it sets a state, and busy with OpenCode's own spinner (`status.OPENCODE_SPINNER`) unless it sets that too.

## Session persistence

Restoring a Neovim session resumes each tab's conversation, the next time you open that tab's Claude. `:ClaudeCodeSessionRestore!` (`<leader>aR`) reopens all of them at once. Conversations you ended yourself stay ended, and a tab whose Claude you never spoke to opens a fresh one.

- `session_persistence = "global"` works with `:mksession`, persistence.nvim and mini.sessions, once `vim.opt.sessionoptions:append("globals")` is set.
- `session_persistence = "external"` leaves storage to your session manager. For resession.nvim: `require("resession").setup({ extensions = { claudecode = {} } })`. For auto-session, return `require("claude_agents.session_state").encode()` from `save_extra_data` and hand it back to `.restore(data)` in `restore_extra_data`.

With the agents view, also call `require("claude_agents.session_state").prepare_save()` from your session manager's pre-save hook (auto-session's `pre_save_cmds`, resession's `pre_save` hook, persistence.nvim's `User PersistenceSavePre`). Otherwise a view still open when you quit is saved with the session, agents' terminals included, and reopening the session starts them again.

## Troubleshooting

- **Claude does not connect:** `:checkhealth claude_agents`, then `:ClaudeCodeStatus`. The lock file it connects through is in `~/.claude/ide/` (or `$CLAUDE_CONFIG_DIR/ide/`).
- **`claude` not found:** set `terminal_cmd` to the path `which claude` prints.
- **OpenCode shows no status or diffs:** `:checkhealth claude_agents` reports its service; `opencode service restart` restarts it. Only an OpenCode the plugin launched is followed.
- **OpenCode's conversations are missing from the agents view:** its service is not running; `gO` in the Sessions pane (or `:ClaudeCodeOpencodeStart`) starts it. The view starts it by itself only in a directory the plugin has launched OpenCode in.
- **Terminal misbehaves with snacks:** try `terminal.provider = "native"`.
- **Anything else:** `log_level = "debug"` and read `:messages`.

## Development

[DEVELOPMENT.md](../DEVELOPMENT.md) covers the toolchain and the tests (`mise run all` before a commit). The [protocol](protocol.md) page documents the WebSocket protocol Claude Code speaks to editors, and [architecture](architecture.md) how the plugin is put together.
