---@brief [[
--- A small HTTP/1.1 client on `vim.loop`, for the OpenCode service's loopback API.
---
--- The service listens on 127.0.0.1 (its `service.json` says where), so this
--- needs no TLS and no proxy handling: JSON requests with HTTP Basic auth, and
--- one long-lived server-sent-events stream (`GET /api/event`). Pure Lua for the
--- same reason the WebSocket server is: nothing to install, and Windows behaves
--- like everything else.
---
--- Every request is `Connection: close`, so a response ends at EOF when it says
--- neither a `Content-Length` nor `chunked`. Callbacks run on the main loop.
---@brief ]]
---@module 'claude_agents.opencode.http'

local M = {}

local function uv()
  return vim.uv or vim.loop
end

--------------------------------------------------------------------------------
-- Pure helpers (no I/O)
--------------------------------------------------------------------------------

---Split a base URL into the parts a socket needs.
---@param url string e.g. `http://127.0.0.1:49374`
---@return { host: string, port: integer, prefix: string }|nil
function M.parse_url(url)
  if type(url) ~= "string" then
    return nil
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
  if scheme ~= "http" or not rest then
    return nil
  end
  local authority, path = rest:match("^([^/]+)(.*)$")
  if not authority then
    return nil
  end
  local host, port = authority:match("^%[(.+)%]:(%d+)$")
  if not host then
    host, port = authority:match("^([^:]+):(%d+)$")
  end
  if not host then
    host, port = authority, "80"
  end
  local prefix = (path or ""):gsub("/+$", "")
  return { host = host, port = tonumber(port), prefix = prefix }
end

---Percent-encode one query component.
---@param value string
---@return string
function M.urlencode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

