---@brief [[
--- Finding OpenCode's shared background service, and starting it.
---
--- Every local OpenCode client connects to one service per user; it writes where
--- it listens to `<state>/service.json` (`{ id, version, url, pid, password }`),
--- and accepts HTTP Basic auth as user `opencode` with that password. `<state>`
--- is whatever `opencode debug paths state` prints — asked once, since that
--- command starts nothing — so a relocated XDG directory or another platform's
--- layout needs no rule of ours.
---
--- A user can switch the service off (`opencode service set disabled true`).
--- TUIs then run private servers nothing else can reach, and the plugin says so
--- rather than starting one behind their back: `ensure` only starts the shared
--- service when it is not disabled, which `opencode service start` itself
--- decides.
---@brief ]]
---@module 'claude_agents.opencode.service'

local http = require("claude_agents.opencode.http")
local logger = require("claude_agents.logger")

local M = {}

M.USER = "opencode"

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@class ClaudeCodeOpencodeConnection
---@field url string
---@field password string
---@field pid integer|nil
---@field version string|nil

local state = {
  state_dir = nil, ---@type string|nil
  conn = nil, ---@type ClaudeCodeOpencodeConnection|nil
  waiters = nil, ---@type (fun(err: string|nil, conn: ClaudeCodeOpencodeConnection|nil))[]|nil
}

--- Seams for specs.
M._system = function(argv, opts, on_exit)
  return vim.system(argv, opts or { text = true }, on_exit)
