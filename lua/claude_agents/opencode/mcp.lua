---@brief [[
--- `open_files` for OpenCode: the model's way to open files in this Neovim.
---
--- A Claude launch is handed its tool server on the command line
--- (`open_files.mcp_config`). OpenCode's MCP servers belong to its shared
--- service instead, configured per directory, and nothing a launched TUI carries
--- reaches it. What does (2.0.30, read from the binary):
---
---   * `PUT /api/experimental/mcp/<name>?location[directory]=<dir>` with
---     `{ config }` adds a server to that directory's set at runtime, replacing
---     one of the same name. It is kept in memory only: a service restart, an
---     `opencode reload` and the location's eviction (an hour without activity)
---     drop it, so it is added again when the event stream reconnects, when a
---     location shuts down, and checked at every prompt.
---   * Remote servers speak Streamable HTTP only, so this is a small HTTP
---     endpoint of its own (`POST /mcp`, JSON answers, no SSE), not the
---     WebSocket server a Claude launch uses.
---   * Every `tools/call` names the session that made it in
---     `params._meta["ai.opencode/sessionID"]` — a subagent's own session for a
---     subagent — which the event bridge maps to the tab or agent it belongs to.
---     A call from a session this Neovim did not launch is refused.
---   * MCP tools sit behind OpenCode's "code mode" `execute` tool unless the
---     server says `codemode = false`.
---
--- Every session in the directory sees a server added there, so each Neovim
--- registers under a name of its own (`<server_name>-<8 hex>`), and the plugin's
--- sessions carry rules hiding every other Neovim's (`rules.for_tool`).
---@brief ]]
---@module 'claude_agents.opencode.mcp'

local logger = require("claude_agents.logger")

local M = {}

M.PATH = "/mcp"
M.SESSION_META = "ai.opencode/sessionID"
M.TOKEN_HEADER = "x-claude-code-ide-authorization"
--- Largest request body read.
M.MAX_BODY = 1024 * 1024

M._api = require("claude_agents.opencode.api")

local state = {
  server = nil,
  port = nil,
  token = nil,
  id = nil,
  --- [directory] = true once added there.
  registered = {},
}

local function hex(bytes)
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

---@return table
local function open_files()
  return require("claude_agents.open_files")
end

---Whether OpenCode sessions are offered the tool.
---@return boolean
function M.enabled()
  return open_files().enabled()
end

---This Neovim's id among others registering in the same directories.
---@return string
local function instance_id()
  if not state.id then
    state.id = hex(require("claude_agents.utils").random_bytes(4))
  end
  return state.id
end

---The server's name in OpenCode: `<server_name>-<8 hex>`.
---@return string
function M.server_name()
  return open_files().opts().server_name .. "-" .. instance_id()
end

---The permission action of this Neovim's tool (OpenCode names an MCP tool
---`<server>_<tool>`), and a pattern for every Neovim's.
---@return string own
---@return string any
function M.actions()
  local prefix = open_files().opts().server_name
  return M.server_name() .. "_open_files", prefix .. "-????????_open_files"
end

--------------------------------------------------------------------------------
-- The endpoint
--------------------------------------------------------------------------------

