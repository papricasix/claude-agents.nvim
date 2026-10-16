# claude-agents.nvim

Claude Code in Neovim, from one terminal to a whole team of agents.

![The agents view: two Claude agents at work beside the project's earlier conversations, with the selected one's changes, activity and tasks](https://raw.githubusercontent.com/papricasix/claude-agents.nvim/assets/hero.gif)

`<leader>aA` opens the agents view: several Claudes on one project, which of them is working, which one is waiting on you, what each has changed, and the subagents, shells and monitors they run, live as they work. Beside your code, Claude Code connects to Neovim the way it connects to VS Code: it sees what you have selected, opens files in your editor, and proposes every edit as a diff you accept with `:w`.

## What you get

- **The agents view.** Every conversation this project has had, read from Claude Code's own transcripts: what each one changed, file by file and edit by edit, the commands it ran, the subagents and background jobs it started, followed live while they run. Start, resume, search, flag and stop them from one tab.
- **A live cursor** that follows Claude through your files as it reads and edits them, and plan mode's plan opened as a document in the editor.
- **The IDE integration.** Claude sees your file and selection, opens files, reads your diagnostics, and shows each edit as a diff. `:w` accepts, `:q` rejects, and you can edit the proposal first.
- **Inline diffs** right in the file, if you have [unified.nvim](https://github.com/papricasix/unified.nvim), instead of two windows side by side.
- **Per-tab status** for your tabline: which tab's Claude is working, which one needs you, and which answer you have not read yet.
- **Clickable paths.** File paths in Claude's terminal open in Neovim, not in your file manager.
- **Conversations that come back.** Restore a Neovim session and each tab's Claude resumes where it left off.
- **Subscription or API key, per session.** Start any Claude on either, or switch a running one without losing the conversation. The key stays in your OS keychain, out of your config and out of reach of the commands Claude runs.
- **OpenCode too.** Run [OpenCode](https://opencode.ai) instead of Claude Code (`backend = "opencode"`), or next to it under a launch profile: the same terminal, selection, status, edit diffs and agents view, with Claude's and OpenCode's conversations in one list.

## In the agents view

A tab of its own, for several Claudes at once. Diffs and files an agent opens appear there as floats.

**Follow the work as it happens**: the subagents, shells and monitors an agent starts appear in Tasks while they run. Open one to watch what it is doing.

![The agents view: an agent's release check starts a monitor and three subagents; a running subagent is opened and its calls appear live, then its background build's output streams in](https://raw.githubusercontent.com/papricasix/claude-agents.nvim/assets/tasks.gif)

**Read what a session did**: open an edit, a changed file or a subagent's work, then flag the session to come back to.

![The agents view: opening an Activity edit, a Changes file and a subagent, then flagging a session](https://raw.githubusercontent.com/papricasix/claude-agents.nvim/assets/agents-switch.gif)

## In your editor

With one Claude beside your code, as `:ClaudeCode` opens it. **The live cursor** follows Claude through the files it reads, and **its edit** opens as an inline diff in your editor that you accept with `:w`.

![A preview split following Claude through the files it reads, then its edit as an inline diff, accepted with :w](https://raw.githubusercontent.com/papricasix/claude-agents.nvim/assets/editor.gif)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "papricasix/claude-agents.nvim",
  dependencies = { "folke/snacks.nvim" }, -- optional: a nicer terminal window
  opts = {
    agents = {
      enabled = true,
      -- tab_name = "agents", -- name the view's tab in your tabline
    },
    -- live_cursor = { enabled = true, mode = "preview" }, -- follow Claude through files
    -- session_persistence = "global", -- resume each tab's Claude with a saved session
    -- plan = { enabled = false }, -- on by default: plan mode's plan in the editor
    -- status = { enabled = false }, -- on by default: busy / waiting / done per tab
  },
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude: toggle terminal" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Claude: send selection" },
    { "<leader>aA", "<cmd>ClaudeCodeAgents<cr>", desc = "Claude: agents view" },
    { "<leader>ap", "<cmd>ClaudeCodeProfile<cr>", desc = "Claude: subscription or API key" },
  },
}
```

Coming from [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)? Change the repo line and keep everything else: the commands and the options are the same. The Lua module is now `claude_agents`; a `require("claudecode…")` in your config still works, with a one-time reminder to rename it.

You need Neovim 0.11 or newer and the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code), or [OpenCode](https://opencode.ai) 2.0 or newer with `backend = "opencode"` (the [guide](docs/guide.md#opencode) has the details). [unified.nvim](https://github.com/papricasix/unified.nvim) is optional, and gives you inline diffs. `:checkhealth claude_agents` tells you what is missing.

## Good to know

The plan view and per-tab status are on; the live cursor and session persistence are off until you turn them on. All four hear from Claude through hooks the plugin adds when it launches Claude (`claude --settings`; your own settings are left alone, and a `--settings` of your own in `terminal_cmd` is merged in), so they only work for a Claude started from Neovim, and a change applies to the next Claude you start. Per-tab status runs a short hook on every tool call; switch it off if you never look at it. OpenCode needs no hooks: the plugin follows the OpenCode it starts through OpenCode's own event stream.

The [guide](docs/guide.md) has every command, the configuration, diffs, terminal providers and each of those features. The [agents guide](docs/agents.md) walks through the agents view.

## Credits

claude-agents.nvim is a fork of [claudecode.nvim](https://github.com/coder/claudecode.nvim) by Coder and its contributors, who reverse-engineered the IDE protocol and built the WebSocket server, terminal and diff integration everything here stands on. Used under the MIT license; Coder's copyright notice is retained in [LICENSE](LICENSE). Bugs in this fork belong here, not upstream.
