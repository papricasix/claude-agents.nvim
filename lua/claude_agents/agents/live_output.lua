---@brief [[
--- What a command printed before the agent's pipe got to it.
---
--- An agent runs `cargo test 2>&1 | grep FAIL`, and the CLI keeps only what grep
--- let through (`tasks/<id>.output`, which `shell_view` follows). This module puts
--- a small process into that pipe, in front of the filter, so the views can show
--- the last lines cargo itself printed while it runs — without the agent's
--- command changing and without anything written to disk.
---
--- **How it gets there.** A launch sets `CLAUDE_ENV_FILE`: the CLI runs that
--- file's text ahead of every Bash command (2.1.319). It defines one shell
--- function per listed command (`cargo() { __claudecode_tap cargo "$@"; }`), and
--- the function runs the real command itself, as the shell would have — lookup,
--- quoting, exit status and environment unchanged. Only a stream that is piped
--- gets the tap (`[ -p /dev/stdout ]`, a builtin): an unpiped command's output
--- already reaches the CLI's file whole, and a piped one's stderr does unless
--- `2>&1` put it in the same pipe, in which case one tap carries both and keeps
--- their order. The tap is `scripts/live_output_tap.lua` under a headless Neovim
--- (~12 ms to start, ~11 MB, no CPU while waiting).
---
--- **The env file's text is pasted into an `&&` chain** ahead of the command, its
--- last line followed by ` :`. That line must succeed or the agent's command does
--- not run, so it is `[ … ] || [ ! -r file ] || . file`, and the sourced file ends
--- in `:`. Anything that is not bash or zsh skips it.
---
--- **Which call a tap belongs to.** The CLI gives a command no tool-call id, so a
--- tap's `hello` (conversation id, command name, arrival) is matched to a pending
--- `Bash` or `Monitor` call of that conversation whose command names the program:
--- the newest one noted before the tap arrived, else the first noted after it
--- (hooks are separate processes and can arrive after the tap). Calls are noted
--- from hooks and, where hooks are off, from the transcript when a view asks.
---
--- **Not covered**: the PowerShell tool. The only way into a `-NoProfile`
--- PowerShell is a shim on PATH, and a `.ps1` or `.cmd` shim changes the
--- arguments it forwards (`--` is dropped for scripts; cmd.exe reads `^` and
--- `&`). Commands run by path (`./gradlew`), or through `xargs`/`env`, are not
--- shell function calls and run untapped.
---@brief ]]
---@module 'claude_agents.agents.live_output'

local logger = require("claude_agents.logger")

local M = {}

--- The commands tapped when `agents.live_output.commands` is unset.
M.DEFAULT_COMMANDS = {
  "cargo",
  "go",
  "make",
  "cmake",
  "ninja",
  "npm",
  "pnpm",
  "yarn",
  "bun",
  "npx",
  "pytest",
  "uv",
  "mise",
  "gradle",
  "mvn",
  "dotnet",
  "swift",
  "xcodebuild",
  "docker",
  "busted",
  "jest",
  "vitest",
  "tsc",
  "zig",
}

--- Defaults owned here, like `fade`'s: `config.defaults` carries no copy.
local DEFAULTS = {
  enabled = true,
  commands = nil, -- nil: DEFAULT_COMMANDS
  lines = 20, -- lines shown while the command runs
  keep = 40, -- lines kept once it has ended
  ticker = true, -- the last line beside a running command's Activity row
  frame_ms = 250, -- how often a tap reports, at most
}

--- A command name that is safe as a shell function name and in a script.
M.NAME_PATTERN = "^[%w][%w._-]*$"

--- Taps kept, running and ended. Beyond it the oldest ended ones go.
local MAX_TAPS = 200
--- How long a tap that found no call keeps looking for one, in seconds.
local BIND_WINDOW_S = 30
--- How long a call nobody tapped is remembered, in seconds.
local CALL_TTL_S = 6 * 3600

local agents_on = false
local opts = vim.deepcopy(DEFAULTS)

local state = {
  taps = {}, ---@type table<string, table>
  order = {}, ---@type string[] tap ids, oldest first
  calls = {}, ---@type table<string, table> tool_use_id -> call
  listeners = {}, ---@type table<string, fun(changed: table<string, boolean>)>
  pending = nil, ---@type table<string, boolean>|nil tool ids changed since the last emit
  dir = nil, ---@type string|nil
  files = {}, ---@type table<string, string> content key -> env file path
}