---@param status integer
---@param reason string
---@param body string|nil
---@param extra string[]|nil
---@return string
local function http_response(status, reason, body, extra)
  local lines = { ("HTTP/1.1 %d %s"):format(status, reason) }
  if body then
    lines[#lines + 1] = "Content-Type: application/json"
  end
  lines[#lines + 1] = "Content-Length: " .. tostring(body and #body or 0)
  lines[#lines + 1] = "Connection: close"
  for _, line in ipairs(extra or {}) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

---@param id any
---@param result table|nil
---@param err table|nil
---@return table
local function rpc_reply(id, result, err)
  local out = { jsonrpc = "2.0", id = id }
  if err then
    out.error = err
  else
    out.result = result
  end
  return out
end

---The tool registry, filled: an editor server instance registers it as it
---starts, but nothing here may depend on one having started first.
---@return table
local function tools_registry()
  local tools = require("claude_agents.tools.init")
  if next(tools.model_tools) == nil then
    tools.register_all()
  end
  return tools
end

---The text the model reads when a call cannot be served.
---@param text string
---@return table
local function refusal(text)
  return { content = { { type = "text", text = text } }, isError = true }
end

---Serve a `tools/call` for the session that made it.
---@param params table
---@return table result
local function call_tool(params)
  local meta = type(params._meta) == "table" and params._meta or {}
  local session_id = meta[M.SESSION_META]
  local entry = type(session_id) == "string" and require("claude_agents.opencode.bridge").get(session_id) or nil
  if not entry then
    return refusal(
      "This OpenCode session was not started from this Neovim, so this tool cannot open files for it. "
        .. "Tell the user to open the file themselves."
    )
  end
  local tools = tools_registry()
  local context = require("claude_agents.request_context")
  local saved = context.get()
  context.set({
    instance_id = entry.instance and entry.instance.id or nil,
    tab = entry.tab,
    session_id = entry.kind == "agent" and entry.root or nil,
    kind = entry.kind,
    backend = "opencode",
  })
  local ok, outcome = pcall(tools.handle_invoke, nil, { name = params.name, arguments = params.arguments }, true)
  context.set(saved)
  if not ok then
    return refusal("open_files failed: " .. tostring(outcome))
  end
  if outcome.error then
    return refusal(tostring(outcome.error.message or "open_files failed"))
  end
  return outcome.result
end

---Answer one JSON-RPC message; nil for a notification or a response.
---@param message table
---@return table|nil
function M.handle_message(message)
  if type(message) ~= "table" or message.method == nil then
    return nil
  end
  local is_request = message.id ~= nil
  local params = type(message.params) == "table" and message.params or {}
  local method = message.method
  if not is_request then
    return nil
  end
  if method == "initialize" then
    local main = package.loaded["claude_agents"]
    return rpc_reply(message.id, {
      protocolVersion = type(params.protocolVersion) == "string" and params.protocolVersion or "2025-03-26",
      capabilities = { tools = { listChanged = false } },
      serverInfo = {
        name = "claudecode-neovim",
        version = (main and main.version and main.version.string) and main.version:string() or "0",
      },
      instructions = open_files().instructions(),
    })
  elseif method == "ping" then
    return rpc_reply(message.id, vim.empty_dict())
  elseif method == "tools/list" then
    return rpc_reply(message.id, { tools = tools_registry().get_model_tool_list({}) })
  elseif method == "tools/call" then
    return rpc_reply(message.id, call_tool(params))
  end
  return rpc_reply(message.id, nil, { code = -32601, message = "Method not found: " .. tostring(method) })
end

---Answer one HTTP request.
---@param req { method: string, path: string, headers: table<string, string>, body: string }
---@return string response
function M.handle_http(req)
  local path = (req.path or ""):match("^[^?#]*")
  if path ~= M.PATH then
    return http_response(404, "Not Found")
  end
  -- A browser page reaching for a loopback port sends an Origin; OpenCode never does.
  if req.headers.origin then
    return http_response(403, "Forbidden")
  end
  local token = req.headers[M.TOKEN_HEADER]
  if
    not state.token
    or type(token) ~= "string"
    or not require("claude_agents.server.utils").constant_time_compare(token, state.token)
  then
    return http_response(401, "Unauthorized")
  end
  if req.method ~= "POST" then
    -- No server-sent stream to open, and no MCP session to end.
    return http_response(405, "Method Not Allowed", nil, { "Allow: POST" })
  end
  local ok, decoded = pcall(vim.json.decode, req.body or "", { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    local body = vim.json.encode(rpc_reply(vim.NIL, nil, { code = -32700, message = "Parse error" }))
    return http_response(400, "Bad Request", body)
  end
  local batch = decoded[1] ~= nil
  local replies = {}
  for _, message in ipairs(batch and decoded or { decoded }) do
    local reply = M.handle_message(message)
    if reply then
      replies[#replies + 1] = reply
    end
  end
  if #replies == 0 then
    return http_response(202, "Accepted")
  end
  return http_response(200, "OK", vim.json.encode(batch and replies or replies[1]))
end

---Read one request off a connection, then answer and close it.
---@param client userdata uv_tcp_t
local function serve(client)
  local buffer = ""
  local head, length
  local function finish(response)
    client:write(response, function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
  client:read_start(function(err, data)
    if err or not data then
      if not client:is_closing() then
        client:close()
      end
      return
    end
    buffer = buffer .. data
    if not head then
      local stop = buffer:find("\r\n\r\n", 1, true)
      if not stop then
        if #buffer > 64 * 1024 then
          client:read_stop()
          finish(http_response(431, "Request Header Fields Too Large"))
        end
        return
      end
      head = buffer:sub(1, stop - 1)
      buffer = buffer:sub(stop + 4)
      length = tonumber(head:match("\r\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:%s*(%d+)")) or 0
      if length > M.MAX_BODY then
        client:read_stop()
        finish(http_response(413, "Payload Too Large"))
        return
      end
    end
    if #buffer < length then
      return
    end
    client:read_stop()
    local method, target = head:match("^(%u+)%s+(%S+)")
    local headers = {}
    for line in head:gmatch("[^\r\n]+") do
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if name then
        headers[name:lower()] = value
      end
    end
    local body = buffer:sub(1, length)
    -- Serving a call opens windows: not from libuv's fast context.
    vim.schedule(function()
      local ok, response = pcall(M.handle_http, { method = method, path = target, headers = headers, body = body })
      if not ok then
        logger.debug("opencode", "open_files endpoint failed:", tostring(response))
        response = http_response(500, "Internal Server Error")
      end
      finish(response)
    end)
  end)
end

---Start the endpoint, once per Neovim.
---@return integer|nil port
function M.start()
  if state.server then
    return state.port
  end
  local uv = vim.loop
  local server = uv.new_tcp()
  if not server then
    return nil
  end
  local ok_bind = pcall(function()
    assert(server:bind("127.0.0.1", 0))
    assert(server:listen(16, function(err)
      if err then
        return
      end
      local client = uv.new_tcp()
      if client and server:accept(client) then
        serve(client)
      elseif client then
        client:close()
      end
    end))
  end)
  local ok_name, name = pcall(server.getsockname, server)
  if not ok_bind or not ok_name or type(name) ~= "table" or not name.port then
    pcall(server.close, server)
    logger.warn("opencode", "could not start the open_files endpoint for OpenCode")
    return nil
  end
  state.server = server
  state.port = name.port
  state.token = hex(require("claude_agents.utils").random_bytes(16))
  return state.port
end

---Stop the endpoint (tests, plugin reload).
function M.stop()
  if state.server and not state.server:is_closing() then
    state.server:close()
  end
  state.server, state.port, state.token = nil, nil, nil
end

--------------------------------------------------------------------------------
-- Registration with the service
--------------------------------------------------------------------------------

---The server config the service is given.
---@return table|nil
function M.service_config()
  if not state.port then
    return nil
  end
  return {
    type = "remote",
    url = ("http://127.0.0.1:%d%s"):format(state.port, M.PATH),
    headers = { [M.TOKEN_HEADER] = state.token },
    oauth = false,
    codemode = false,
  }
end

---@param name string
---@return string
local function route(name)
  return "/api/experimental/mcp/" .. require("claude_agents.opencode.http").urlencode(name)
end

---Add this Neovim's server to a directory's set (replacing an older copy).
---@param dir string Canonical directory.
---@param cb fun(err: string|nil)|nil
function M.register(dir, cb)
  cb = cb or function() end
  if not M.enabled() or type(dir) ~= "string" or dir == "" then
    cb(nil)
    return
  end
  if not M.start() then
    cb("no endpoint")
    return
  end
  M._api.call("PUT", route(M.server_name()), {
    query = { ["location[directory]"] = dir },
    body = { config = M.service_config() },
  }, function(err)
    if err then
      logger.debug("opencode", "could not add the open_files server for " .. dir .. ":", err)
    else
      state.registered[dir] = true
    end
    cb(err)
  end)
end

---Add the server to a directory unless it is there and connected.
---@param dir string Canonical directory.
---@param cb fun(err: string|nil)|nil
function M.ensure_registered(dir, cb)
  cb = cb or function() end
  if not M.enabled() or type(dir) ~= "string" or dir == "" then
    cb(nil)
    return
  end
  M._api.call("GET", "/api/mcp", { query = { ["location[directory]"] = dir }, no_start = true }, function(err, data)
    if not err and type(data) == "table" then
      local name = M.server_name()
      for _, server in ipairs(data) do
        -- 2.0.30 answers `status = { status = "connected" }`.
        local status = type(server) == "table" and server.status or nil
        if type(status) == "table" then
          status = status.status
        end
        if type(server) == "table" and server.name == name and status == "connected" then
          state.registered[dir] = true
          cb(nil)
          return
        end
      end
    end
    M.register(dir, cb)
  end)
end

---The directories the plugin's sessions run in now.
---@return table<string, boolean>
local function live_dirs()
  local out = {}
  local bridge = require("claude_agents.opencode.bridge")
  for _, id in ipairs(bridge.roots()) do
    local entry = bridge.get(id)
    if entry and entry.cwd then
      out[require("claude_agents.opencode").canonical(entry.cwd)] = true
    end
  end
  return out
end

---The event stream (re)connected: the service may have restarted, and its
---runtime servers with it.
function M.resync()
  if not M.enabled() then
    return
  end
  for dir in pairs(live_dirs()) do
    M.ensure_registered(dir)
  end
end

---A location shut down (reload, eviction): its runtime servers went with it.
---Added again for a directory a launched session still runs in.
---@param location table|nil `{ directory }`
function M.location_shutdown(location)
  local dir = type(location) == "table" and location.directory or nil
  if type(dir) ~= "string" then
    return
  end
  state.registered[dir] = nil
  if live_dirs()[dir] then
    -- After the shutdown has finished, or the add lands on the dying location.
    vim.defer_fn(function()
      M.ensure_registered(dir)
    end, 1000)
  end
end

---A launched session started a turn: make sure the tool is there to call.
---@param cwd string|nil
function M.turn_started(cwd)
  if type(cwd) == "string" and M.enabled() then
    M.ensure_registered(require("claude_agents.opencode").canonical(cwd))
  end
end

---A launched session ended: when no other session of this Neovim runs in that
---directory, its server is taken off.
---@param cwd string|nil
function M.released(cwd)
  if type(cwd) ~= "string" then
    return
  end
  local dir = require("claude_agents.opencode").canonical(cwd)
  if not state.registered[dir] or live_dirs()[dir] then
    return
  end
  state.registered[dir] = nil
  M._api.call(
    "DELETE",
    route(M.server_name()),
    { query = { ["location[directory]"] = dir }, no_start = true },
    function() end
  )
end

---Neovim is exiting: take every registration off. Waited for briefly, since
---the process is about to end; one left behind only reads `failed` in OpenCode
---until its location is rebuilt.
---@param wait_ms integer|nil
function M.shutdown(wait_ms)
  local pending = 0
  for dir in pairs(state.registered) do
    pending = pending + 1
    local ok = pcall(M._api.call, "DELETE", route(M.server_name()), {
      query = { ["location[directory]"] = dir },
      no_start = true,
      timeout_ms = wait_ms or 300,
    }, function()
      pending = pending - 1
    end)
    if not ok then
      pending = pending - 1
    end
  end
  state.registered = {}
  if pending > 0 then
    vim.wait(wait_ms or 300, function()
      return pending <= 0
    end, 10)
  end
  M.stop()
end

---Registered directories (specs, health).
---@return table<string, boolean>
function M._registered()
  return state.registered
end

---Test helper: the endpoint's token.
---@return string|nil
function M._token()
  return state.token
end

--- Specs set a port and token without a socket.
M._state = state

---Test/reload helper.
function M._reset()
  M.stop()
  state.registered = {}
  state.id = nil
end

return M
