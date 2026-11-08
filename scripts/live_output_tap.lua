-- claudecode.nvim live-output tap (cross-platform).
--
-- Sits in a pipe the agent built, passing every byte through unchanged, and
-- tells the Neovim the agent runs in what came past: the agents view draws it
-- above the command's filtered output. Started by the shell functions in
-- `agents/live_output.lua`'s generated script, from a process substitution:
--
--   command cargo "$@" > >(nvim --headless -u NONE -i NONE -n -l <this> \
--                           <stream> <frame_ms> <lines> <keep> cargo <args…>)
--
-- `<stream>` is which of the command's streams come through here: `out`,
-- `both` (stdout and stderr shared one pipe, `2>&1`), or `err`.
--
-- Rules this file keeps, since a mistake here breaks the agent's command rather
-- than a view:
--
-- * Never print. Its stdout is the agent's pipe; its stderr goes to /dev/null.
-- * Never hold the pipe up. Neovim is told nothing it must answer while bytes
--   are flowing; a Neovim that is gone or busy costs nothing but the frames.
-- * Never outlive the reader: once the downstream end is closed (`| head -1`)
--   it stops reading, so the command gets SIGPIPE as it would have without us.
-- * Raw libuv handles on both ends. Lua's `io` would translate line ends on
--   Windows.

local uv = vim.uv or vim.loop
local argv = _G.arg or {}