end
M._read_file = function(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end
M._http = http
M._defer = function(fn, ms)
  vim.defer_fn(fn, ms)
end

local function opencode()
  return require("claude_agents.opencode")
end

---Where OpenCode keeps its state, `service.json` among it.
---@return string
function M.state_dir()
  if state.state_dir then
    return state.state_dir
  end
  local argv = opencode().cmd_argv()
  argv[#argv + 1] = "debug"
  argv[#argv + 1] = "paths"
  argv[#argv + 1] = "state"
  local ok, res = pcall(function()
    return M._system(argv, { text = true }):wait(5000)
  end)
  local out = ok and type(res) == "table" and res.code == 0 and type(res.stdout) == "string" and res.stdout or nil
  local dir = out and trim(out) or ""
  if dir == "" then
    local xdg = os.getenv("XDG_STATE_HOME")
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "~"
    dir = ((xdg and xdg ~= "") and xdg or (home .. "/.local/state")) .. "/opencode"
    logger.debug("opencode", "could not ask OpenCode for its state directory; assuming", dir)
  end
  state.state_dir = dir
  return dir
end

---The service's registration, as written. No health check.
---@return ClaudeCodeOpencodeConnection|nil
---@return string|nil error
function M.read_registration()
  local path = M.state_dir() .. "/service.json"
  local data = M._read_file(path)
  if not data then
    return nil, "no OpenCode service is registered (" .. path .. ")"
  end
  local info = http.decode(data)
  if type(info) ~= "table" or type(info.url) ~= "string" or type(info.password) ~= "string" then
    return nil, "unreadable service registration at " .. path
  end
  return { url = info.url, password = info.password, pid = tonumber(info.pid), version = info.version }, nil
end

---The connection last found healthy, if any.
---@return ClaudeCodeOpencodeConnection|nil
function M.connection()
  return state.conn
end

---Forget the cached connection (the service restarted, or refused us).
function M.invalidate()
  state.conn = nil
end

---Ask a registration whether its service answers.
---@param conn ClaudeCodeOpencodeConnection
---@param cb fun(ok: boolean, err: string|nil)
local function probe(conn, cb)
  M._http.request({
    url = conn.url,
    path = "/api/info",
    auth = { user = M.USER, password = conn.password },
    timeout_ms = 2000,
  }, function(err, res)
    if err then
      cb(false, err)
    elseif res.status ~= 200 then
      cb(false, "HTTP " .. tostring(res.status))
    else
      cb(true, nil)
    end
  end)
end

local function settle(err, conn)
  local waiters = state.waiters or {}
  state.waiters = nil
  state.conn = conn
  for _, waiter in ipairs(waiters) do
    pcall(waiter, err, conn)
  end
end

---Poll the registration until it answers or the deadline passes.
---@param deadline number `vim.loop.now()` milliseconds.
local function wait_for_service(deadline)
  local conn = M.read_registration()
  local function retry(last_err)
    if (vim.uv or vim.loop).now() >= deadline then
      settle("the OpenCode service did not come up: " .. tostring(last_err), nil)
      return
    end
    M._defer(function()
      wait_for_service(deadline)
    end, 250)
  end
  if not conn then
    retry("no registration yet")
    return
  end
  probe(conn, function(ok, err)
    if ok then
      settle(nil, conn)
    else
      retry(err)
    end
  end)
end

---A healthy connection to the service, starting it when none answers.
---Concurrent callers share one attempt.
---@param cb fun(err: string|nil, conn: ClaudeCodeOpencodeConnection|nil)
function M.ensure(cb)
  if state.conn then
    cb(nil, state.conn)
    return
  end
  if state.waiters then
    table.insert(state.waiters, cb)
    return
  end
  state.waiters = { cb }

  local conn = M.read_registration()
  local function start()
    local argv = opencode().cmd_argv()
    argv[#argv + 1] = "service"
    argv[#argv + 1] = "start"
    logger.debug("opencode", "starting the OpenCode service:", table.concat(argv, " "))
    local timeout = tonumber(opencode().config().service_timeout_ms) or 15000
    local deadline = (vim.uv or vim.loop).now() + timeout
    local ok, err = pcall(M._system, argv, { text = true }, function(res)
      vim.schedule(function()
        if type(res) == "table" and res.code ~= 0 then
          local detail = trim((res.stderr or "") .. " " .. (res.stdout or ""))
          settle("`" .. table.concat(argv, " ") .. "` failed" .. (detail ~= "" and (": " .. detail) or ""), nil)
          return
        end
        wait_for_service(deadline)
      end)
    end)
    if not ok then
      settle("could not run " .. table.concat(argv, " ") .. ": " .. tostring(err), nil)
    end
  end

  if not conn then
    start()
    return
  end
  probe(conn, function(ok)
    if ok then
      settle(nil, conn)
    else
      start()
    end
  end)
end

---A healthy connection if the service is already up; never starts it. What
---browsing uses (the agents view listing OpenCode sessions beside Claude's), so
---that merely having OpenCode installed starts nothing behind the user's back.
---@param cb fun(err: string|nil, conn: ClaudeCodeOpencodeConnection|nil)
function M.find(cb)
  if state.conn then
    cb(nil, state.conn)
    return
  end
  if state.waiters then
    -- A start is under way; its answer is this one's too.
    table.insert(state.waiters, cb)
    return
  end
  local conn, err = M.read_registration()
  if not conn then
    cb(err, nil)
    return
  end
  probe(conn, function(ok, probe_err)
    if ok then
      state.conn = conn
      cb(nil, conn)
    else
      cb("the OpenCode service is not running (" .. tostring(probe_err) .. ")", nil)
    end
  end)
end

---`ensure`, waited for. For the launch path, which builds a command in one tick.
---@param timeout_ms integer|nil
---@return string|nil err
---@return ClaudeCodeOpencodeConnection|nil conn
function M.ensure_sync(timeout_ms)
  if state.conn then
    return nil, state.conn
  end
  timeout_ms = timeout_ms or (tonumber(opencode().config().service_timeout_ms) or 15000)
  local done, result_err, result = false, nil, nil
  M.ensure(function(err, conn)
    done, result_err, result = true, err, conn
  end)
  vim.wait(timeout_ms + 500, function()
    return done
  end, 10)
  if not done then
    return "timed out waiting for the OpenCode service", nil
  end
  return result_err, result
end

---Test/reload helper.
function M._reset()
  state = { state_dir = nil, conn = nil, waiters = nil }
end

return M
