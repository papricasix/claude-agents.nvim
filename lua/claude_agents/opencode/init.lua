---@brief [[
--- OpenCode as the agent behind a launch, next to the Claude Code CLI.
---
--- OpenCode (V2) is a terminal client of a shared background service that owns
--- sessions, configuration and tool execution. The plugin talks to it on three
--- paths, the counterparts of Claude's three channels:
---   * the editor context: OpenCode's TUI speaks the same IDE protocol to the
---     plugin's WebSocket server (selection and @ mentions only — it calls no
---     tools), told the port through `OPENCODE_EDITOR_SSE_PORT`;
---   * the service's HTTP API (`api.lua`): sessions are created with the rules
---     and model a launch needs, edits are answered, history is read;
---   * the service's event stream (`events.lua`), translated into the hook
---     events every consumer already reads (`bridge.lua`).
---
--- This module holds the configuration and the facts about ids every other
--- part needs.
---@brief ]]
---@module 'claude_agents.opencode'

local M = {}

M.DEFAULTS = {
  cmd = "opencode",
  start_service = "view",
  review_edits = true,
  service_timeout_ms = 15000,
}

---@type table|nil The full plugin config, for the few answers that need more than the `opencode` block.
local full = nil

---@type table
local config = vim.deepcopy(M.DEFAULTS)
---@type "claude"|"opencode"
local default_backend = "claude"

---@param full_config table|nil
function M.setup(full_config)
  full = type(full_config) == "table" and full_config or nil
  local opts = full and full.opencode or nil
  config = vim.tbl_deep_extend("force", vim.deepcopy(M.DEFAULTS), type(opts) == "table" and opts or {})
  default_backend = (full and full.backend == "opencode") and "opencode" or "claude"
end

---A Neovim key (`<C-p>`) in OpenCode's notation (`ctrl+p`); nil for anything
---that is not a single Ctrl or Alt chord.
---@param lhs any
---@return string|nil
function M.opencode_key(lhs)
  if type(lhs) ~= "string" then
    return nil
  end
  local mod, key = lhs:match("^<([CcMmAa])%-(.)>$")
  if not mod then
    return nil
  end
  mod = mod:lower()
  return (mod == "c" and "ctrl+" or "alt+") .. key:lower()
end

---The OpenCode keybinds an agent launch overrides, as cli.json takes them; nil
---for none.
---
---The agents view takes its session-switching keys inside an agent's terminal,
---so OpenCode never sees them there. By default those are `<C-n>`/`<C-p>`, and
---OpenCode opens its command palette — its way to settings and every command —
---with ctrl+p (its lists also take ctrl+n/ctrl+p, beside the arrow keys, which
---keep working). So unless told otherwise, an agent's palette moves to
---`<leader>p` (OpenCode's leader, ctrl+x, then p) whenever ctrl+p is one of
---those keys. Tab terminals keep ctrl+p: nothing takes it there.
---@return table<string, any>|nil
function M.agent_keybinds()
  local setting = config.agent_keybinds
  if setting == false then
    return nil
  end
  if type(setting) == "table" then
    return next(setting) ~= nil and setting or nil
  end
  local agents = full and type(full.agents) == "table" and full.agents or {}
  local keys = type(agents.keymaps) == "table" and agents.keymaps or {}
  local next_key = keys.next_session == nil and "<C-n>" or keys.next_session
  local prev_key = keys.prev_session == nil and "<C-p>" or keys.prev_session
  if M.opencode_key(next_key) == "ctrl+p" or M.opencode_key(prev_key) == "ctrl+p" then
    return { ["command.palette.show"] = "<leader>p" }
  end
  return nil
end

---`OPENCODE_CLI_CONFIG_CONTENT` (OpenCode's inline `cli.json`, which the TUI
---merges over the user's file) with keybinds merged in: whatever the variable
---held already — the user's own, from the environment or the config's `env` —
---with these keybinds over its own.
---@param existing string|nil
---@param keybinds table<string, any>
---@return string
function M.cli_config_content(existing, keybinds)
  local base = nil
  if type(existing) == "string" and existing ~= "" then
    local ok, decoded = pcall(vim.json.decode, existing)
    if ok and type(decoded) == "table" then
      base = decoded
    end
  end
  base = base or {}
  base.keybinds = type(base.keybinds) == "table" and base.keybinds or {}
  for id, value in pairs(keybinds) do
    base.keybinds[id] = value
  end
  return vim.json.encode(base)
end

---The `opencode` config block.
---@return table
function M.config()
  return config
end

---The backend plain launches use.
---@return "claude"|"opencode"
function M.default_backend()
  return default_backend
end

---Whether a conversation id is OpenCode's (`ses_…`) rather than Claude's (a UUID).
---@param id any
---@return boolean
function M.is_session_id(id)
  return type(id) == "string" and id:match("^ses_[%w]+$") ~= nil
end

---The backend a conversation id belongs to.
---@param id string|nil
---@return "claude"|"opencode"|nil
function M.backend_of(id)
  if M.is_session_id(id) then
    return "opencode"
  end
  if type(id) == "string" and id:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
    return "claude"
  end
  return nil
end

---The OpenCode command as an argv prefix.
---@return string[]
function M.cmd_argv()
  local cmd = type(config.cmd) == "string" and config.cmd ~= "" and config.cmd or "opencode"
  local ok, argv = pcall(function()
    return require("claude_agents.utils").parse_command(cmd)
  end)
  if ok and type(argv) == "table" and #argv > 0 then
    return argv
  end
  return { cmd }
end

---A directory as OpenCode's processes see it: symlinks resolved. The TUI's own
---working directory is the real path (on macOS the temp directory is `/var/…`
---to Neovim and `/private/var/…` to every process), and a session it opens in
---another spelling of the same place is moved to its own.
---@param dir string
---@return string
function M.canonical(dir)
  if type(dir) ~= "string" or dir == "" then
    return dir
  end
  local uv = vim.uv or vim.loop
  local ok, real = pcall(function()
    return uv.fs_realpath(dir)
  end)
  return (ok and type(real) == "string" and real ~= "") and real or dir
end

---Whether the OpenCode executable is on PATH.
---@return boolean
function M.available()
  local exe = M.cmd_argv()[1]
  local ok, result = pcall(function()
    return vim.fn.executable(exe)
  end)
  return ok and result == 1
end

--- What a session's metadata is stamped with, so a session the plugin created
--- can be told from one it did not.
M.METADATA_KEY = "claude_agents"

--- The mark an OpenCode conversation's row carries in the agents view, unless a
--- launch profile gives it its own.
M.MARK = "◇"

---Test/reload helper.
function M._reset()
  config = vim.deepcopy(M.DEFAULTS)
  default_backend = "claude"
  full = nil
end

return M
