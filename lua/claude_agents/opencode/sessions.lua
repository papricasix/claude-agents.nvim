---@brief [[
--- The sessions the plugin launches OpenCode on: made ready before the TUI
--- opens them, kept in line with the review setting, and tidied away when they
--- were never used.
---
--- A launch names its session (`opencode --session <id>`). The TUI creates a
--- session it does not know only when the first prompt is submitted (measured
--- against 2.0.30), and by then the prompt is already running — too late to set
--- the model a profile asks for, or the rules that make edits reviewable. So the
--- plugin creates the session itself before the TUI starts, with those already
--- in place, and the TUI attaches to it. A session created that way and closed
--- without a word said in it is deleted again, so opening and closing a
--- terminal leaves nothing behind in OpenCode's session list.
---
--- What the plugin added to a session's rules is recorded in its metadata
--- (`metadata.claude_agents.rules`), so a later change removes exactly that and
--- leaves the user's own session rules alone.
---@brief ]]
---@module 'claude_agents.opencode.sessions'

local logger = require("claude_agents.logger")
local rules = require("claude_agents.opencode.rules")

local M = {}

M._api = require("claude_agents.opencode.api")

local function opencode()
  return require("claude_agents.opencode")
end

--- Sessions the plugin created in this Neovim: [id] = true.
local created = {}
--- Sessions already made ready since they were last launched: [id] = true.
local ready = {}
--- Sessions known to hold a prompt: [id] = true.
local used = {}
--- The agent a session runs, as last heard: [id] = agent id.
local agents = {}

---@param id string
function M.note_used(id)
  if type(id) == "string" then
    used[id] = true
  end
end

---@param id string
---@param agent string|nil
function M.note_agent(id, agent)
  if type(id) == "string" and type(agent) == "string" and agent ~= "" then
    agents[id] = agent
  end
end

---Whether a session was created by this Neovim.
---@param id string
---@return boolean
function M.created_here(id)
  return created[id] == true
end

---The plugin's own record in a session's metadata.
---@param info table|nil Session.Info
---@return table
local function own_metadata(info)
  local metadata = type(info) == "table" and type(info.metadata) == "table" and info.metadata or {}
  local own = metadata[opencode().METADATA_KEY]
  return type(own) == "table" and own or {}
end

---The agent a session will run when it names none: the configured default.
---@param directory string|nil
---@param cb fun(agent: string)
local function default_agent(directory, cb)
  M._api.call("GET", "/api/config", {
    query = directory and { ["location[directory]"] = directory } or nil,
  }, function(err, data)
    local agent = (not err and type(data) == "table" and type(data.default_agent) == "string") and data.default_agent
      or "build"
    cb(agent)
  end)
end

