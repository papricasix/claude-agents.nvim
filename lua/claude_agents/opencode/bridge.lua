---@brief [[
--- OpenCode's event stream, told to the plugin as Claude Code hook events.
---
--- Everything that follows what an agent is doing — per-tab status, the agents
--- view, session persistence, the live cursor — reads one input: a hook event
--- handed to `live_cursor.dispatch`. A Claude launch delivers those through its
--- hooks; an OpenCode launch has none, but the service reports the same moments
--- on its event stream, so they are translated here and dispatched the same way.
---
--- Only the sessions the plugin launched are followed, with their child
--- sessions (subagents): a session cannot be tied to the TUI that created it, so
--- one started inside the TUI with `/new` is not ours to report on.
---
---   OpenCode event                         hook event
---   session.execution.started              UserPromptSubmit
---   session.tool.called (+ input.started)  PreToolUse        (child: with agent_id)
---   session.tool.success / .failed         PostToolUse
---   permission.asked                       PermissionRequest (tool_use_id from its source)
---   form.created (the question tool)       PermissionRequest for AskUserQuestion
---   session.execution.succeeded            Stop              (child: SubagentStop)
---   session.execution.failed               StopFailure
---   session.execution.interrupted          status.note_interrupt
---   session.deleted                        SessionEnd
---
--- The tool call's name arrives on `session.tool.input.started`, not on the
--- `called` event, so it is remembered by call id in between.
---@brief ]]
---@module 'claude_agents.opencode.bridge'

local logger = require("claude_agents.logger")
local tools = require("claude_agents.opencode.tools")

local M = {}

M._events = require("claude_agents.opencode.events")
M._dispatch = function(event, tab, agent_key)
  require("claude_agents.live_cursor").dispatch(event, tab, agent_key)
end

---@class ClaudeCodeOpencodeTracked
---@field tab integer|nil Tab the launch lives in.
---@field agent_key string|nil The agents view's launch key.
---@field cwd string|nil
---@field kind "tab"|"agent"
---@field root string The launched session this one belongs to.
---@field parent string|nil For a child session: its parent.
---@field instance table|nil

--- [session id] = ClaudeCodeOpencodeTracked
local tracked = {}
--- [call id] = { name, input }
local calls = {}
local call_count = 0
local MAX_CALLS = 2000

local unsubscribe = nil

--- Plan files OpenCode's plan agent writes.
---@return string
function M.plan_dir()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  return home .. "/.opencode/plan/"
end

---@param id string
---@return ClaudeCodeOpencodeTracked|nil
function M.get(id)
  return tracked[id]
end

---Every launched (root) session being followed.
---@return string[]
function M.roots()
  local out = {}
  for id, entry in pairs(tracked) do
    if entry.root == id then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function remember_call(id, name, input)
  if not calls[id] then
    call_count = call_count + 1
  end
  calls[id] = calls[id] or {}
  if name then
    calls[id].name = name
  end
  if input then
    calls[id].input = input
  end
  if call_count > MAX_CALLS then
    calls, call_count = {}, 0
  end
end

---A hook event for a tracked session.
---@param entry ClaudeCodeOpencodeTracked
---@param session_id string The session the OpenCode event is about.
---@param fields table
---@return table
local function hook_event(entry, session_id, fields)
  local event = {
    session_id = entry.root,
    cwd = entry.cwd,
    transcript_path = require("claude_agents.agents.opencode_store").path(entry.root),
    -- Says the launch reports every state change (see `agents_view.note`).
    opencode = true,
  }
  if session_id ~= entry.root then
    event.agent_id = session_id
  end
  for key, value in pairs(fields) do
    event[key] = value
  end
  return event
end

local function dispatch(entry, event)
  local ok, err = pcall(M._dispatch, event, entry.tab, entry.agent_key)
  if not ok then
    logger.debug("opencode", "dispatch failed:", tostring(err))
  end
end

---The `tool_name`/`tool_input` pair of a call, in Claude's words.
---@param entry ClaudeCodeOpencodeTracked
---@param call_id string|nil
---@param input table|nil
---@return string|nil name
---@return table input
local function call_fields(entry, call_id, input)
  local call = call_id and calls[call_id] or {}
  local name = call.name
  return tools.name(name), tools.input(name, input or call.input, entry.cwd)
end

