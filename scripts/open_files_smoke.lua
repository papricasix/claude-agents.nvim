-- Live end-to-end check of `open_files`: a real CLI asked to open a file in this
-- Neovim, through the MCP server the plugin gives it.
--
--   nvim --headless -u NONE -l scripts/open_files_smoke.lua [claude|opencode|all]
--
-- Each part runs in a throwaway directory under the temp directory on a cheap
-- model (Claude: haiku in print mode, no session saved; OpenCode: the model in
-- OPENCODE_SMOKE_MODEL, default anthropic/claude-haiku-4-5, session deleted
-- afterwards) and costs a few cents. A part whose CLI is not installed is
-- skipped.
--
-- Every part runs in a Neovim with a UI: this script starts one in a terminal of
-- its own. Headless 0.12.2 segfaults (in `vim.wait`'s timer, or in TermClose at
-- exit) once a tab opens beside a running OpenCode TUI; with a UI attached it
-- does not. Prints PASS/FAIL per check and exits non-zero on any failure.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local script = root .. "/scripts/open_files_smoke.lua"

--------------------------------------------------------------------------------
-- Outer: run each part in a Neovim with a UI, relay what it printed.
--------------------------------------------------------------------------------

if not vim.env.OPEN_FILES_SMOKE_LOG then
  local which = (arg and arg[1]) or "all"
  local parts = which == "all" and { "claude", "opencode" } or { which }
  local failed = false
  vim.o.columns, vim.o.lines = 200, 60
  for _, part in ipairs(parts) do
    local log = vim.fn.tempname()
    local done, code = false, nil
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_call(buf, function()
      vim.fn.termopen({ vim.v.progpath, "-u", "NONE", "-i", "NONE", "-c", "luafile " .. vim.fn.fnameescape(script) }, {
        env = { OPEN_FILES_SMOKE_LOG = log, OPEN_FILES_SMOKE_PART = part },
        on_exit = function(_, c)
          done, code = true, c
        end,
      })
    end)
    vim.wait(300000, function()
      return done
    end, 200)
    local ok, lines = pcall(vim.fn.readfile, log)
    io.write(table.concat(ok and lines or { "FAIL " .. part .. ": no output" }, "\n"), "\n")
    vim.fn.delete(log)
    if code ~= 0 then
      failed = true
    end
  end
  io.write(failed and "SOME FAILED\n" or "ALL PASSED\n")
  vim.cmd(failed and "cq!" or "qa!")
  return
end

--------------------------------------------------------------------------------
-- Inner: one part.
--------------------------------------------------------------------------------

vim.opt.rtp:prepend(root)
vim.o.swapfile = false
local out = assert(io.open(vim.env.OPEN_FILES_SMOKE_LOG, "w"))
local part = vim.env.OPEN_FILES_SMOKE_PART
local failures = 0
local function say(line)
  out:write(line, "\n")
  out:flush()
