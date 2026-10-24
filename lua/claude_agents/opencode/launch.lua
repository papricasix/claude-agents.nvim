---@brief [[
--- The command and environment an OpenCode launch needs: the OpenCode half of
--- `terminal.lua`'s launch seam, which every provider and agents mode share.
---
---   * The TUI is told the editor's port in `OPENCODE_EDITOR_SSE_PORT` (and
---     `CLAUDE_CODE_SSE_PORT`, which OpenCode reads first, so an inherited one
---     cannot point it elsewhere). It then connects without a token — it sends
---     the lock file's token only when it found the editor by scanning lock
---     files — so the instance's server is armed to accept that one client.
---   * The conversation is named with `--session <id>`, minted the way OpenCode
---     mints ids, and made ready through the API before the TUI starts
---     (`sessions.ensure`).
---   * Profiles add arguments and environment; their model and agent go on the
---     session, since the TUI has no flag for either.
---
--- The launch is committed — tracked by the event bridge, its server armed —
--- only once a process actually starts (`started`), because a tab's command is
--- rebuilt on every toggle, most of which start nothing.
---@brief ]]
---@module 'claude_agents.opencode.launch'

local logger = require("claude_agents.logger")
local utils = require("claude_agents.utils")

local M = {}

M._sessions = require("claude_agents.opencode.sessions")

local function opencode()
  return require("claude_agents.opencode")
end

--- Flags with which the command already picks the conversation itself.
local SESSION_FLAGS = { ["--session"] = true, ["-s"] = true, ["--continue"] = true, ["-c"] = true }

--- The id of the conversation a tab's OpenCode runs, while its process lives:
--- [tabpage] = id. A toggle rebuilds the command and must not mint another.
local tab_ids = {}

--- Launches built but not started yet, by session id.
---@type table<string, table>
local pending = {}

---@param argv string[]
---@return boolean decides
---@return string|nil session_id
function M.session_in_argv(argv)
  for i, word in ipairs(argv) do
    local flag, inline = word:match("^(%-%-?[%w-]+)=(.*)$")
    flag = flag or word
    if SESSION_FLAGS[flag] then
      local value = inline or argv[i + 1]
      if (flag == "--session" or flag == "-s") and opencode().is_session_id(value) then
        return true, value
      end
      return true, nil
    end
  end
  return false, nil
end

