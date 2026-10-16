---@brief [[
--- Which CLI a launch runs: Claude Code or OpenCode.
---
--- In order, the first that says:
---   1. the launch profile asked for (`ga`/`gi`, `:ClaudeCodeProfile`,
---      `:ClaudeCodeAgentNew <profile>`) — its `backend`;
---   2. the conversation the launch resumes — a command line naming one, or the
---      id an agent is launched with — since a conversation only continues in
---      the CLI that holds it (`ses_…` is OpenCode's, a UUID Claude's);
---   3. for a tab's own terminal, the conversation session persistence has for
---      that tab;
---   4. `profiles.default`, when set;
---   5. the `backend` option.
---@brief ]]
---@module 'claude_agents.backend'

local utils = require("claude_agents.utils")

local M = {}

---@class ClaudeCodeBackendQuery
---@field profile string|table|nil
---@field cmd_args string|nil
---@field session_id string|nil
---@field tab integer|nil A tab's own launch: the tab.
---@field cwd string|nil

---@param query ClaudeCodeBackendQuery
---@return "claude"|"opencode"
function M.resolve(query)
  query = query or {}
  local profiles = require("claude_agents.profiles")
  local opencode = require("claude_agents.opencode")

  if query.profile ~= nil then
    local profile = profiles.get(query.profile)
    if profile then
      return profiles.backend(profile)
    end
  end

  local session_id = query.session_id
  if not session_id and type(query.cmd_args) == "string" and query.cmd_args ~= "" then
    session_id = profiles.session_of_argv(utils.shell_split(query.cmd_args))
  end
  local named = opencode.backend_of(session_id)
  if named then
    return named
  end

  if query.tab then
    local ok, session_state = pcall(require, "claude_agents.session_state")
    if ok and session_state.is_enabled() and not session_state.is_disowned(query.tab) then
      local record = session_state.get(query.tab)
      local recorded = record and opencode.backend_of(record.session_id)
      if recorded then
        return recorded
      end
    end
  end

  local default = profiles.default()
  if default then
    return profiles.backend(default)
  end
  return opencode.default_backend()
end

---The name a backend goes by in messages.
---@param backend string|nil
---@return string
function M.label(backend)
  return backend == "opencode" and "OpenCode" or "Claude"
end

return M