--- Injectable clock: wall seconds with a fraction.
M._now = function()
  local uv = vim.uv or vim.loop
  if uv and uv.gettimeofday then
    local s, us = uv.gettimeofday()
    if s then
      return s + (us or 0) / 1e6
    end
  end
  return os.time()
end

--- Injectable: how listeners are called later (specs run them at once).
M._defer = function(fn)
  vim.defer_fn(fn, 50)
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

---@param full_config table|nil The whole plugin config.
function M.setup(full_config)
  local agents = type(full_config) == "table" and full_config.agents or nil
  agents_on = type(agents) == "table" and agents.enabled == true
  local own = nil -- not `x and x.live_output or nil`, which reads `false` as unset
  if type(agents) == "table" then
    own = agents.live_output
  end
  opts = vim.deepcopy(DEFAULTS)
  if own == false then
    opts.enabled = false
  elseif type(own) == "table" then
    for key, value in pairs(own) do
      opts[key] = value
    end
  end
end

---@return boolean
function M.is_enabled()
  if vim.fn.has("win32") == 1 and not M._windows then
    return false
  end
  return agents_on and opts.enabled ~= false
end

--- Native Windows stays off until `tests/nvim/live_output_check.lua` has passed
--- under Git Bash with the `tee` design; the check turns it on for itself.
M._windows = false

--- Which shell functions to write: `"direct"` (the tap is in the pipe) or
--- `"tee"` (msys `tee` is, and hands the tap a copy). nil picks `"tee"` on
--- Windows and `"direct"` elsewhere.
---@type "direct"|"tee"|nil
M._design = nil

---@return "direct"|"tee"
function M.design()
  return M._design or (vim.fn.has("win32") == 1 and "tee" or "direct")
end

---@return table
function M.opts()
  return opts
end

---@return string[]
function M.commands()
  local list = type(opts.commands) == "table" and opts.commands or M.DEFAULT_COMMANDS
  local out, seen = {}, {}
  for _, name in ipairs(list) do
    if type(name) == "string" and name:match(M.NAME_PATTERN) and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- What a launch carries
--------------------------------------------------------------------------------

---A path as a POSIX shell reads it: forward slashes, which Git Bash takes for a
---Windows path as well (`C:/Program Files/…`).
---@param path string
---@return string
function M.sh_path(path)
  if vim.fn.has("win32") == 1 then
    path = path:gsub("\\", "/")
  end
  return path
end

---@param text string
---@return string
local function sh_quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

---Absolute path of the shipped tap script.
---@return string
function M.tap_script()
  local src = debug.getinfo(1, "S").source or ""
  local file = src:gsub("^@", "")
  local root = file:gsub("[/\\]lua[/\\]claude_agents[/\\]agents[/\\]live_output%.lua$", "")
  return root .. "/scripts/live_output_tap.lua"
end

