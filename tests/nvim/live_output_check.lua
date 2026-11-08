-- The agents view's live output, end to end in a real Neovim: the generated
-- shell functions, the tap, and what this Neovim is told. Each shell gets the
-- env file's text the way the CLI passes it — pasted into an `&&` chain ahead of
-- the command, with ` :` after its last line.
--
--   nvim --headless -u NONE -l tests/nvim/live_output_check.lua
--
-- Runs every shell it finds: bash and zsh (and sh, which must skip the file
-- without breaking the command). On Windows that is Git Bash, found through
-- CLAUDE_CODE_GIT_BASH_PATH, PATH, or its usual install place.
--
-- Exits non-zero on the first failure. Driven by tests/integration/live_output_nvim_spec.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local uv = vim.uv or vim.loop
local windows = vim.fn.has("win32") == 1

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then
    io.stderr:write("FAILED: " .. what .. "\n")
    os.exit(1)
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/bin", "p")

-- The producer: interleaved stdout/stderr with pauses, like a compiler, then
-- exit 3. A script, so every shell runs it the same way (Git Bash included).
local gen = dir .. "/bin/gen"
vim.fn.writefile({
  "#!/bin/sh",
  "i=1",
  'while [ "$i" -le "${GEN_LINES:-40}" ]; do',
  '  echo "out $i"',
  '  echo "err $i" >&2',
  "  [ $((i % 10)) -eq 0 ] && sleep 0.05",
  "  i=$((i + 1))",
  "done",
  'exit "${GEN_EXIT:-3}"',
}, gen)
uv.fs_chmod(gen, 493) -- 0755
-- Endless, for the early-exit check.
local spew = dir .. "/bin/spew"
vim.fn.writefile({ "#!/bin/sh", "while :; do echo y; done" }, spew)
uv.fs_chmod(spew, 493)

local live = require("claude_agents.agents.live_output")
live.setup({ agents = { enabled = true, live_output = { commands = { "gen", "spew" }, frame_ms = 50 } } })

local server = vim.v.servername
if server == nil or server == "" then
  server = vim.fn.serverstart()
end

---@param path string|nil
local function exists(path)
  return path and path ~= "" and uv.fs_stat(path) ~= nil
end

