---@brief [[
--- The OpenCode service's HTTP API, as far as the plugin uses it.
---
--- Every call finds the service first (`service.ensure`), and a call that cannot
--- connect or is refused (401) forgets the connection and tries once more: the
--- service restarts with a new port and password, and the registration says so.
--- Answers are the `data` member of the service's JSON, with the response itself
--- third for callers that need a status or a cursor.
---
--- Shapes verified against OpenCode 2.0.30; see the endpoint notes per function.
---@brief ]]
---@module 'claude_agents.opencode.api'

local http = require("claude_agents.opencode.http")
local service = require("claude_agents.opencode.service")

local M = {}

M._http = http
M._service = service

---@alias ClaudeCodeOpencodeCallback fun(err: string|nil, data: any, res: ClaudeCodeHttpResponse|nil)

local function describe_error(res)
  local json = res and res.json
  if type(json) == "table" then
    local message = json.message or json._tag
    if message then
      return "HTTP " .. tostring(res.status) .. ": " .. tostring(message)
    end
  end
  return "HTTP " .. tostring(res and res.status)
end

---@param method string
---@param path string
---@param opts { query: table|nil, body: table|string|nil, timeout_ms: integer|nil, no_start: boolean|nil }|nil
---       `no_start`: answer an error rather than start a service that is not running.
---@param cb ClaudeCodeOpencodeCallback
function M.call(method, path, opts, cb)
  opts = opts or {}
  local connect = opts.no_start and M._service.find or M._service.ensure
  local attempt
  attempt = function(retried)
    connect(function(err, conn)
      if err or not conn then
        cb(err or "no OpenCode service", nil, nil)
        return
      end
      M._http.request({
        url = conn.url,
        method = method,
        path = path,
        query = opts.query,
        body = opts.body,
        auth = { user = service.USER, password = conn.password },
        timeout_ms = opts.timeout_ms,
      }, function(req_err, res)
        local refused = res and res.status == 401
        if (req_err and req_err:match("^could not connect")) or refused then
          M._service.invalidate()
          if not retried then
            attempt(true)
            return
          end
        end
        if req_err then
          cb(req_err, nil, nil)
          return
        end
        if res.status >= 400 then
          cb(describe_error(res), nil, res)
          return
        end
        local data = type(res.json) == "table" and res.json.data
        if data == nil then
          data = res.json
        end
        cb(nil, data, res)
      end)
    end)
  end
  attempt(false)
end

---`M.call`, waited for.
---@return string|nil err
---@return any data
---@return ClaudeCodeHttpResponse|nil res
function M.call_sync(method, path, opts, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local done, r_err, r_data, r_res = false, nil, nil, nil
  M.call(method, path, vim.tbl_extend("force", opts or {}, { timeout_ms = timeout_ms }), function(err, data, res)
    done, r_err, r_data, r_res = true, err, data, res
  end)
  vim.wait(timeout_ms + 1000, function()
    return done
  end, 5)
  if not done then
    return "timed out after " .. timeout_ms .. " ms", nil, nil
  end
  return r_err, r_data, r_res
end

local function enc(id)
  return http.urlencode(id)
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

---`POST /api/session` — `{ id?, parentID?, title?, agent?, model?: { providerID, id }, location?: { directory }, metadata?, permissions? }`.
function M.create_session(body, cb)
  M.call("POST", "/api/session", { body = body }, cb)
end

function M.get_session(id, cb)
  M.call("GET", "/api/session/" .. enc(id), nil, cb)
end

---`PATCH /api/session/<id>` — `{ title?, metadata?, permissions? }`.
function M.update_session(id, body, cb)
  M.call("PATCH", "/api/session/" .. enc(id), { body = body }, cb)
end

---Deletes the session and its children.
function M.delete_session(id, cb)
  M.call("DELETE", "/api/session/" .. enc(id), nil, cb)
end

---`POST /api/session/<id>/fork` — `{ before? }`; answers the new session.
function M.fork_session(id, body, cb)
  M.call("POST", "/api/session/" .. enc(id) .. "/fork", { body = body or {} }, cb)
end

---`GET /api/session` — query `directory`, `project`, `parentID` (`"null"` for top level), `limit`, `order`, `cursor`, `search`.
function M.list_sessions(query, cb)
  M.call("GET", "/api/session", { query = query }, cb)
end

---`GET /api/session/<id>/message` — query `limit`, `order`, `cursor`, `type`.
function M.messages(id, query, cb)
  M.call("GET", "/api/session/" .. enc(id) .. "/message", { query = query }, cb)
end

---@param model { providerID: string, id: string }
function M.set_model(id, model, cb)
  M.call("POST", "/api/session/" .. enc(id) .. "/model", { body = { model = model } }, cb)
end

function M.set_agent(id, agent, cb)
  M.call("POST", "/api/session/" .. enc(id) .. "/agent", { body = { agent = agent } }, cb)
end

function M.interrupt(id, cb)
  M.call("POST", "/api/session/" .. enc(id) .. "/interrupt", { body = {} }, cb)
end

--------------------------------------------------------------------------------
-- Permissions, agents, models
--------------------------------------------------------------------------------

---Answer a permission request: `decision` is `once`, `always` or `reject`.
---A `reject` with a message fails the tool with that message, which the model reads.
function M.reply_permission(session_id, request_id, decision, message, cb)
  local body = { decision = decision }
  if type(message) == "string" and message ~= "" then
    body.message = message
  end
  M.call(
    "POST",
    "/api/session/" .. enc(session_id) .. "/permission/" .. enc(request_id) .. "/reply",
    { body = body },
    cb
  )
end

---Pending permission requests of a session.
function M.permissions(session_id, cb)
  M.call("GET", "/api/session/" .. enc(session_id) .. "/permission", nil, cb)
end

---An agent with its effective permission rules.
---@param directory string|nil The location whose configuration applies.
function M.agent(agent_id, directory, cb)
  M.call("GET", "/api/agent/" .. enc(agent_id), {
    query = directory and { ["location[directory]"] = directory } or nil,
  }, cb)
end

---The location a directory resolves to: `{ directory, project = { id, directory, canonical } }`.
function M.location(directory, cb)
  M.call("GET", "/api/location", { query = { ["location[directory]"] = directory } }, cb)
end

function M.models(directory, cb)
  M.call("GET", "/api/model", { query = directory and { ["location[directory]"] = directory } or nil }, cb)
end

---Running shell commands of a location (background shells).
function M.shells(directory, cb)
  M.call("GET", "/api/shell", { query = directory and { ["location[directory]"] = directory } or nil }, cb)
end

function M.shell_output(shell_id, directory, query, cb)
  local q = vim.tbl_extend("force", query or {}, directory and { ["location[directory]"] = directory } or {})
  M.call("GET", "/api/shell/" .. enc(shell_id) .. "/output", { query = q }, cb)
end

return M
