# The agents view

Several Claudes on one project, in one tab: which of them is working, which one wants you, and what each has actually changed.

```text
┌────────────────────────┬──────────────────────┬──────────────────────────────────┐
│ Changes                │                      │ Sessions                         │
│ M session_st…  +90  -5 │ the selected agent's │ ● Fix session res…  2m  +90   -5 │
│ A spec.lua     +45  -0 │ Claude terminal      │ ○ Expose tab stat…  1d +865 -100 │
│                        │                      │                                  │
├────────────────────────┤                      ├──────────────────────────────────┤
│ Tasks                  │                      │ Activity                         │
│ ✓ Explore: find tests  │                      │ 14:04 added git.lua              │
│ ● $ mise run test      │                      │ 14:03 edit  status.lua           │
└────────────────────────┴──────────────────────┴──────────────────────────────────┘
```

Turn it on with `agents = { enabled = true }` and press `<leader>aA` (`:ClaudeCodeAgents`). An agent's diffs open as floats inside the view with [unified.nvim](https://github.com/papricasix/unified.nvim), and in the tab you came from without it. `?` in any pane lists every key that reaches it, as you have bound them; this page covers the ones worth knowing.

Everything in the view comes from Claude Code's own transcripts, and from OpenCode's history for OpenCode conversations, so it includes conversations you had outside Neovim, and nothing is lost when you restart.

## Sessions

The top right lists this project's conversations from the last two weeks, each with its title, how long ago it ran, and the lines it added and removed. The order holds still while agents work, so the row you are reaching for stays where it is; `gs` re-sorts it (recent, name, changes, status) and sets how far back it reaches. A running, selected or flagged session is always listed, however old.