---The shell functions, as the script that defines them.
---
---bash and zsh only (both are what the CLI runs commands in); the env file
---sources this only when one of them is reading it, since the process
---substitutions below are a syntax error to anything else. A command the user
---already defines as a function or alias is left to theirs.
---
---Two designs (`M.design`):
---
--- * `direct`: the tap sits in the pipe and passes the bytes on. When the reader
---   quits early (`| head -1`) the tap's next write fails, it stops reading, and
---   the command's next write fails in turn.
--- * `tee` (Git Bash): under the msys runtime every Cygwin process holding a
---   pipe's write end also holds a handle on its read end, so a native writer
---   (the tap is `nvim.exe`) is never told that the reader has gone while the
---   function's own bash still holds that pipe — and it holds the pipe the
---   function writes to for as long as the command runs. Cygwin's own programs
---   are told. So msys `tee` is the writer into the agent's pipe and the tap only
---   reads its copy (`:sink`); when the reader quits, `tee` dies, and the command
---   writing into `tee` fails. The command runs in a subshell it replaces
---   (`exec`), so no bash is left holding the pipe into `tee` either.
---@param nvim string Neovim's executable.
---@param tap string The tap script.
---@param commands string[]
---@param design "direct"|"tee"|nil Defaults to `M.design()`.
---@return string
function M.functions_script(nvim, tap, commands, design)
  design = design or M.design()
  local n, t = sh_quote(M.sh_path(nvim)), sh_quote(M.sh_path(tap))
  local frame, lines, keep = tostring(opts.frame_ms or 250), tostring(opts.lines or 20), tostring(opts.keep or 40)
  ---@param stream string
  local function tap_cmd(stream)
    return table.concat({ n, "--headless -u NONE -i NONE -n -l", t, stream, frame, lines, keep, '"${@:1:7}"' }, " ")
  end
  ---A tap that only reads; one that fails to start leaves `cat` to drain the copy.
  ---@param stream string
  local function sink(stream)
    return ">(" .. tap_cmd(stream .. ":sink") .. " >/dev/null 2>&1 || exec cat >/dev/null)"
  end
  local piped
  if design == "tee" then
    piped = {
      "    if [ /dev/stdout -ef /dev/stderr ]; then",
      "      ( exec > >(command tee " .. sink("both") .. ') 2>&1; exec "$@" )',
      "    else",
      "      ( exec > >(command tee " .. sink("out") .. '); exec "$@" )',
      "    fi",
      "  elif [ -p /dev/stderr ]; then",
      "    ( exec 2> >(command tee " .. sink("err") .. ' >&2); exec "$@" )',
    }
  else
    piped = {
      "    if [ /dev/stdout -ef /dev/stderr ]; then",
      '      command "$@" > >(' .. tap_cmd("both") .. " 2>/dev/null || exec cat) 2>&1",
      "    else",
      '      command "$@" > >(' .. tap_cmd("out") .. " 2>/dev/null || exec cat)",
      "    fi",
      "  elif [ -p /dev/stderr ]; then",
      '    command "$@" 2> >(' .. tap_cmd("err") .. " >&2 2>/dev/null || exec cat >&2)",
    }
  end
  local out = {
    "# Generated by claudecode.nvim for the agents view's live output. Do not edit.",
    "# Shows what a listed command prints before the pipe the agent built reads it.",
    "__claudecode_tap() {",
    '  if [ -z "${CLAUDECODE_NVIM_SERVER:-}" ] || [ ! -x ' .. n .. " ]; then",
    '    command "$@"',
    "  elif [ -p /dev/stdout ]; then",
  }
  for _, line in ipairs(piped) do
    out[#out + 1] = line
  end
  for _, line in ipairs({ "  else", '    command "$@"', "  fi", "}" }) do
    out[#out + 1] = line
  end
  for _, name in ipairs(commands) do
    out[#out + 1] = ('typeset -f %s >/dev/null 2>&1 || alias %s >/dev/null 2>&1 || function %s { __claudecode_tap %s "$@"; }'):format(
      name,
      name,
      name,
      name
    )
  end
  -- The CLI runs the agent's command only if this file's last status is zero.
  out[#out + 1] = ":"
  return table.concat(out, "\n") .. "\n"
end

---The file `CLAUDE_ENV_FILE` names: the user's own one first, then ours.
---
---Its text is pasted into an `&&` chain with ` :` after its last line, and the
---agent's command runs only if that line succeeds — so every line here does.
---@param functions_path string
---@param user_file string|nil A `CLAUDE_ENV_FILE` the user had set.
---@return string
function M.env_script(functions_path, user_file)
  local out = { "# Generated by claudecode.nvim (agents view, live output). Do not edit." }
  if type(user_file) == "string" and user_file ~= "" then
    local u = sh_quote(M.sh_path(user_file))
    out[#out + 1] = "[ ! -r " .. u .. " ] || . " .. u
  end
  -- Skipped unless zsh, or bash outside POSIX mode (macOS's `/bin/sh` is bash
  -- with `BASH_VERSION` set, and rejects a process substitution).
  local f = sh_quote(M.sh_path(functions_path))
  out[#out + 1] = '{ [ -z "${ZSH_VERSION:-}" ] && { [ -z "${BASH_VERSION:-}" ] || shopt -oq posix; }; } || [ ! -r '
    .. f
    .. " ] || . "
    .. f
  return table.concat(out, "\n") .. "\n"
end

--- Injectable file writer: specs keep it in memory.
---@param path string
---@param text string
---@return boolean
M._write = function(path, text)
  local ok = pcall(function()
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end)
  if ok then
    -- Read-only: the agent's own file tools would otherwise be one edit away
    -- from code that runs ahead of every command they are allowed to run.
    pcall(function()
      (vim.uv or vim.loop).fs_chmod(path, 292) -- 0444
    end)
  end
  return ok
end

---Where this Neovim keeps its two files.
---@return string|nil
local function files_dir()
  if state.dir then
    return state.dir
  end
  local ok, base = pcall(vim.fn.stdpath, "run")
  if not ok or type(base) ~= "string" or base == "" then
    base = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
  end
  local uv = vim.uv or vim.loop
  local pid = (uv and uv.os_getpid and uv.os_getpid()) or vim.fn.getpid()
  local dir = base .. "/claudecode-live-" .. tostring(pid)
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p", 448) == 0 then -- 0700
    return nil
  end
  state.dir = dir
  -- Gone with this Neovim; registered only once there is something to remove.
  pcall(function()
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("ClaudeCodeLiveOutput", { clear = true }),
      callback = function()
        M.cleanup()
      end,
    })
  end)
  return dir
end

---Write both files for one set of inputs, once; a different set gets files of
---its own rather than rewriting ones a running CLI may still read.
---@param user_file string|nil
---@return string|nil env_path
local function ensure_files(user_file)
  local nvim = (vim.v and vim.v.progpath) or "nvim"
  local functions = M.functions_script(nvim, M.tap_script(), M.commands())
  local key = functions .. "\0" .. (user_file or "")
  if state.files[key] then
    return state.files[key]
  end
  local dir = files_dir()
  if not dir then
    return nil
  end
  -- A name per set of inputs, not a checksum: only this Neovim writes here.
  local hash = 0
  for i = 1, #key do
    hash = (hash * 31 + key:byte(i)) % 4294967296
  end
  local short = ("%08x"):format(hash)
  local functions_path = dir .. "/tap-" .. short .. ".sh"
  local env_path = dir .. "/env-" .. short .. ".sh"
  if not M._write(functions_path, functions) or not M._write(env_path, M.env_script(functions_path, user_file)) then
    logger.warn("agents", "live output: could not write its shell files under " .. dir)
    return nil
  end
  state.files[key] = env_path
  return env_path
end

---Point a launch's environment at the file that defines the shell functions.
---@param env table<string, string> The launch's environment, changed in place.
---@return boolean injected
function M.launch_env(env)
  if not M.is_enabled() or type(env) ~= "table" then
    return false
  end
  -- The user's own file keeps working: ours sources it first. One inherited from
  -- another Neovim's launch is chained the same way, and skipped once it is gone.
  local user_file = env.CLAUDE_ENV_FILE or os.getenv("CLAUDE_ENV_FILE")
  local path = ensure_files(user_file)
  if not path then
    return false
  end
  env.CLAUDE_ENV_FILE = path
  return true
end

---Remove this Neovim's files.
function M.cleanup()
  local dir = state.dir
  if not dir then
    return
  end
  local uv = vim.uv or vim.loop
  pcall(function()
    for _, name in ipairs(vim.fn.readdir(dir)) do
      local path = dir .. "/" .. name
      pcall(uv.fs_chmod, path, 420) -- 0644, or Windows refuses to delete it
      pcall(uv.fs_unlink, path)
    end
    uv.fs_rmdir(dir)
  end)
  state.dir = nil
  state.files = {}
end

--------------------------------------------------------------------------------
-- Calls
--------------------------------------------------------------------------------

local CALL_TOOLS = { Bash = true, Monitor = true }

---@param text string
---@return string
local function escape_pattern(text)
  return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

---Whether a command line runs `name` as a word of its own.
---@param command string|nil
---@param name string
---@return boolean
function M.names(command, name)
  if type(command) ~= "string" or name == "" then
    return false
  end
  return command:find("%f[%w_.%-]" .. escape_pattern(name) .. "%f[^%w_.%-]") ~= nil
end

---@param changed string|nil tool id
local function emit(changed)
  if changed then
    local first = state.pending == nil
    state.pending = state.pending or {}
    state.pending[changed] = true
    if not first then
      return
    end
    M._defer(function()
      local set = state.pending or {}
      state.pending = nil
      for _, fn in pairs(state.listeners) do
        pcall(fn, set)
      end
    end)
  end
end

---@param tap table
---@param call table
local function attach(tap, call)
  tap.call = call.tool_id
  call.taps[#call.taps + 1] = tap.id
  emit(call.tool_id)
end

---The call a tap belongs to: of its conversation, naming its program, not over
---before it arrived; the newest noted before it, else the first noted after.
---@param tap table
---@return table|nil
local function find_call(tap)
  local before, after
  for _, call in pairs(state.calls) do
    local same = tap.session == "" or call.session == tap.session
    local open = call.ended_at == nil or call.ended_at >= tap.arrived
    if same and open and M.names(call.command, tap.name) then
      if call.noted <= tap.arrived then
        if not before or call.noted > before.noted then
          before = call
        end
      elseif call.noted - tap.arrived <= BIND_WINDOW_S then
        if not after or call.noted < after.noted then
          after = call
        end
      end
    end
  end
  return before or after
end

---Give taps still without a call another look, now that one has been noted.
---@param session string
local function bind_waiting(session)
  local now = M._now()
  for _, id in ipairs(state.order) do
    local tap = state.taps[id]
    -- Running, at any age: with hooks off a call is only noted once a view reads
    -- it from the transcript, which can be long after the command started.
    local recent = tap and (not tap.ended_at or now - tap.ended_at <= BIND_WINDOW_S)
    if recent and not tap.call and (tap.session == "" or tap.session == session) then
      local call = find_call(tap)
      if call then
        attach(tap, call)
      end
    end
  end
end

---Note a shell call that may get a tap.
---@param session_id string|nil
---@param tool_id string|nil
---@param command string|nil
---@param extra { background: boolean?, noted: number? }|nil
function M.note_call(session_id, tool_id, command, extra)
  if type(session_id) ~= "string" or type(tool_id) ~= "string" or tool_id == "" then
    return
  end
  local call = state.calls[tool_id]
  if call then
    call.command = call.command or command
    if extra and extra.background then
      call.background = true
      call.ended_at = nil
    end
    return
  end
  call = {
    session = session_id,
    tool_id = tool_id,
    command = type(command) == "string" and command or nil,
    noted = (extra and extra.noted) or M._now(),
    background = extra and extra.background or nil,
    taps = {},
  }
  state.calls[tool_id] = call
  bind_waiting(session_id)
end

---A call returned. A command sent to the background returns at once and runs on.
---@param tool_id string
---@param background boolean|nil
function M.end_call(tool_id, background)
  local call = state.calls[tool_id]
  if not call then
    return
  end
  if background then
    call.background = true
    return
  end
  call.ended_at = call.ended_at or M._now()
end

---Fold one hook event in (from `live_cursor.dispatch`).
---@param event table
function M.note(event)
  if not M.is_enabled() or type(event) ~= "table" or not CALL_TOOLS[event.tool_name] then
    return
  end
  local id = event.tool_use_id
  if type(id) ~= "string" then
    return
  end
  local input = type(event.tool_input) == "table" and event.tool_input or {}
  if event.hook_event_name == "PreToolUse" then
    local command = type(input.command) == "string" and input.command or nil
    M.note_call(event.session_id, id, command, { background = input.run_in_background == true or nil })
  elseif event.hook_event_name == "PostToolUse" then
    local response = type(event.tool_response) == "table" and event.tool_response or {}
    local background = type(response.backgroundTaskId) == "string" or event.tool_name == "Monitor"
    M.end_call(id, background)
  end
end

--------------------------------------------------------------------------------
-- Taps
--------------------------------------------------------------------------------

local function prune()
  local now = M._now()
  while #state.order > MAX_TAPS do
    local drop
    for index, id in ipairs(state.order) do
      local tap = state.taps[id]
      if not tap or tap.ended_at then
        drop = index
        break
      end
    end
    drop = drop or 1
    local id = table.remove(state.order, drop)
    local tap = state.taps[id]
    state.taps[id] = nil
    local call = tap and tap.call and state.calls[tap.call]
    if call then
      for i = #call.taps, 1, -1 do
        if call.taps[i] == id then
          table.remove(call.taps, i)
        end
      end
    end
  end
  for tool_id, call in pairs(state.calls) do
    if #call.taps == 0 and now - call.noted > CALL_TTL_S then
      state.calls[tool_id] = nil
    end
  end
end

---@param value any
---@return string[]
local function string_list(value)
  local out = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "string" then
        out[#out + 1] = item
      end
    end
  end
  return out
end

---Entry point for the tap, over RPC (`nvim_exec_lua`).
---@param msg table
---@return boolean
function M.ingest(msg)
  if type(msg) ~= "table" or type(msg.id) ~= "string" then
    return false
  end
  local tap = state.taps[msg.id]
  if msg.ev == "hello" then
    if tap then
      return true
    end
    tap = {
      id = msg.id,
      name = type(msg.name) == "string" and msg.name or "?",
      args = string_list(msg.args),
      stream = msg.stream,
      session = type(msg.session) == "string" and msg.session or "",
      agent = msg.agent,
      cwd = msg.cwd,
      at = tonumber(msg.at),
      arrived = M._now(),
      lines = {},
      total = 0,
      bytes = 0,
    }
    state.taps[tap.id] = tap
    state.order[#state.order + 1] = tap.id
    prune()
    local call = find_call(tap)
    if call then
      attach(tap, call)
    end
    return true
  end
  if not tap or (msg.ev ~= "frame" and msg.ev ~= "bye") then
    return false
  end
  tap.lines = string_list(msg.lines)
  tap.partial = msg.partial == true
  tap.total = tonumber(msg.total) or tap.total
  tap.bytes = tonumber(msg.bytes) or tap.bytes
  if msg.ev == "bye" then
    tap.ended_at = M._now()
  end
  if tap.call then
    emit(tap.call)
  end
  return true
end

--------------------------------------------------------------------------------
-- What the views read
--------------------------------------------------------------------------------

---@class ClaudeCodeLiveOutput
---@field name string The program, as the agent called it.
---@field args string[] Its first arguments.
---@field label string `cargo test --workspace`
---@field lines string[] The last lines it printed (raw: escape codes kept).
---@field partial boolean The last line is still being written.
---@field total integer Lines it has printed.
---@field bytes integer
---@field running boolean
---@field taps integer How many tapped commands this call ran.

---What a call's command printed before the pipe, as the latest tap saw it.
---@param session_id string|nil
---@param tool_id string|nil
---@param hint { command: string?, at: number? }|nil The call as a transcript has it, for when no hook noted it.
---@return ClaudeCodeLiveOutput|nil
function M.get(session_id, tool_id, hint)
  if type(tool_id) ~= "string" then
    return nil
  end
  if hint and not state.calls[tool_id] and type(session_id) == "string" then
    M.note_call(session_id, tool_id, hint.command, { noted = hint.at })
  end
  local call = state.calls[tool_id]
  if not call or #call.taps == 0 then
    return nil
  end
  local tap = state.taps[call.taps[#call.taps]]
  if not tap then
    return nil
  end
  local label = tap.name
  if #tap.args > 0 then
    label = label .. " " .. table.concat(tap.args, " ")
  end
  return {
    name = tap.name,
    args = tap.args,
    label = label,
    lines = tap.lines,
    partial = tap.partial == true,
    total = tap.total or 0,
    bytes = tap.bytes or 0,
    running = tap.ended_at == nil,
    taps = #call.taps,
  }
end

---The last line a running command printed, for its Activity row.
---@param session_id string|nil
---@param tool_id string|nil
---@param hint { command: string?, at: number? }|nil
---@return string|nil
function M.ticker(session_id, tool_id, hint)
  if opts.ticker == false then
    return nil
  end
  local out = M.get(session_id, tool_id, hint)
  if not out or not out.running then
    return nil
  end
  for i = #out.lines, 1, -1 do
    local line = out.lines[i]:gsub("\27%[[%d;?]*[%a]", ""):gsub("%s+$", "")
    if line:match("%S") then
      return (line:gsub("^%s+", ""))
    end
  end
  return nil
end

---The conversation a call belongs to, when it has been noted.
---@param tool_id string
---@return string|nil
function M.session_of(tool_id)
  local call = state.calls[tool_id]
  return call and call.session or nil
end

---Be told which calls' output changed (a set of tool ids), coalesced.
---@param name string
---@param fn fun(changed: table<string, boolean>)|nil nil unsubscribes.
function M.on_change(name, fn)
  state.listeners[name] = fn
end

---Test/reload helper.
function M.reset()
  state.taps, state.order, state.calls, state.pending = {}, {}, {}, nil
  state.listeners = {}
end

M._state = state

return M