end
local function check(name, ok, detail)
  say((ok and "PASS " or "FAIL ") .. part .. ": " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  if not ok then
    failures = failures + 1
  end
  return ok
end
local function finish()
  out:close()
  vim.cmd(failures == 0 and "qa!" or "cq!")
end

local project = vim.fn.tempname() .. "-open-files"
vim.fn.mkdir(project, "p")
vim.fn.writefile({ "one", "two", "three", "four", "five" }, project .. "/a.txt")
vim.fn.system({ "git", "-C", project, "init", "-q" })
vim.cmd.cd(project)

---The tab the call should have made: a.txt, cursor on line 2, lines 2-3 lit.
local function check_opened()
  local opened = vim.wait(120000, function()
    return #vim.api.nvim_list_tabpages() > 1
  end, 100)
  check("a new tab opened", opened)
  if not opened then
    return
  end
  local win = vim.api.nvim_tabpage_get_win(vim.api.nvim_list_tabpages()[2])
  local buf = vim.api.nvim_win_get_buf(win)
  check(
    "it shows the file",
    vim.fn.resolve(vim.api.nvim_buf_get_name(buf)) == vim.fn.resolve(project .. "/a.txt"),
    vim.api.nvim_buf_get_name(buf)
  )
  check("the cursor is on line 2", vim.api.nvim_win_get_cursor(win)[1] == 2, vim.api.nvim_win_get_cursor(win)[1])
  local marks = vim.api.nvim_buf_get_extmarks(buf, require("claude_agents.open_files")._ns, 0, -1, {})
  check("lines 2-3 are highlighted", #marks == 2, #marks)
end

local PROMPT = "Open a.txt in my editor at lines 2-3, in a new tab, using the open_files tool. Do nothing else."

if part == "claude" then
  if vim.fn.executable("claude") ~= 1 then
    say("SKIP claude: not on PATH")
    finish()
    return
  end
  require("claude_agents").setup({ log_level = "warn", status = { enabled = false } })
  local args = ("-p %s --model haiku --permission-mode default --no-session-persistence --allowedTools %s"):format(
    vim.fn.shellescape(PROMPT),
    "mcp__nvim__open_files"
  )
  local cmd, env = require("claude_agents.terminal").build_launch(args, { cwd = project })
  check("the launch registers the tool server", cmd:find("--mcp-config", 1, true) ~= nil)
  local roles = {}
  local tools = require("claude_agents.tools.init")
  local invoke = tools.handle_invoke
  tools.handle_invoke = function(client, params, model)
    roles[#roles + 1] = tostring(client and client.role)
    return invoke(client, params, model)
  end
  local done = false
  vim.fn.jobstart(require("claude_agents.utils").parse_command(cmd), {
    env = env,
    cwd = project,
    on_exit = function()
      done = true
    end,
  })
  check_opened()
  check("the call came over the tool server", roles[1] == "tools", table.concat(roles, ","))
  vim.wait(60000, function()
    return done
  end, 200)
  -- No session is saved, but the CLI still makes the project's store directory
  -- with an empty `memory/` in it. Only empty directories are removed.
  local store = require("claude_agents.utils").claude_config_dir()
    .. "/projects/"
    .. require("claude_agents.agents.transcript").slugify(vim.loop.fs_realpath(project) or project)
  vim.fn.delete(store .. "/memory", "d")
  vim.fn.delete(store, "d")
elseif part == "opencode" then
  if vim.fn.executable("opencode") ~= 1 then
    say("SKIP opencode: not on PATH")
    finish()
    return
  end
  local model = vim.env.OPENCODE_SMOKE_MODEL or "anthropic/claude-haiku-4-5"
  require("claude_agents").setup({
    backend = "opencode",
    log_level = "warn",
    terminal = { provider = "native" },
    diff_opts = { provider = "native" },
    profiles = { list = { { name = "smoke", backend = "opencode", model = model } }, default = "smoke" },
  })
  local api = require("claude_agents.opencode.api")
  local mcp = require("claude_agents.opencode.mcp")
  require("claude_agents.terminal").open()
  local session_id = require("claude_agents.opencode.launch").tab_session(vim.api.nvim_get_current_tabpage())
  local dir = require("claude_agents.opencode").canonical(project)
  check(
    "the server was added for the directory",
    vim.wait(20000, function()
      return mcp._registered()[dir] == true
    end, 100)
  )
  local _, servers = api.call_sync("GET", "/api/mcp", { query = { ["location[directory]"] = dir } }, 5000)
  local connected = false
  for _, server in ipairs(type(servers) == "table" and servers or {}) do
    local status = type(server.status) == "table" and server.status.status or server.status
    connected = connected or (server.name == mcp.server_name() and status == "connected")
  end
  check("OpenCode connected to it", connected, vim.inspect(servers))
  local _, info = api.call_sync("GET", "/api/session/" .. tostring(session_id), nil, 5000)
  local own, any = mcp.actions()
  local hides, keeps = false, false
  for _, rule in ipairs(info and info.permissions or {}) do
    hides = hides or (rule.action == any and rule.effect == "deny")
    keeps = keeps or (rule.action == own and rule.effect == "allow")
  end
  check("the session hides other Neovims' tool and keeps this one's", hides and keeps)
  vim.wait(3000)
  api.call_sync("POST", "/api/session/" .. session_id .. "/prompt", { body = { text = PROMPT } }, 10000)
  check_opened()
  vim.wait(20000, function()
    local _, active = api.call_sync("GET", "/api/session/active", nil, 3000)
    return type(active) == "table" and active[session_id] == nil
  end, 500)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, id = pcall(function()
      return vim.b[b].terminal_job_id
    end)
    if ok and id then
      pcall(vim.fn.jobstop, id)
    end
  end
  api.call_sync("DELETE", "/api/session/" .. session_id, nil, 5000)
  mcp.shutdown(2000)
  local _, after = api.call_sync("GET", "/api/mcp", { query = { ["location[directory]"] = dir } }, 5000)
  local gone = true
  for _, server in ipairs(type(after) == "table" and after or {}) do
    gone = gone and server.name ~= mcp.server_name()
  end
  check("the server was taken off again", gone)
else
  say("FAIL unknown part " .. tostring(part))
  failures = failures + 1
end

vim.fn.delete(project, "rf")
finish()