local shells = {}
local function add_shell(kind, path)
  if exists(path) then
    shells[#shells + 1] = { kind = kind, path = path }
  end
end
if windows then
  local git_bash = os.getenv("CLAUDE_CODE_GIT_BASH_PATH")
  if not exists(git_bash) then
    git_bash = "C:/Program Files/Git/bin/bash.exe"
  end
  if not exists(git_bash) then
    git_bash = vim.fn.exepath("bash")
  end
  add_shell("bash", git_bash)
else
  add_shell("bash", vim.fn.exepath("bash"))
  -- macOS ships bash 3.2 as /bin/bash; PATH often finds a newer one first.
  local found = shells[1] and uv.fs_realpath(shells[1].path)
  if exists("/bin/bash") and uv.fs_realpath("/bin/bash") ~= found then
    add_shell("bash", "/bin/bash")
  end
  add_shell("zsh", vim.fn.exepath("zsh"))
  add_shell("sh", vim.fn.exepath("sh"))
end
check(#shells > 0, "found no bash or zsh to run")

-- The user's own CLAUDE_ENV_FILE, which ours has to keep working.
local user_env = dir .. "/user-env.sh"
vim.fn.writefile({ "export LIVE_CHECK_USER=from-user-file" }, user_env)

local env = {}
check(live.launch_env(env), "launch_env injected nothing")
local env_path = env.CLAUDE_ENV_FILE
check(exists(env_path), "no env file written")
local with_user = { CLAUDE_ENV_FILE = user_env }
check(
  live.launch_env(with_user) and with_user.CLAUDE_ENV_FILE ~= env_path,
  "a user's file did not get a file of its own"
)

---The env file's text as the CLI passes it: trimmed, then ` :` after it.
---@param path string
local function pasted(path)
  local text = table.concat(vim.fn.readfile(path), "\n"):gsub("%s+$", "")
  return text .. " :"
end

local session = "11111111-2222-3333-4444-555555555555"
local tool_counter = 0

---Run a command the way the CLI does: `<earlier steps> && <env file> : && eval <cmd>`.
---@param shell { kind: string, path: string }
---@param command string
---@param opts { env_file: string?, call: boolean?, preamble: string? }|nil
---@return { out: string, code: integer, tool_id: string, ms: number }
local function run(shell, command, opts)
  opts = opts or {}
  tool_counter = tool_counter + 1
  local tool_id = "toolu_check_" .. tool_counter
  if opts.call ~= false then
    live.note_call(session, tool_id, command)
  end
  local parts = { "true" }
  if opts.preamble then
    parts[#parts + 1] = opts.preamble
  end
  parts[#parts + 1] = pasted(opts.env_file or env_path)
  -- Quoted for sh here: `shellescape` follows 'shell', which may be fish.
  parts[#parts + 1] = "eval '" .. command:gsub("'", "'\\''") .. "'"
  local script = table.concat(parts, " && ")
  local chunks = {}
  local started = uv.hrtime()
  local code
  local job = vim.fn.jobstart({ shell.path, "-c", script }, {
    cwd = dir,
    env = {
      PATH = dir .. "/bin" .. (windows and ";" or ":") .. (vim.env.PATH or ""),
      CLAUDECODE_NVIM_SERVER = server,
      CLAUDE_CODE_SESSION_ID = session,
    },
    stdout_buffered = true,
    on_stdout = function(_, data)
      chunks[#chunks + 1] = table.concat(data, "\n")
    end,
    on_exit = function(_, c)
      code = c
    end,
  })
  check(job > 0, shell.kind .. ": could not start")
  -- Not `jobwait`: it would keep this Neovim from answering the tap.
  local done = vim.wait(20000, function()
    return code ~= nil
  end, 10)
  check(done, shell.kind .. ": `" .. command .. "` did not finish")
  return {
    out = table.concat(chunks, ""),
    code = code,
    tool_id = tool_id,
    ms = (uv.hrtime() - started) / 1e6,
  }
end

---@param tool_id string
local function wait_ended(tool_id)
  vim.wait(3000, function()
    local got = live.get(session, tool_id)
    return got ~= nil and not got.running
  end, 20)
  return live.get(session, tool_id)
end

for _, shell in ipairs(shells) do
  local k = shell.kind
  local real = shell.kind ~= "sh"

  -- Byte-identical output: merged, stdout only, inside $(…).
  local plain_merged = run(shell, "command gen 2>&1 | cat", { call = false })
  local merged = run(shell, "gen 2>&1 | cat")
  check(merged.out == plain_merged.out and #merged.out > 0, k .. ": 2>&1 output differs with the tap")
  local plain_out = run(shell, "command gen 2>/dev/null | cat", { call = false })
  local only_out = run(shell, "gen 2>/dev/null | cat")
  check(only_out.out == plain_out.out, k .. ": stdout-only output differs with the tap")
  local captured = run(shell, 'x=$(gen 2>&1); printf "%s\\n" "$x"')
  check(captured.out == plain_merged.out, k .. ": command substitution differs with the tap")

  if real then
    -- What this Neovim was told: the last lines, in order, and how many there were.
    local got = wait_ended(merged.tool_id)
    check(got ~= nil, k .. ": the tap never reported the 2>&1 call")
    check(got.name == "gen", k .. ": tap names " .. tostring(got and got.name))
    check(got.total == 80, k .. ": counted " .. tostring(got and got.total) .. " lines, not 80")
    check(got.lines[#got.lines] == "err 40", k .. ": last line is " .. tostring(got and got.lines[#got.lines]))
    check(#got.lines == 20, k .. ": kept " .. tostring(got and #got.lines) .. " lines after the end, not 20")
    local stdout_only = wait_ended(only_out.tool_id)
    check(stdout_only and stdout_only.lines[#stdout_only.lines] == "out 40", k .. ": stdout tap saw stderr")
  end

  -- The exit status comes through the pipe unchanged.
  local status_cmd = shell.kind == "zsh" and 'gen 2>/dev/null | cat >/dev/null; echo "status=${pipestatus[1]}"'
    or 'gen 2>/dev/null | cat >/dev/null; echo "status=${PIPESTATUS[0]}"'
  if shell.kind ~= "sh" then
    check(run(shell, status_cmd).out:find("status=3", 1, true) ~= nil, k .. ": exit status changed")
  end
  check(run(shell, "gen >/dev/null 2>&1; echo status=$?").out:find("status=3", 1, true), k .. ": unpiped exit status")

  -- A reader that leaves early stops the producer, as without the tap.
  local early = run(shell, "spew | head -1")
  check(early.out:gsub("%s+$", "") == "y", k .. ": `| head -1` printed " .. early.out)
  check(early.ms < 5000, k .. ": `| head -1` took " .. math.floor(early.ms) .. " ms")

  -- Unpiped output reaches the CLI's file whole: no tap.
  local unpiped = run(shell, "gen >/dev/null 2>&1")
  vim.wait(300, function()
    return false
  end)
  check(live.get(session, unpiped.tool_id) == nil, k .. ": tapped a command that was not piped")

  -- The user's own env file still applies, through ours.
  local chained = run(shell, 'echo "$LIVE_CHECK_USER"', { env_file = with_user.CLAUDE_ENV_FILE })
  check(chained.out:find("from-user-file", 1, true) ~= nil, k .. ": the user's CLAUDE_ENV_FILE was lost")

  -- A function of the user's own wins.
  if real then
    local theirs = run(shell, "gen | cat", { preamble = "gen() { echo mine; }" })
    check(theirs.out:gsub("%s+$", "") == "mine", k .. ": overrode the user's own function")
  end
end

-- The command still runs when our functions file is gone (Neovim exited first).
local tap_file = table.concat(vim.fn.readfile(env_path), "\n"):match("%. '([^']+)'%s*$")
check(tap_file ~= nil, "env file names no functions file")
local orphan = dir .. "/orphan-env.sh"
vim.fn.writefile(
  { (table.concat(vim.fn.readfile(env_path), "\n"):gsub(vim.pesc(tap_file), dir .. "/missing.sh")) },
  orphan
)
for _, shell in ipairs(shells) do
  local gone = run(shell, "echo still-runs", { env_file = orphan, call = false })
  check(gone.out:find("still-runs", 1, true) ~= nil, shell.kind .. ": a missing functions file stopped the command")
end

--------------------------------------------------------------------------------
-- The floats: where the panel sits, and that it moves only what is below it.
--------------------------------------------------------------------------------

vim.o.columns, vim.o.lines = 160, 50
require("claude_agents.agents.float").setup({ agents = { enabled = true } })
local shell_view = require("claude_agents.agents.shell_view")
local tool_view = require("claude_agents.agents.tool_view")

local function buf_lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end
local function index_of(lines, pattern)
  for i, line in ipairs(lines) do
    if line:find(pattern, 1, true) then
      return i
    end
  end
  return nil
end
local function feed_tap(id, lines, ev)
  live.ingest({ ev = ev or "frame", id = id, lines = lines, total = #lines })
  -- Listeners are called after a short delay.
  vim.wait(150, function()
    return false
  end)
end

-- A foreground command still running: its output file holds what grep let through.
local output = dir .. "/fg.output"
vim.fn.writefile({ "test b ... FAILED" }, output)
live.note_call("s-view", "toolu_fg", "cargo test 2>&1 | grep FAILED")
live.ingest({ ev = "hello", id = "v1", name = "cargo", args = { "test" }, session = "s-view" })
local win
shell_view.open({
  session_id = "s-view",
  transcript = dir .. "/none.jsonl",
  tool_id = "toolu_fg",
  command = "cargo test 2>&1 | grep FAILED",
  foreground = { output_path = output, started = os.time(), tool = "Bash" },
}, function(w)
  win = w
end)
vim.wait(1000, function()
  return win ~= nil and index_of(buf_lines(win), "test b ... FAILED") ~= nil
end, 20)
check(win ~= nil, "shell float did not open")
local before = buf_lines(win)
check(index_of(before, "before the pipe") == nil, "panel drawn before the tap said anything")

feed_tap("v1", { "   Compiling a", "test a ... ok" })
local now_lines = buf_lines(win)
local status_at = index_of(now_lines, "running")
local panel_at = index_of(now_lines, "── cargo test · before the pipe · 2 lines")
local rule_at = index_of(now_lines, "── output")
check(status_at and panel_at and rule_at, "panel or rule missing:\n" .. table.concat(now_lines, "\n"))
check(status_at < panel_at and panel_at < rule_at, "panel not between status and output")
check(now_lines[panel_at + 2] == "test a ... ok", "panel's last line is " .. tostring(now_lines[panel_at + 2]))
check(now_lines[rule_at + 1] == "test b ... FAILED", "the filtered output moved off the rule")

feed_tap("v1", { "   Compiling a", "test a ... ok", "test b ... FAILED", "test c ... ok" })
now_lines = buf_lines(win)
rule_at = index_of(now_lines, "── output")
check(now_lines[rule_at + 1] == "test b ... FAILED", "a growing panel overwrote the output")
check(index_of(now_lines, "· 4 lines") ~= nil, "panel did not grow")

-- More filtered output still lands below the rule, after what was there.
vim.fn.writefile({ "test b ... FAILED", "test d ... FAILED" }, output)
vim.wait(1500, function()
  return index_of(buf_lines(win), "test d ... FAILED") ~= nil
end, 50)
now_lines = buf_lines(win)
local d_at = index_of(now_lines, "test d ... FAILED")
check(d_at and d_at > index_of(now_lines, "── output"), "new output landed above the rule")
pcall(vim.api.nvim_win_close, win, true)

-- A finished call: the kept lines under its command.
local tx = dir .. "/session.jsonl"
vim.fn.writefile({
  vim.json.encode({
    type = "assistant",
    timestamp = "2026-11-08T10:00:00.000Z",
    message = {
      role = "assistant",
      content = {
        { type = "tool_use", id = "toolu_done", name = "Bash", input = { command = "cargo test 2>&1 | grep -c ok" } },
      },
    },
  }),
  vim.json.encode({
    type = "user",
    timestamp = "2026-11-08T10:00:05.000Z",
    message = { role = "user", content = { { type = "tool_result", tool_use_id = "toolu_done", content = "2" } } },
    toolUseResult = { stdout = "2", stderr = "", interrupted = false },
  }),
}, tx)
live.note_call("s-view", "toolu_done", "cargo test 2>&1 | grep -c ok")
live.ingest({ ev = "hello", id = "v2", name = "cargo", args = { "test" }, session = "s-view" })
live.ingest({ ev = "bye", id = "v2", lines = { "test a ... ok", "test result: ok" }, total = 2 })
local twin
tool_view.open({ session_id = "s-view", transcript = tx, tool_id = "toolu_done", tool = "Bash" }, function(w)
  twin = w
end)
vim.wait(1000, function()
  return twin ~= nil
end, 20)
check(twin ~= nil, "tool float did not open")
local tlines = buf_lines(twin)
check(tlines[1] == "$ cargo test 2>&1 | grep -c ok", "tool float's first line is " .. tostring(tlines[1]))
check(tlines[2] == "", "no blank under the command")
check(tlines[3] and tlines[3]:find("── cargo test · before the pipe", 1, true) == 1, "panel not under the command")
check(tlines[5] == "test result: ok", "kept lines missing")
check(index_of(tlines, "── stdout") > 5, "stdout section not after the panel")
pcall(vim.api.nvim_win_close, twin, true)

-- A subagent's transcript: virtual lines under its running command, and none
-- once the call has its result.
local subagent_view = require("claude_agents.agents.subagent_view")
local sess = dir .. "/sess.jsonl"
vim.fn.writefile({}, sess)
vim.fn.mkdir(dir .. "/sess/subagents", "p")
local agent_tx = dir .. "/sess/subagents/agent-a1.jsonl"
vim.fn.writefile({
  vim.json.encode({
    type = "assistant",
    timestamp = "2026-11-08T10:00:00.000Z",
    message = {
      role = "assistant",
      content = {
        { type = "tool_use", id = "toolu_sub", name = "Bash", input = { command = "cargo build 2>&1 | tail -3" } },
      },
    },
  }),
}, agent_tx)
live.note_call("s-view", "toolu_sub", "cargo build 2>&1 | tail -3")
live.ingest({ ev = "hello", id = "v3", name = "cargo", args = { "build" }, session = "s-view" })
local swin
subagent_view.open({ session_id = "s-view", session_path = sess, agent_id = "a1" }, function(w)
  swin = w
end)
vim.wait(1500, function()
  return swin ~= nil and index_of(buf_lines(swin), "cargo build") ~= nil
end, 20)
check(swin ~= nil, "subagent float did not open")
feed_tap("v3", { "   Compiling serde v1.0", "   Compiling tokio v1.40" })
local sbuf = vim.api.nvim_win_get_buf(swin)
local live_ns = vim.api.nvim_create_namespace("claudecode_agents_subagent_view_live")
local function virt()
  local marks = vim.api.nvim_buf_get_extmarks(sbuf, live_ns, 0, -1, { details = true })
  return marks[1] and marks[1][4].virt_lines or nil
end
local shown = virt()
check(shown ~= nil, "no virtual lines under the running command")
check(shown and shown[1][1][1]:find("cargo build · before the pipe", 1, true) ~= nil, "virtual panel has no rule")
check(shown and shown[#shown][1][1]:find("Compiling tokio", 1, true) ~= nil, "virtual panel lacks the last line")
local call_row = vim.api.nvim_buf_get_extmarks(sbuf, live_ns, 0, -1, {})[1][2]
check(buf_lines(swin)[call_row + 1]:find("cargo build", 1, true) ~= nil, "panel not under the call's line")
pcall(vim.api.nvim_win_close, swin, true)

live.cleanup()
check(not exists(env_path), "cleanup left the env file")
vim.fn.delete(dir, "rf")
print(("ok %d checks (%s)"):format(
  checks,
  table.concat(
    vim.tbl_map(function(s)
      return s.kind
    end, shells),
    ", "
  )
))
os.exit(0)