---Show a plan file the plan agent wrote, the way the plan view shows Claude's.
---@param entry ClaudeCodeOpencodeTracked
---@param path string|nil
local function maybe_show_plan(entry, path)
  if type(path) ~= "string" or path:sub(1, #M.plan_dir()) ~= M.plan_dir() then
    return
  end
  if entry.kind == "agent" then
    return -- the agents view has no window to spare for it
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" then
    return
  end
  pcall(function()
    local plan_view = require("claude_agents.plan_view")
    if plan_view.is_enabled == nil or plan_view.is_enabled() then
      plan_view.show(table.concat(lines, "\n"), entry.tab)
    end
  end)
end

---@param event table
function M.handle(event)
  local etype = event.type
  local data = type(event.data) == "table" and event.data or {}

  if etype == M._events.CONNECTED then
    M.resync()
    return
  end

  -- A location's runtime MCP servers go with it (reload, eviction).
  if etype == "location.shutdown" then
    local location = type(event.location) == "table" and event.location or data.location or data
    pcall(function()
      require("claude_agents.opencode.mcp").location_shutdown(location)
    end)
    return
  end

  if etype == "form.created" then
    local form = type(data.form) == "table" and data.form or data
    local entry = tracked[form.sessionID]
    if not entry then
      return
    end
    local tool = type(form.metadata) == "table" and type(form.metadata.tool) == "table" and form.metadata.tool or {}
    local call = tool.id and calls[tool.id] or {}
    dispatch(
      entry,
      hook_event(entry, form.sessionID, {
        hook_event_name = "PermissionRequest",
        tool_name = "AskUserQuestion",
        tool_use_id = tool.id,
        tool_input = call.input or { questions = form.fields },
      })
    )
    return
  end

  local session_id = data.sessionID
  if etype == "session.created" then
    local parent = data.parentID
    if parent and tracked[parent] and not tracked[session_id] then
      local p = tracked[parent]
      tracked[session_id] = {
        tab = p.tab,
        agent_key = p.agent_key,
        cwd = (type(data.location) == "table" and data.location.directory) or p.cwd,
        kind = p.kind,
        root = p.root,
        parent = parent,
        instance = p.instance,
      }
      require("claude_agents.opencode.sessions").note_agent(session_id, data.agent)
      pcall(function()
        require("claude_agents.opencode.review").child_created(session_id, data.agent)
      end)
    end
    return
  end

  if etype == "permission.asked" or etype == "permission.replied" then
    local entry = tracked[session_id]
    if not entry then
      return
    end
    if etype == "permission.asked" then
      local source = type(data.source) == "table" and data.source or {}
      local name, input = call_fields(entry, source.id, nil)
      dispatch(
        entry,
        hook_event(entry, session_id, {
          hook_event_name = "PermissionRequest",
          tool_name = name,
          tool_use_id = source.id,
          tool_input = input,
        })
      )
    end
    pcall(function()
      local review = require("claude_agents.opencode.review")
      if etype == "permission.asked" then
        review.asked(data, entry)
      else
        review.replied(data)
      end
    end)
    return
  end

  local entry = session_id and tracked[session_id]
  if not entry then
    return
  end
  local is_root = session_id == entry.root

  if etype == "session.tool.input.started" then
    remember_call(data.id, data.name, nil)
  elseif etype == "session.tool.called" then
    remember_call(data.id, nil, data.input)
    local name, input = call_fields(entry, data.id, data.input)
    dispatch(
      entry,
      hook_event(entry, session_id, {
        hook_event_name = "PreToolUse",
        tool_name = name,
        tool_use_id = data.id,
        tool_input = input,
      })
    )
  elseif etype == "session.tool.success" or etype == "session.tool.failed" then
    local name, input = call_fields(entry, data.id, nil)
    local response = { success = etype == "session.tool.success" }
    local patch = tools.metadata_patch(data.metadata)
    local file_path = input.file_path
    if type(patch) == "string" and file_path then
      local hunks = tools.first_hunks(patch)
      if hunks then
        response.filePath = file_path
        response.structuredPatch = hunks
      end
    end
    if type(data.error) == "table" then
      response.error = data.error.message
    end
    dispatch(
      entry,
      hook_event(entry, session_id, {
        hook_event_name = "PostToolUse",
        tool_name = name,
        tool_use_id = data.id,
        tool_input = input,
        tool_response = response,
      })
    )
    if etype == "session.tool.success" and (name == "Write" or name == "Edit") then
      maybe_show_plan(entry, file_path)
    end
    calls[data.id] = nil
    call_count = math.max(0, call_count - 1)
  elseif etype == "session.execution.started" then
    require("claude_agents.opencode.sessions").note_used(entry.root)
    if is_root then
      dispatch(entry, hook_event(entry, session_id, { hook_event_name = "UserPromptSubmit" }))
      pcall(function()
        require("claude_agents.opencode.mcp").turn_started(entry.cwd)
      end)
    end
  elseif etype == "session.execution.succeeded" or etype == "session.execution.failed" then
    local name
    if not is_root then
      name = "SubagentStop"
    elseif etype == "session.execution.succeeded" then
      name = "Stop"
    else
      name = "StopFailure"
    end
    dispatch(entry, hook_event(entry, session_id, { hook_event_name = name }))
  elseif etype == "session.execution.interrupted" then
    if is_root then
      M.interrupted(entry)
    else
      dispatch(entry, hook_event(entry, session_id, { hook_event_name = "SubagentStop" }))
    end
  elseif etype == "session.agent.selected" then
    require("claude_agents.opencode.sessions").note_agent(session_id, data.agent)
    pcall(function()
      require("claude_agents.opencode.review").agent_selected(session_id, data.agent)
    end)
  elseif etype == "session.deleted" then
    if is_root then
      dispatch(entry, hook_event(entry, session_id, { hook_event_name = "SessionEnd" }))
    end
    tracked[session_id] = nil
  end
end

---A launched session's turn was interrupted: the tab's status stops, and the
---agents view hears the turn end.
---@param entry ClaudeCodeOpencodeTracked
function M.interrupted(entry)
  if entry.kind == "tab" then
    pcall(function()
      require("claude_agents.status").note_interrupt(entry.tab)
    end)
  end
  if package.loaded["claude_agents.agents.model"] then
    pcall(function()
      require("claude_agents.agents.model").note_interrupt(entry.root)
    end)
  end
end

---After the stream reopens: a turn that ended in the gap is ended here too,
---and an edit waiting for an answer gets its diff.
function M.resync()
  local roots = M.roots()
  if #roots == 0 then
    return
  end
  -- A restarted service has lost the `open_files` servers added at runtime.
  pcall(function()
    require("claude_agents.opencode.mcp").resync()
  end)
  local api = require("claude_agents.opencode.api")
  api.call("GET", "/api/session/active", nil, function(err, data)
    if err then
      return
    end
    local active = type(data) == "table" and data or {}
    for _, id in ipairs(roots) do
      local entry = tracked[id]
      if entry and active[id] == nil then
        dispatch(entry, hook_event(entry, id, { hook_event_name = "Stop" }))
      end
    end
  end)
  for _, id in ipairs(roots) do
    pcall(function()
      require("claude_agents.opencode.review").resync(id, tracked[id])
    end)
  end
end

---Follow a launched session.
---@param session_id string
---@param opts { tab: integer|nil, agent_key: string|nil, cwd: string|nil, kind: "tab"|"agent", instance: table|nil }
function M.track(session_id, opts)
  tracked[session_id] = {
    tab = opts.tab,
    agent_key = opts.agent_key,
    cwd = opts.cwd,
    kind = opts.kind or "tab",
    root = session_id,
    instance = opts.instance,
  }
  if not unsubscribe then
    unsubscribe = M._events.subscribe(M.handle)
  end
  -- What a Claude launch's SessionStart hook says: this tab (or agent) is now
  -- having this conversation.
  dispatch(
    tracked[session_id],
    hook_event(tracked[session_id], session_id, { hook_event_name = "SessionStart", source = "startup" })
  )
end

---Stop following a launched session and its children.
---@param session_id string
function M.untrack(session_id)
  local doomed = {}
  for id, entry in pairs(tracked) do
    if entry.root == session_id then
      doomed[#doomed + 1] = id
    end
  end
  for _, id in ipairs(doomed) do
    tracked[id] = nil
  end
  pcall(function()
    require("claude_agents.opencode.review").forget_session(session_id)
  end)
  if next(tracked) == nil and unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

---Test/reload helper.
function M._reset()
  tracked, calls, call_count = {}, {}, 0
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M