---Put the review rules for its agent on a session — or take them off when
---review is off. `info` is the session as last read.
---@param info table Session.Info
---@param agent string|nil The agent it runs; read or defaulted when nil.
---@param cb fun(err: string|nil)|nil
function M.apply_rules(info, agent, cb)
  cb = cb or function() end
  if type(info) ~= "table" or type(info.id) ~= "string" then
    cb("no session")
    return
  end
  local directory = info.location and info.location.directory or nil
  local own = own_metadata(info)
  local previous = own.rules
  local function write(new_rules, added)
    local metadata = vim.deepcopy(type(info.metadata) == "table" and info.metadata or {})
    local mine = vim.deepcopy(own)
    mine.rules = added
    metadata[opencode().METADATA_KEY] = mine
    M._api.update_session(info.id, { permissions = new_rules, metadata = metadata }, function(err, data)
      if not err and type(data) == "table" then
        info.permissions, info.metadata = data.permissions, data.metadata
      end
      cb(err)
    end)
  end
  local review = opencode().config().review_edits
  -- `open_files`: every Neovim's server is visible in the directory, so the
  -- session is kept to this one's (`rules.for_tool`).
  local mcp = require("claude_agents.opencode.mcp")
  local tool = mcp.enabled()
  if not review and not tool then
    if type(previous) == "table" and #previous > 0 then
      write(rules.strip(info.permissions, previous), {})
    else
      cb(nil)
    end
    return
  end
  local function with_agent(agent_id)
    M._api.agent(agent_id, directory, function(err, data)
      if err or type(data) ~= "table" then
        -- Without the agent's rules the ask rule alone could weaken a refusal,
        -- so nothing is changed; edits then go through OpenCode's own prompts.
        logger.warn("opencode", "could not read agent " .. tostring(agent_id) .. "; edits will not be reviewed:", err)
        cb(err or "no agent")
        return
      end
      local added = review and rules.for_agent(data.permissions) or {}
      if tool then
        local own_action, any_action = mcp.actions()
        for _, rule in ipairs(rules.for_tool(data.permissions, own_action, any_action)) do
          added[#added + 1] = rule
        end
      end
      write(rules.replace_tail(info.permissions, previous, added), added)
    end)
  end
  agent = agent or info.agent or agents[info.id]
  if agent then
    agents[info.id] = agent
    with_agent(agent)
  else
    default_agent(directory, with_agent)
  end
end

---@class ClaudeCodeOpencodeSessionOpts
---@field directory string The directory the TUI runs in.
---@field title string|nil A name for a new session.
---@field model { providerID: string, id: string }|nil
---@field agent string|nil
---@field launch table|nil Extra fields for the plugin's metadata record.

---Make a session ready for the TUI to open: create it when it does not exist,
---set the profile's model and agent, and put the review rules on it.
---Once per launch; a toggle that rebuilds the command asks again for nothing.
---@param id string
---@param opts ClaudeCodeOpencodeSessionOpts
---@param cb fun(err: string|nil, info: table|nil)
function M.ensure(id, opts, cb)
  if ready[id] then
    cb(nil, nil)
    return
  end
  local function finish(err, info)
    if not err then
      ready[id] = true
    end
    cb(err, info)
  end
  local function prepare(info, is_new)
    local steps = {}
    if not is_new and opts.model then
      steps[#steps + 1] = function(next_step)
        M._api.set_model(id, opts.model, function(err)
          if err then
            logger.warn("opencode", "could not switch the session's model:", err)
          end
          next_step()
        end)
      end
    end
    if not is_new and opts.agent then
      steps[#steps + 1] = function(next_step)
        M._api.set_agent(id, opts.agent, function(err)
          if err then
            logger.warn("opencode", "could not switch the session's agent:", err)
          end
          next_step()
        end)
      end
    end
    steps[#steps + 1] = function(next_step)
      M.apply_rules(info, opts.agent, function()
        next_step()
      end)
    end
    local i = 0
    local function run()
      i = i + 1
      if steps[i] then
        steps[i](run)
      else
        finish(nil, info)
      end
    end
    run()
  end

  M._api.get_session(id, function(err, info)
    if not err and type(info) == "table" then
      prepare(info, false)
      return
    end
    local metadata = {
      [opencode().METADATA_KEY] = vim.tbl_extend("force", { launched = true }, opts.launch or {}),
    }
    local body = { id = id, location = { directory = opts.directory }, metadata = metadata }
    if opts.title and opts.title ~= "" then
      body.title = opts.title
    end
    if opts.model then
      body.model = opts.model
    end
    if opts.agent then
      body.agent = opts.agent
    end
    M._api.create_session(body, function(create_err, data)
      if create_err or type(data) ~= "table" then
        finish(create_err or "could not create the session", nil)
        return
      end
      created[id] = true
      prepare(data, true)
    end)
  end)
end

---`ensure`, waited for: the launch path needs the session ready before the TUI starts.
---@param id string
---@param opts ClaudeCodeOpencodeSessionOpts
---@param timeout_ms integer|nil
---@return string|nil err
function M.ensure_sync(id, opts, timeout_ms)
  if ready[id] then
    return nil
  end
  timeout_ms = timeout_ms or opencode().config().service_timeout_ms
  local done, result = false, nil
  M.ensure(id, opts, function(err)
    done, result = true, err
  end)
  vim.wait(timeout_ms + 1000, function()
    return done
  end, 5)
  if not done then
    return "timed out preparing the OpenCode session"
  end
  return result
end

---Whether a session has anything in it worth resuming. Answers nil when that
---cannot be told (no service).
---@param id string
---@return boolean|nil
function M.resumable(id)
  if used[id] then
    return true
  end
  local err, data =
    M._api.call_sync("GET", "/api/session/" .. id .. "/message", { query = { limit = 5 }, no_start = true }, 2000)
  if err then
    if tostring(err):match("^HTTP 404") then
      return false
    end
    return nil
  end
  for _, message in ipairs(type(data) == "table" and data or {}) do
    if type(message) == "table" and message.type == "user" then
      used[id] = true
      return true
    end
  end
  return false
end

---A launched session's terminal closed to be launched again at once: made
---ready again (another profile may want another model), never deleted.
---@param id string
function M.relaunching(id)
  ready[id] = nil
end

---A launched session's terminal closed: it may be launched again, and if the
---plugin created it and nothing was ever said in it, it goes.
---@param id string
function M.closed(id)
  ready[id] = nil
  if not created[id] or used[id] then
    return
  end
  M._api.messages(id, { limit = 5 }, function(err, data)
    if err then
      return
    end
    for _, message in ipairs(type(data) == "table" and data or {}) do
      if type(message) == "table" and (message.type == "user" or message.type == "assistant") then
        used[id] = true
        return
      end
    end
    M._api.delete_session(id, function(del_err)
      if not del_err then
        created[id] = nil
        logger.debug("opencode", "deleted unused session", id)
      end
    end)
  end)
end

---Test/reload helper.
function M._reset()
  created, ready, used, agents = {}, {}, {}, {}
end

return M