local stream = argv[1] or "out"
local frame_ms = tonumber(argv[2]) or 250
local lines_running = tonumber(argv[3]) or 20
local lines_kept = tonumber(argv[4]) or 40
local name = argv[5] or "?"
local args = {}
for i = 6, math.min(#argv, 11) do
  local a = argv[i]
  args[#args + 1] = #a > 200 and a:sub(1, 200) or a
end

--- Bytes of output kept to cut the last lines from: room for the kept lines
--- at their full LINE_BYTES each.
local TAIL = 32 * 1024
--- A line is cut to this many bytes before it is sent.
local LINE_BYTES = 400
--- Stop reading while this much is queued for a slow reader.
local HIGH_WATER = 1024 * 1024
--- How long the goodbye may take before the process leaves anyway.
local BYE_MS = 1000

local function now()
  local s, us = uv.gettimeofday()
  return (s or os.time()) + (us or 0) / 1e6
end

local id = ("%d-%.0f"):format(uv.os_getpid(), uv.hrtime())

--------------------------------------------------------------------------------
-- The bytes
--------------------------------------------------------------------------------

local src = uv.new_pipe(false)
local dst
if uv.guess_handle(1) == "pipe" then
  dst = uv.new_pipe(false)
  if not dst:open(1) then
    dst = nil
  end
end
if not src:open(0) then
  -- Not a pipe after all (the wrappers only start us on one): copy and leave.
  while true do
    local data = uv.fs_read(0, 65536, -1)
    if not data or data == "" or not uv.fs_write(1, data, -1) then
      os.exit(0)
    end
  end
end

local tail, trimmed = "", false
local total_lines, bytes = 0, 0
local changed = false

local function keep(data)
  bytes = bytes + #data
  local at = 1
  while true do
    local nl = data:find("\n", at, true)
    if not nl then
      break
    end
    total_lines = total_lines + 1
    at = nl + 1
  end
  tail = tail .. data
  if #tail > 2 * TAIL then
    tail = tail:sub(-TAIL)
    trimmed = true
  end
  changed = true
end

---What a terminal would show of one line: the text after its last carriage
---return (a progress bar's redraw), CRLF being a line end and not a redraw.
---@param raw string
---@return string
local function collapse_cr(raw)
  raw = raw:gsub("\r+$", "")
  return raw:match("([^\r]*)$") or raw
end

---The last `count` lines of what came through, the unfinished one included.
---@param count integer
---@return string[] lines
---@return boolean partial The last line is still being written.
local function last_lines(count)
  local pieces = {}
  local at = 1
  while true do
    local nl = tail:find("\n", at, true)
    if not nl then
      break
    end
    pieces[#pieces + 1] = tail:sub(at, nl - 1)
    at = nl + 1
  end
  local rest = tail:sub(at)
  local partial = rest ~= ""
  if partial then
    pieces[#pieces + 1] = rest
  end
  -- A tail cut from a longer stream begins mid-line.
  if trimmed and #pieces > 1 then
    table.remove(pieces, 1)
  end
  local out = {}
  for i = math.max(1, #pieces - count + 1), #pieces do
    local line = collapse_cr(pieces[i])
    out[#out + 1] = #line > LINE_BYTES and line:sub(1, LINE_BYTES) or line
  end
  return out, partial
end

--------------------------------------------------------------------------------
-- Neovim
--------------------------------------------------------------------------------

local chan
local CODE = "local m = ... ; return require('claude_agents.agents.live_output').ingest(m)"

local function connect()
  local server = os.getenv("CLAUDECODE_NVIM_SERVER")
  if not server or server == "" then
    return
  end
  local kind = server:match("^%d[%d%.]*:%d+$") and "tcp" or "pipe"
  local ok, c = pcall(vim.fn.sockconnect, kind, server, { rpc = true })
  if ok and type(c) == "number" and c > 0 then
    chan = c
  end
end

---@param msg table
local function notify(msg)
  if not chan then
    return
  end
  if not pcall(vim.rpcnotify, chan, "nvim_exec_lua", CODE, { msg }) then
    chan = nil
  end
end

local function frame()
  if not changed or not chan then
    return
  end
  changed = false
  local lines, partial = last_lines(lines_running)
  notify({ ev = "frame", id = id, lines = lines, partial = partial, total = total_lines, bytes = bytes })
end

local finished = false
local function finish()
  if finished then
    return
  end
  finished = true
  -- The reader gets its end of file now, not after Neovim has answered.
  if dst and not dst:is_closing() then
    dst:close()
  end
  vim.schedule(function()
    if chan then
      local guard = uv.new_timer()
      guard:start(BYE_MS, 0, function()
        os.exit(0)
      end)
      local lines, partial = last_lines(lines_kept)
      local msg = { ev = "bye", id = id, lines = lines, partial = partial, total = total_lines, bytes = bytes }
      -- A request, so the goodbye is delivered before the process exits.
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", CODE, { msg })
    end
    os.exit(0)
  end)
end

local function drain_then_finish()
  if not dst or uv.stream_get_write_queue_size(dst) == 0 then
    return finish()
  end
  local t = uv.new_timer()
  t:start(1, 1, function()
    if dst:is_closing() or uv.stream_get_write_queue_size(dst) == 0 then
      t:stop()
      t:close()
      finish()
    end
  end)
end

local function stop_reading()
  if not src:is_closing() then
    src:read_stop()
    src:close()
  end
end

local function on_read(err, data)
  if finished then
    return
  end
  if err or not data then
    stop_reading()
    return drain_then_finish()
  end
  keep(data)
  if not dst then
    if not uv.fs_write(1, data, -1) then
      stop_reading()
      return finish()
    end
    return
  end
  dst:write(data, function(werr)
    -- The reader went away (`| head -1`): stop reading, so the command's next
    -- write fails the way it would have without the tap in between.
    if werr then
      stop_reading()
      finish()
    end
  end)
  if uv.stream_get_write_queue_size(dst) > HIGH_WATER then
    src:read_stop()
    local t = uv.new_timer()
    t:start(1, 1, function()
      if finished or src:is_closing() then
        t:stop()
        t:close()
      elseif uv.stream_get_write_queue_size(dst) < HIGH_WATER / 4 then
        t:stop()
        t:close()
        src:read_start(on_read)
      end
    end)
  end
end

-- Reading first: bytes flow whatever Neovim does.
src:read_start(on_read)

connect()
local cwd = uv.cwd()
notify({
  ev = "hello",
  id = id,
  name = name,
  args = args,
  stream = stream,
  session = os.getenv("CLAUDE_CODE_SESSION_ID") or "",
  agent = os.getenv("CLAUDECODE_AGENT_ID") or "",
  tab = tonumber((os.getenv("CLAUDECODE_NVIM_TAB") or ""):match("%d+") or "0") or 0,
  cwd = cwd,
  at = now(),
  pid = uv.os_getpid(),
})

if chan then
  local ticker = uv.new_timer()
  ticker:start(frame_ms, frame_ms, function()
    if finished then
      ticker:stop()
      return
    end
    -- Callbacks run in libuv's fast context, where RPC is off limits.
    vim.schedule(frame)
  end)
end

while true do
  vim.wait(1e9, function()
    return false
  end)
end