---`--resume <ses_…>` and `--session-id <ses_…>` are Claude's words for what
---OpenCode calls `--session`; callers that only know the Claude flags (a
---profile restart, `:ClaudeCode --resume <id>`) get theirs translated.
---@param cmd_args string|nil
---@return string
function M.translate_args(cmd_args)
  if type(cmd_args) ~= "string" or cmd_args == "" then
    return ""
  end
  local words = utils.shell_split(cmd_args)
  local out = {}
  local i = 1
  while i <= #words do
    local word = words[i]
    if (word == "--resume" or word == "-r" or word == "--session-id") and opencode().is_session_id(words[i + 1]) then
      out[#out + 1] = "--session"
      out[#out + 1] = words[i + 1]
      i = i + 2
    else
      -- Quoted only when the word needs it, so a command reads as it was typed.
      out[#out + 1] = word:match("^[%w%-%._/:=@,+%%]+$") and word or utils.shell_quote(word)
      i = i + 1
    end
  end
  return table.concat(out, " ")
end

---Forget a tab's conversation id (its terminal closed).
---@param tab integer
function M.forget_tab(tab)
  tab_ids[tab] = nil
end

---@param tab integer
---@return string|nil
function M.tab_session(tab)
  return tab_ids[tab]
end

---@class ClaudeCodeOpencodeLaunchContext
---@field instance table The server instance the TUI connects to.
---@field for_tab boolean A tab's own terminal, rather than an agent.
---@field cwd string The directory the TUI starts in.
---@field user_env table<string, string> The config's `env`.
---@field no_proxy fun(...): string Builds a no_proxy value that keeps loopback out of the proxy.
---@field profile string|table|nil The launch profile asked for.
---@field name string|nil A name for a new conversation (agents' `--name`).
---@field model { providerID: string, id: string }|nil A model asked for at launch (`:ClaudeCodeSelectModel`); wins over the profile's.

---Build an OpenCode launch.
---@param cmd_args string|nil Arguments for the TUI.
---@param ctx ClaudeCodeOpencodeLaunchContext
---@return string cmd_string
---@return table env_table
---@return string|nil profile_name
function M.build(cmd_args, ctx)
  local profiles = require("claude_agents.profiles")
  local base = opencode().config().cmd
  local args = M.translate_args(cmd_args)
  local cmd_string = (args ~= "") and (base .. " " .. args) or base

  local tab = vim.api.nvim_get_current_tabpage()
  local decides, session_id = M.session_in_argv(utils.shell_split(cmd_string))
  if not decides then
    if ctx.for_tab then
      local ok_ss, session_state = pcall(require, "claude_agents.session_state")
      if ok_ss then
        session_id = session_state.opencode_session(tab, ctx.cwd)
      end
      session_id = session_id or tab_ids[tab] or require("claude_agents.opencode.ids").new_session_id()
    else
      session_id = require("claude_agents.opencode.ids").new_session_id()
    end
    cmd_string = cmd_string .. " --session " .. session_id
  end
  if ctx.for_tab and session_id then
    tab_ids[tab] = session_id
  end

  local argv = utils.shell_split(cmd_string)
  local profile = profiles.resolve(ctx.profile, argv)
  if profile and profiles.backend(profile) ~= "opencode" then
    -- A Claude profile remembered for, or set as the default of, a launch that
    -- runs OpenCode says nothing about it.
    profile = nil
  end
  local parts = profiles.launch_parts(profile, argv)

  local port = ctx.instance and ctx.instance.port
  local env = {}
  for key, value in pairs(ctx.user_env or {}) do
    env[key] = value
  end
  if port then
    env.OPENCODE_EDITOR_SSE_PORT = tostring(port)
    env.CLAUDE_CODE_SSE_PORT = tostring(port)
  else
    logger.error(
      "terminal",
      "No editor server for this OpenCode launch: selections and @ mentions will not reach it. Run :ClaudeCodeStart."
    )
  end
  if parts then
    if parts.args ~= "" then
      cmd_string = cmd_string .. " " .. parts.args
    end
    for key, value in pairs(parts.env) do
      env[key] = value
    end
  end
  local combined = ctx.no_proxy(os.getenv("no_proxy"), os.getenv("NO_PROXY"), env.no_proxy, env.NO_PROXY)
  env.no_proxy = combined
  env.NO_PROXY = combined

  -- An agent's terminal sits in the agents view, which has its own
  -- session-switching keys and its own list of sessions: the OpenCode keybinds
  -- those keys would shadow move, and OpenCode's session tabs go, for this TUI
  -- only (`opencode.agent_cli_config`); the variable is read by the TUI itself.
  if not ctx.for_tab then
    local overrides = opencode().agent_cli_config()
    if overrides then
      local existing = env.OPENCODE_CLI_CONFIG_CONTENT or os.getenv("OPENCODE_CLI_CONFIG_CONTENT")
      env.OPENCODE_CLI_CONFIG_CONTENT = opencode().cli_config_content(existing, overrides)
    end
  end

  if session_id then
    local err = M._sessions.ensure_sync(session_id, {
      directory = opencode().canonical(ctx.cwd),
      title = ctx.name,
      model = ctx.model or (parts and parts.model) or nil,
      agent = parts and parts.agent or nil,
      launch = { kind = ctx.for_tab and "tab" or "agent" },
    })
    if err then
      logger.warn(
        "opencode",
        "could not prepare the OpenCode session (" .. tostring(err) .. "); it starts without edit review"
      )
    end
    pending[session_id] = {
      tab = tab,
      for_tab = ctx.for_tab,
      instance = ctx.instance,
      cwd = ctx.cwd,
      profile = profile and profile.name or nil,
    }
  end

  local profile_name = profile and profile.name or nil
  if ctx.for_tab then
    profiles.set_pending_tab_launch(tab, profile_name, session_id)
  end
  return cmd_string, env, profile_name
end

---A built launch's process started: follow its session and let its editor
---connection in.
---@param session_id string|nil
---@param opts { agent_key: string|nil }|nil
function M.started(session_id, opts)
  local launch = session_id and pending[session_id]
  if not launch then
    return
  end
  pending[session_id] = nil
  opts = opts or {}
  -- Where OpenCode ran is what the agents view reads while the service is down.
  pcall(function()
    require("claude_agents.opencode.dirs").mark(launch.cwd)
  end)
  local server = launch.instance and launch.instance.server
  if server and type(server.arm_tokenless) == "function" then
    server.arm_tokenless(true)
  end
  require("claude_agents.opencode.bridge").track(session_id, {
    tab = launch.tab,
    agent_key = opts.agent_key,
    cwd = launch.cwd,
    kind = launch.for_tab and "tab" or "agent",
    instance = launch.instance,
  })
  if launch.profile then
    pcall(function()
      require("claude_agents.profiles").remember(session_id, launch.profile)
    end)
  end
end

---A tab's terminal opened a new buffer: the launch built for that tab started.
---@param tab integer
---@param bufnr integer|nil
function M.tab_started(tab, bufnr)
  local session_id = tab_ids[tab]
  if session_id and pending[session_id] then
    if bufnr then
      pcall(function()
        vim.b[bufnr].claudecode_backend = "opencode"
        vim.b[bufnr].claudecode_opencode_session = session_id
      end)
    end
    M.started(session_id)
  end
end

---A launch's process ended.
---@param session_id string|nil
---@param opts { tab: integer|nil, instance: table|nil, keep: boolean|nil }|nil
---       `keep`: it is about to be launched again (a restart), so an unused
---       session is not deleted from under the relaunch.
function M.ended(session_id, opts)
  opts = opts or {}
  if opts.tab and not opts.keep then
    tab_ids[opts.tab] = nil
  end
  local server = opts.instance and opts.instance.server
  if server and type(server.arm_tokenless) == "function" then
    server.arm_tokenless(false)
  end
  if session_id then
    require("claude_agents.opencode.bridge").untrack(session_id)
    if opts.keep then
      M._sessions.relaunching(session_id)
    else
      M._sessions.closed(session_id)
    end
  end
end

---Test/reload helper.
function M._reset()
  tab_ids, pending = {}, {}
end

return M
