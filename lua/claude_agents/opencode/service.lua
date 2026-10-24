---@brief [[
--- Finding OpenCode's shared background service, and starting it.
---
--- Every local OpenCode client connects to one service per user; it writes where
--- it listens to `<state>/service.json` (`{ id, version, url, pid, password }`),
--- and accepts HTTP Basic auth as user `opencode` with that password. `<state>`
--- is looked for at the standard place first (`$XDG_STATE_HOME/opencode`, else
--- `~/.local/state/opencode`), where a live registration settles it without
--- running anything. Only when nothing there answers is OpenCode asked (`opencode
--- debug paths state`, which starts nothing; once, without blocking), so a
--- relocated directory or another platform's layout needs no rule of ours, and a
--- stale `service.json` at the standard place does not hide the real one.
---
--- A user can switch the service off (`opencode service set disabled true`).
--- TUIs then run private servers nothing else can reach, and the plugin says so
--- rather than starting one behind their back: `ensure` asks `opencode service
--- get disabled` before it starts anything, because `opencode service start`
--- itself ignores the setting (2.0.30), and answers `DISABLED_ERR` instead.
---@brief ]]
---@module 'claude_agents.opencode.service'

local http = require("claude_agents.opencode.http")
local logger = require("claude_agents.logger")

local M = {}

M.USER = "opencode"

--- What `ensure` answers for a service the user switched off; compared by
--- callers that tell "switched off" from "failed to start".
M.DISABLED_ERR =
  "OpenCode's service is switched off (`opencode service set disabled true`); `opencode service unset disabled` switches it back on"

---@class ClaudeCodeOpencodeConnection
---@field url string
---@field password string
---@field pid integer|nil
---@field version string|nil

local state = {
  state_dir = nil, ---@type string|nil
  asking = nil, ---@type (fun(dir: string))[]|nil
  conn = nil, ---@type ClaudeCodeOpencodeConnection|nil
  waiters = nil, ---@type (fun(err: string|nil, conn: ClaudeCodeOpencodeConnection|nil))[]|nil
}

--- Seams for specs.
M._system = function(argv, opts, on_exit)
  return vim.system(argv, opts or { text = true }, on_exit)
end
M._read_file = require("claude_agents.store_io").read
M._http = http
M._defer = function(fn, ms)
  vim.defer_fn(fn, ms)
end

local function opencode()
  return require("claude_agents.opencode")
end

---Where OpenCode keeps its state unless told otherwise: the XDG layout it uses,
---under the user's profile where there is no `$HOME` (Windows). Anywhere else is
---found by asking it.
---@return string
function M.standard_state_dir()
  local xdg = os.getenv("XDG_STATE_HOME")
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "~"
  return ((xdg and xdg ~= "") and xdg or (home .. "/.local/state")) .. "/opencode"
end

---Take OpenCode's answer to `debug paths state` as the state directory.
---@param res table|nil `vim.system`'s result.
---@return string
local function answered(res)
  local out = type(res) == "table" and res.code == 0 and type(res.stdout) == "string" and res.stdout or nil
  local dir = out and vim.trim(out) or ""
  if dir == "" then
    dir = M.standard_state_dir()
    logger.debug("opencode", "could not ask OpenCode for its state directory; assuming", dir)
  end
  state.state_dir = dir
  return dir
end