| Key               | What it does                                                                                                                      |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `<C-n>` / `<C-p>` | Select the next or previous session, from any pane, even inside the terminal. A session that is not running is shown, not started |
| `<CR>`            | Show the session under the cursor in the centre, resuming it if it is not running                                                 |
| `i`               | Go into the selected session's terminal, starting it if needed                                                                    |
| `a`               | Start a new agent                                                                                                                 |
| `ga`              | Start a new agent on your subscription or an API key, picked from a menu                                                          |
| `gi`              | Resume the session under a profile you pick; a running one is restarted under it, its conversation carried on                     |
| `A`               | Start a new agent named after this session, numbered on (`plan` → `plan-2`), with a fresh context                                 |
| `x`               | Stop the agent under the cursor                                                                                                   |
| `dd`              | Delete the conversation for good, after asking (from OpenCode's service for an OpenCode one). Takes a count or a visual selection |
| `m`, `M`          | Flag or unflag the session, or flag it with a note                                                                                |
| `gf`              | Search the conversations                                                                                                          |
| `gO`              | Start OpenCode's background service, so its conversations are listed (with OpenCode installed)                                    |
| `q`               | Close the view, after asking. The agents keep running                                                                             |

Switching to another agent leaves the one you were in running: start three, come back to whichever finishes first. A session working in a git worktree is marked `⎇`, and resuming it puts it back in that worktree. A session run on an API key is marked `$`, and resuming it with `i` goes back to the same key; the [guide](guide.md#subscription-or-api-key) explains the profiles behind `ga` and `gi`.

**OpenCode** conversations are listed beside Claude's, marked `◇`: the ones the project had in OpenCode, wherever they ran. `ga` with the `OpenCode` profile starts an OpenCode agent (with `backend = "opencode"`, `a` does), and `<CR>` or `i` on an OpenCode session resumes it in OpenCode. Since `<C-p>` switches sessions inside its terminal, an OpenCode agent opens its command palette with `ctrl+x p` instead (`opencode.agent_keybinds`). Everything below works for them too, read from OpenCode's own history: Changes, Activity, file and tool views, search, checkpoints, flags, and the subagents in Tasks (OpenCode has no background shells, monitors or workflow runs to show). The [guide](guide.md#opencode) says what else differs.

OpenCode's conversations are listed only while OpenCode's background service runs. The view starts it when it opens in a directory the plugin has launched OpenCode in, so after a login they are back by themselves. With `opencode.start_service = "launch"` it leaves the service stopped, and the list's top line says `◇ OpenCode stopped · gO starts it`; `gO`, or `<CR>` on that line, starts it.

**Flags** are for sessions you have to come back to. A plain flag (`⚑`) comes off when you next answer that conversation, wherever you do it. A flag with a note (`⚑ Port upstream · check CI`) stays until you take it off. Flags survive restarts and are shared between Neovims.

**Search** (`gf`) finds what you said, what Claude said, the files a session touched, the commands it ran and its reasoning. Tool output is not searched, so a word only matches where it was written or run. The search starts on the whole project, older conversations included, and `<Tab>` widens it to every project on this machine. Moving through the results shows each session in the panes; `<CR>` goes into it, and `<Esc>` puts back the session you had.

## Changes and Activity

**Changes**, top left, lists every file the selected session touched, with the lines it added and removed and the file's git status. The counts are what Claude did, not the state of your tree: an edit you reverted still counts. **Activity**, bottom right, lists everything the session did, newest first: edits, reads, commands, searches, subagents. `…` marks a call still running, `✗` one that failed, `⊘` one you stopped or declined, or a permission rule or auto mode refused. `f` cycles between everything, files only and commands only.

| Key               | What it does                                                                                                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<CR>`            | Show the work: on a Changes row, everything the session did to that file, inline; on an Activity row, that one edit, the lines that read covered, or the command with its output |
| `.`               | Diff the file against git `HEAD` (svn `BASE`): everything uncommitted, whoever did it                                                                                            |
| `gf`              | Open the file itself in a new tab, to work in                                                                                                                                    |
| `<C-n>` / `<C-p>` | Inside one of those floats: the next or previous row of the pane                                                                                                                 |

A file view shows the file **as it stood then**, rebuilt from the transcript, and its title says `reconstructed`. When the transcript never held the whole file (a large file Claude only read in parts), it shows today's file with the session's edits undone instead, and says `on disk`. A key that edits, such as `i`, `dd` or `ciw`, pressed in one of these floats opens the real file in a new tab and does it there.

A rewind (`/rewind`, or `Esc Esc`) is drawn as a rule in Activity, and the calls it took back drop out of every count.

## Checkpoints

`gc` draws a line through the selected session's history: from then on, what it does is listed apart from what it did before, in all three panes. Take one after you have reviewed an agent's work, and only the new work is above the line. A file edited on both sides gets a row on each, and `<CR>` on either shows just that part. `a` on the rule names it, and `gC` drops the newest. Checkpoints survive restarts.

## Tasks

Bottom left: the subagents the session started, as a tree, with its background shells (`$`), monitors (`~`) and workflow runs (`»`) under whoever started them. `●` is running, `✓` done, `✗` failed, `⊘` stopped.

`<CR>` on a subagent opens its transcript: the prompt it got, what it said, and one line per tool call. Tool output is left out: `<CR>` on a call opens it, `<CR>` on a subagent this one started opens that one, and `<BS>` goes back up. `<CR>` on a shell or monitor shows its output, followed live while it runs. `g.` names the rows by agent type or command instead of description.

## Diffs and files

Each agent has its own connection to Neovim, so a diff goes to the agent that asked for it. Files an agent opens, and with unified.nvim its diffs, appear as floats titled with the agent, stacked so several can wait for you at once. `:w` accepts and `:q` rejects, as everywhere else. The live cursor and the plan view do not run inside the view: every window there is a pane.

## Configuration

Every option is in the `agents` block of [`lua/claude_agents/config.lua`](../lua/claude_agents/config.lua), except the fade animation's, which [`agents/fade.lua`](../lua/claude_agents/agents/fade.lua) owns. The ones people change:

```lua
agents = {
  enabled = true,
  sessions = { limit = "2w", sort = "recent" }, -- "3d", "1m", "all", or a count
  kill_on_close = false,     -- stop the agents when the view closes
  resume_mode = "resume",    -- "fork" resumes into a copy of the conversation
  tab_name = false,          -- e.g. "agents", for tablines that show tab names
  keymaps = { delete = false }, -- any key can be rebound, or unbound with false
}
```

The view follows the agents through the hooks [per-tab status](guide.md#per-tab-status) runs, which is on by default. An edit then shows as soon as the tool finishes, even while Claude Code has not yet written it to its transcript. With status off it watches their transcripts instead, up to half a second behind (`agents.source`). OpenCode agents report through OpenCode's own event stream either way, and a busy one spins OpenCode's braille snake rather than Claude's spinner.

The commands, to map from inside an agent's terminal where the pane keys do not reach. All but the first and the last act on the selected session:

```vim
:ClaudeCodeAgentNew [profile]         " start a new agent, on a launch profile if named
:ClaudeCodeProfile [profile]          " resume or switch it under a launch profile (no name: the gi menu)
:ClaudeCodeAgentFollowUp              " a new agent named after it, numbered on
:ClaudeCodeAgentsCheckpoint[!]        " draw a checkpoint; with !, drop the newest
:ClaudeCodeAgentsFlag[!] [note]       " toggle its flag, or flag it with a note; with !, unflag
:ClaudeCodeOpencodeStart              " start OpenCode's background service (gO)
```