---A query string from a table of parameters, `?`-prefixed; "" when empty.
---Keys are sorted so a request is the same string every time it is built.
---@param params table<string, string|number|boolean>|nil
---@return string
function M.query(params)
  if type(params) ~= "table" then
    return ""
  end
  local keys = {}
  for key, value in pairs(params) do
    if value ~= nil then
      keys[#keys + 1] = key
    end
  end
  if #keys == 0 then
    return ""
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = M.urlencode(key) .. "=" .. M.urlencode(tostring(params[key]))
  end
  return "?" .. table.concat(parts, "&")
end

---The `Authorization` header value for HTTP Basic auth.
---@param user string
---@param password string
---@return string
function M.basic_auth(user, password)
  local raw = tostring(user) .. ":" .. tostring(password)
  local encode = vim.base64 and vim.base64.encode
  if not encode then
    encode = require("claude_agents.server.utils").base64_encode
  end
  return "Basic " .. encode(raw)
end

---Encode a request body. Tables become JSON; an empty table is sent as `{}`,
---which is what every endpoint here means by "no options".
---@param body string|table|nil
---@return string|nil body
---@return string|nil content_type
function M.encode_body(body)
  if body == nil then
    return nil, nil
  end
  if type(body) == "string" then
    return body, "application/json"
  end
  if next(body) == nil then
    return "{}", "application/json"
  end
  return vim.json.encode(body), "application/json"
end

---The bytes of one request.
---@param opts { method: string, host: string, port: integer, path: string, headers: table<string,string>|nil, body: string|nil }
---@return string
function M.build_request(opts)
  local lines = {
    string.format("%s %s HTTP/1.1", opts.method, opts.path),
    string.format("Host: %s:%d", opts.host, opts.port),
    "Connection: close",
  }
  local headers = opts.headers or {}
  local names = {}
  for name in pairs(headers) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. ": " .. headers[name]
  end
  if opts.body then
    lines[#lines + 1] = "Content-Length: " .. #opts.body
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (opts.body or "")
end

---Parse a response head (status line and headers).
---@param head string Everything before the blank line.
---@return integer|nil status
---@return table<string, string> headers Lower-cased names.
function M.parse_head(head)
  local status = tonumber(head:match("^HTTP/%d%.%d (%d%d%d)"))
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return status, headers
end

---An incremental decoder for `Transfer-Encoding: chunked`.
---@return fun(data: string): string, boolean, string|nil feed Returns the decoded bytes so far, whether the last chunk was read, and an error.
function M.dechunker()
  local buffer = ""
  local phase = "size" -- "size" | "data" | "crlf" | "done"
  local remaining = 0
  return function(data)
    buffer = buffer .. data
    local out = {}
    while phase ~= "done" do
      if phase == "size" then
        local line_end = buffer:find("\r\n", 1, true)
        if not line_end then
          break
        end
        local hex = buffer:sub(1, line_end - 1):match("^%s*(%x+)")
        local size = hex and tonumber(hex, 16)
        if not size then
          return table.concat(out), false, "bad chunk size"
        end
        buffer = buffer:sub(line_end + 2)
        if size == 0 then
          phase = "done"
        else
          phase, remaining = "data", size
        end
      elseif phase == "data" then
        if buffer == "" then
          break
        end
        local take = math.min(remaining, #buffer)
        out[#out + 1] = buffer:sub(1, take)
        buffer = buffer:sub(take + 1)
        remaining = remaining - take
        if remaining == 0 then
          phase = "crlf"
        end
      else
        if #buffer < 2 then
          break
        end
        buffer = buffer:sub(3)
        phase = "size"
      end
    end
    return table.concat(out), phase == "done", nil
  end
end

---An incremental parser for a `text/event-stream` body.
---@param on_event fun(event: { event: string|nil, data: string, id: string|nil })
---@return fun(data: string) feed
function M.sse_parser(on_event)
  local buffer = ""
  local data_lines, event_name, event_id = {}, nil, nil
  local function dispatch()
    if #data_lines > 0 then
      on_event({ event = event_name, data = table.concat(data_lines, "\n"), id = event_id })
    end
    data_lines, event_name, event_id = {}, nil, nil
  end
  return function(data)
    buffer = buffer .. data
    while true do
      local line_end = buffer:find("\n", 1, true)
      if not line_end then
        break
      end
      local line = buffer:sub(1, line_end - 1):gsub("\r$", "")
      buffer = buffer:sub(line_end + 1)
      if line == "" then
        dispatch()
      elseif line:sub(1, 1) ~= ":" then
        local field, value = line:match("^([^:]*):?(.*)$")
        value = value:gsub("^ ", "")
        if field == "data" then
          data_lines[#data_lines + 1] = value
        elseif field == "event" then
          event_name = value
        elseif field == "id" then
          event_id = value
        end
      end
    end
  end
end

---Decode a JSON body, `null`s as nil. Answers nil for anything that is not JSON.
---@param body string|nil
---@return any
function M.decode(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    ok, value = pcall(vim.json.decode, body)
  end
  if not ok then
    return nil
  end
  return value
end

--------------------------------------------------------------------------------
-- Sockets
--------------------------------------------------------------------------------

---A numeric address for `host`; "localhost" and other names go through the resolver.
---@param host string
---@return string|nil
local function resolve(host)
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
    return host
  end
  local ok, infos = pcall(uv().getaddrinfo, host, nil, { family = "inet", socktype = "stream" })
  if ok and type(infos) == "table" and infos[1] and infos[1].addr then
    return infos[1].addr
  end
  return nil
end

--- Injectable so specs can drive requests without a socket.
M._connect = function(host, port, on_connect)
  local tcp = uv().new_tcp()
  if not tcp then
    on_connect("could not create a socket")
    return nil
  end
  local addr = resolve(host)
  if not addr then
    pcall(tcp.close, tcp)
    on_connect("could not resolve " .. host)
    return nil
  end
  local ok, err = pcall(tcp.connect, tcp, addr, port, function(connect_err)
    on_connect(connect_err)
  end)
  if not ok then
    pcall(tcp.close, tcp)
    on_connect(tostring(err))
    return nil
  end
  return tcp
end

---@class ClaudeCodeHttpOptions
---@field url string Base URL of the server.
---@field method string|nil Default "GET".
---@field path string Request path, starting with `/`.
---@field query table|nil Query parameters.
---@field headers table<string,string>|nil
---@field body string|table|nil
---@field auth { user: string, password: string }|nil
---@field timeout_ms integer|nil Default 10000; 0 disables (streams).

---@param opts ClaudeCodeHttpOptions
---@return { host: string, port: integer, bytes: string }|nil
---@return string|nil error
local function prepare(opts, extra_headers)
  local target = M.parse_url(opts.url)
  if not target then
    return nil, "not an http URL: " .. tostring(opts.url)
  end
  local body, content_type = M.encode_body(opts.body)
  local headers = {}
  for name, value in pairs(opts.headers or {}) do
    headers[name] = value
  end
  for name, value in pairs(extra_headers or {}) do
    headers[name] = value
  end
  if content_type and not headers["Content-Type"] then
    headers["Content-Type"] = content_type
  end
  if opts.auth then
    headers["Authorization"] = M.basic_auth(opts.auth.user, opts.auth.password)
  end
  local bytes = M.build_request({
    method = opts.method or "GET",
    host = target.host,
    port = target.port,
    path = target.prefix .. opts.path .. M.query(opts.query),
    headers = headers,
    body = body,
  })
  return { host = target.host, port = target.port, bytes = bytes }, nil
end

---@class ClaudeCodeHttpResponse
---@field status integer
---@field headers table<string, string>
---@field body string
---@field json any The decoded body, when it is JSON.

---Send one request; `cb(err, response)` on the main loop.
---@param opts ClaudeCodeHttpOptions
---@param cb fun(err: string|nil, res: ClaudeCodeHttpResponse|nil)
function M.request(opts, cb)
  local prepared, prep_err = prepare(opts, { Accept = "application/json" })
  if not prepared then
    vim.schedule(function()
      cb(prep_err, nil)
    end)
    return
  end

  local done = false
  local tcp, timer
  local function finish(err, res)
    if done then
      return
    end
    done = true
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
    end
    if tcp then
      pcall(tcp.read_stop, tcp)
      if not tcp:is_closing() then
        pcall(tcp.close, tcp)
      end
    end
    vim.schedule(function()
      cb(err, res)
    end)
  end

  local timeout = opts.timeout_ms == nil and 10000 or opts.timeout_ms
  if timeout > 0 then
    timer = uv().new_timer()
    if timer then
      timer:start(timeout, 0, function()
        finish("timed out after " .. timeout .. " ms", nil)
      end)
    end
  end

  local raw, head_done, status, headers = "", false, nil, nil
  local body_parts, body_len, length, chunked = {}, 0, nil, nil
  local function complete()
    local body = table.concat(body_parts)
    finish(nil, { status = status, headers = headers, body = body, json = M.decode(body) })
  end

  tcp = M._connect(prepared.host, prepared.port, function(connect_err)
    if connect_err then
      finish("could not connect: " .. tostring(connect_err), nil)
      return
    end
    tcp:write(prepared.bytes)
    tcp:read_start(function(read_err, data)
      if read_err then
        finish("read failed: " .. tostring(read_err), nil)
        return
      end
      if not data then
        if head_done then
          complete()
        else
          finish("connection closed before a response", nil)
        end
        return
      end
      if not head_done then
        raw = raw .. data
        local head_end = raw:find("\r\n\r\n", 1, true)
        if not head_end then
          return
        end
        status, headers = M.parse_head(raw:sub(1, head_end - 1))
        head_done = true
        data = raw:sub(head_end + 4)
        raw = nil
        if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
          chunked = M.dechunker()
        else
          length = tonumber(headers["content-length"])
        end
      end
      if chunked then
        local out, finished, err = chunked(data)
        if err then
          finish(err, nil)
          return
        end
        body_parts[#body_parts + 1] = out
        if finished then
          complete()
        end
        return
      end
      body_parts[#body_parts + 1] = data
      body_len = body_len + #data
      if length and body_len >= length then
        complete()
      elseif status == 204 or status == 304 then
        complete()
      end
    end)
  end)
end

---Send one request and wait for its answer, for the few callers that must have
---it in the tick they ask (a launch building its command). Never from a fast
---context.
---@param opts ClaudeCodeHttpOptions
---@param timeout_ms integer|nil Default 3000.
---@return string|nil err
---@return ClaudeCodeHttpResponse|nil res
function M.request_sync(opts, timeout_ms)
  timeout_ms = timeout_ms or 3000
  local finished, result_err, result = false, nil, nil
  opts = vim.tbl_extend("force", opts, { timeout_ms = timeout_ms })
  M.request(opts, function(err, res)
    finished, result_err, result = true, err, res
  end)
  local ok = vim.wait(timeout_ms + 200, function()
    return finished
  end, 5)
  if not ok and not finished then
    return "timed out after " .. timeout_ms .. " ms", nil
  end
  return result_err, result
end

---@class ClaudeCodeHttpStream
---@field close fun()

---Open a server-sent-events stream. Handlers run on the main loop.
---@param opts ClaudeCodeHttpOptions
---@param handlers { on_open: fun(status: integer, headers: table)|nil, on_event: fun(event: { event: string|nil, data: string, id: string|nil }), on_close: fun(err: string|nil)|nil }
---@return ClaudeCodeHttpStream
function M.stream(opts, handlers)
  local closed = false
  local tcp
  local handle = {}
  local function close(err)
    if closed then
      return
    end
    closed = true
    if tcp then
      pcall(tcp.read_stop, tcp)
      if not tcp:is_closing() then
        pcall(tcp.close, tcp)
      end
    end
    if handlers.on_close then
      vim.schedule(function()
        handlers.on_close(err)
      end)
    end
  end
  handle.close = function()
    -- A deliberate close is not an error, and its owner needs no callback.
    handlers = { on_event = function() end }
    close(nil)
  end

  local prepared, prep_err = prepare(opts, { Accept = "text/event-stream", ["Cache-Control"] = "no-cache" })
  if not prepared then
    close(prep_err)
    return handle
  end

  local raw, head_done, chunked = "", false, nil
  local parse = M.sse_parser(function(event)
    vim.schedule(function()
      if not closed then
        handlers.on_event(event)
      end
    end)
  end)

  tcp = M._connect(prepared.host, prepared.port, function(connect_err)
    if connect_err then
      close("could not connect: " .. tostring(connect_err))
      return
    end
    tcp:write(prepared.bytes)
    tcp:read_start(function(read_err, data)
      if read_err then
        close("read failed: " .. tostring(read_err))
        return
      end
      if not data then
        close("stream ended")
        return
      end
      if not head_done then
        raw = raw .. data
        local head_end = raw:find("\r\n\r\n", 1, true)
        if not head_end then
          return
        end
        local status, headers = M.parse_head(raw:sub(1, head_end - 1))
        head_done = true
        data = raw:sub(head_end + 4)
        raw = nil
        if status ~= 200 then
          close("HTTP " .. tostring(status))
          return
        end
        if handlers.on_open then
          vim.schedule(function()
            handlers.on_open(status, headers)
          end)
        end
        if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
          chunked = M.dechunker()
        end
      end
      if chunked then
        local out, finished, err = chunked(data)
        if err then
          close(err)
          return
        end
        parse(out)
        if finished then
          close("stream ended")
        end
      else
        parse(data)
      end
    end)
  end)
  return handle
end

return M