local function paths_argv()
  local argv = opencode().cmd_argv()
  argv[#argv + 1] = "debug"
  argv[#argv + 1] = "paths"
  argv[#argv + 1] = "state"
  return argv
end

---Ask OpenCode where its state directory is, without blocking. Concurrent
---callers share one question.
---@param cb fun(dir: string)
local function ask_state_dir(cb)
  if state.asking then
    table.insert(state.asking, cb)
    return
  end
  state.asking = { cb }
  local function done(res)
    local dir = answered(res)
    local waiters = state.asking or {}
    state.asking = nil
    for _, waiter in ipairs(waiters) do
      pcall(waiter, dir)
    end
  end
  local ok = pcall(M._system, paths_argv(), { text = true }, function(res)
    vim.schedule(function()
      done(res)
    end)
  end)
  if not ok then
    done(nil)
  end
end

---Where OpenCode keeps its state, `service.json` among it. Waits for OpenCode's
---answer when it has not been asked yet (`:checkhealth`); the service lookups
---below never do.
---@return string
function M.state_dir()
  if state.state_dir then
    return state.state_dir
  end
  local ok, res = pcall(function()
    return M._system(paths_argv(), { text = true }):wait(5000)
  end)
  return answered(ok and res or nil)
end

---The registration in `dir`, as written. No health check.
---@param dir string
---@return ClaudeCodeOpencodeConnection|nil
---@return string|nil error
local function registration_in(dir)
  local path = dir .. "/service.json"
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

---The service's registration, as written. No health check.
---@return ClaudeCodeOpencodeConnection|nil
---@return string|nil error
function M.read_registration()
  return registration_in(M.state_dir())
end

local function disabled_argv()
  local argv = opencode().cmd_argv()
  argv[#argv + 1] = "service"
  argv[#argv + 1] = "get"
  argv[#argv + 1] = "disabled"
  return argv
end

---Read `opencode service get disabled`'s answer: it prints `true` or `false`.
---@param res table|nil `vim.system`'s result.
---@return boolean|nil off nil when OpenCode could not be asked (an older one without `service get`).
local function disabled_answer(res)
  if type(res) ~= "table" or res.code ~= 0 or type(res.stdout) ~= "string" then
    return nil
  end
  return vim.trim(res.stdout) == "true"
end

---Whether the user switched the shared service off, without blocking. nil when
---OpenCode could not be asked, which callers take as "not switched off".
---@param cb fun(off: boolean|nil)
function M.disabled(cb)
  local ok = pcall(M._system, disabled_argv(), { text = true }, function(res)
    vim.schedule(function()
      cb(disabled_answer(res))
    end)
  end)
  if not ok then
    cb(nil)
  end
end

---`disabled`, waiting for the answer (`:checkhealth`).
---@param timeout_ms integer
---@return boolean|nil off
function M.disabled_sync(timeout_ms)
  local ok, res = pcall(function()
    return M._system(disabled_argv(), { text = true }):wait(timeout_ms)
  end)
  return disabled_answer(ok and res or nil)
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

---Find the registration and ask whether it answers, without blocking: the known
---state directory, else the standard one, and only when nothing answers there
---the one OpenCode names. Whatever answers settles the directory.
---@param cb fun(conn: ClaudeCodeOpencodeConnection|nil, err: string|nil, alive: boolean)
---       `conn`: the registration last read (dead unless `alive`).
local function lookup(cb)
  local function try(dir, on_dead)
    local conn, err = registration_in(dir)
    if not conn then
      on_dead(nil, err)
      return
    end
    probe(conn, function(ok, probe_err)
      if ok then
        state.state_dir = dir
        cb(conn, nil, true)
      else
        on_dead(conn, probe_err)
      end
    end)
  end
  local function dead(conn, err)
    cb(conn, err, false)
  end
  if state.state_dir then
    try(state.state_dir, dead)
    return
  end
  local standard = M.standard_state_dir()
  try(standard, function(standard_conn, standard_err)
    ask_state_dir(function(dir)
      if dir == standard then
        dead(standard_conn, standard_err)
      else
        try(dir, dead)
      end
    end)
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

  local function start()
    local argv = opencode().cmd_argv()
    argv[#argv + 1] = "service"
    argv[#argv + 1] = "start"
    logger.debug("opencode", "starting the OpenCode service:", table.concat(argv, " "))
    local timeout = opencode().config().service_timeout_ms
    local deadline = (vim.uv or vim.loop).now() + timeout
    local ok, err = pcall(M._system, argv, { text = true }, function(res)
      vim.schedule(function()
        if type(res) == "table" and res.code ~= 0 then
          local detail = vim.trim((res.stderr or "") .. " " .. (res.stdout or ""))
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

  -- A lookup that finds nothing alive has settled the state directory, so the
  -- wait for the started service reads its registration without asking again.
  lookup(function(conn, _, alive)
    if alive then
      settle(nil, conn)
      return
    end
    M.disabled(function(off)
      if off then
        settle(M.DISABLED_ERR, nil)
      else
        start()
      end
    end)
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
  lookup(function(conn, err, alive)
    if alive then
      state.conn = conn
      cb(nil, conn)
    elseif conn then
      cb("the OpenCode service is not running (" .. tostring(err) .. ")", nil)
    else
      cb(err, nil)
    end
  end)
end

---Test/reload helper.
function M._reset()
  state = { state_dir = nil, asking = nil, conn = nil, waiters = nil }
end

return M
