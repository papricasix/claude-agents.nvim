-- Live end-to-end check of the OpenCode backend against a real OpenCode service.
--
--   nvim --headless -u NONE -l scripts/opencode_smoke.lua [model]
--
-- Runs in a throwaway git repository under the temp directory, on a cheap model
-- (default anthropic/claude-haiku-4-5), and deletes the session it made. It costs
-- a few cents of that model. What it drives, through the plugin as a user would:
-- a tab terminal launching `opencode`, the editor connection OpenCode's TUI opens
-- back to Neovim, an edit reviewed and accepted with :w, an edit rejected, the
-- tab's status through a turn, and the agents view's listing and fold of the
-- session. Prints PASS/FAIL per check and exits non-zero on any failure.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local model = arg and arg[1] or "anthropic/claude-haiku-4-5"
local failures = 0
local function check(name, ok, detail)
  print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  if not ok then
    failures = failures + 1
  end
  return ok
end
local function wait(ms, cond)
  return vim.wait(ms, cond, 50)
end

local project = vim.fn.tempname() .. "-oc-smoke"
vim.fn.mkdir(project, "p")
vim.fn.writefile({ "hello" }, project .. "/a.txt")
vim.fn.system({ "git", "-C", project, "init", "-q" })
vim.cmd.cd(project)

local events_seen = {}
require("claude_agents").setup({
  backend = "opencode",
  log_level = "warn",
  terminal = { provider = "native" },
  diff_opts = { provider = "native" },
  agents = { enabled = true },
  profiles = { list = { { name = "smoke", backend = "opencode", model = model } }, default = "smoke" },
})

local api = require("claude_agents.opencode.api")
local oc_launch = require("claude_agents.opencode.launch")
local status = require("claude_agents.status")
local unsub = require("claude_agents.opencode.events").subscribe(function(event)
  events_seen[#events_seen + 1] = event.type
end)

local state_trail = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeStatusChanged",
  callback = function()
    local entry = status.get(vim.api.nvim_get_current_tabpage())
    local s = entry and entry.state or "none"
    if state_trail[#state_trail] ~= s then
      state_trail[#state_trail + 1] = s
    end
  end,
})

-- 1. Launch.
require("claude_agents.terminal").open()
local tab = vim.api.nvim_get_current_tabpage()
local session_id = oc_launch.tab_session(tab)
check("a session id was chosen for the tab", session_id ~= nil and session_id:match("^ses_") ~= nil, session_id)
local err, info = api.call_sync("GET", "/api/session/" .. tostring(session_id), nil, 5000)
check("the session exists before the TUI uses it", err == nil and type(info) == "table", err)
check(
  "the profile's model is on the session",
  info and info.model and (info.model.providerID .. "/" .. info.model.id) == model,
  info and info.model and vim.inspect(info.model)
)
local has_ask = false
for _, rule in ipairs(info and info.permissions or {}) do
  if rule.action == "edit" and rule.resource == "*" and rule.effect == "ask" then
    has_ask = true
  end
end
check("edits are set to ask (review)", has_ask)
check("the session is followed", require("claude_agents.opencode.bridge").get(session_id) ~= nil)

-- 2. Editor connection: OpenCode's TUI connects back without a token.
local connected = wait(20000, function()
  return require("claude_agents").is_claude_connected()
end)
check("OpenCode's TUI connected to the editor server", connected)
local inst = require("claude_agents").get_instance(tab)
local tokenless = false
for _, client in pairs(inst.server and inst.server.state.server and inst.server.state.server.clients or {}) do
  if client.tokenless then
    tokenless = true
  end
end
check("it came in through the tokenless door", tokenless)

-- 3. An edit, reviewed and accepted with :w.
local function proposal_buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find("%[OpenCode%].*proposed") then
      return buf
    end
  end
end
api.call_sync("POST", "/api/session/" .. session_id .. "/prompt", {
  body = { text = "Use the edit tool to replace the word hello with goodbye in a.txt. Do nothing else." },
}, 10000)
local buf = nil
wait(90000, function()
  buf = proposal_buffer()
  return buf ~= nil
end)
check("the edit opened a review diff", buf ~= nil)
if buf then
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  check("the diff shows the proposal", lines[1] == "goodbye", lines[1])
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
end
local written = wait(30000, function()
  local ok, content = pcall(vim.fn.readfile, project .. "/a.txt")
  return ok and content[1] == "goodbye"
end)
check("accepting let OpenCode write the file", written)
wait(60000, function()
  local entry = status.get(tab)
  return entry and (entry.state == "done" or entry.state == "idle")
end)
check(
  "the tab went busy, waited for the review, and finished",
  vim.tbl_contains(state_trail, "busy") and vim.tbl_contains(state_trail, "waiting"),
  table.concat(state_trail, " > ")
)

-- 4. An edit rejected.
api.call_sync("POST", "/api/session/" .. session_id .. "/prompt", {
  body = { text = "Use the edit tool to replace goodbye with bye in a.txt. If the edit is rejected, stop." },
}, 10000)
buf = nil
wait(90000, function()
  buf = proposal_buffer()
  return buf ~= nil
end)
check("the second edit opened a review diff", buf ~= nil)
if buf then
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd("ClaudeCodeDiffDeny")
end
wait(60000, function()
  local entry = status.get(tab)
  return entry and (entry.state == "done" or entry.state == "idle")
end)
local content = vim.fn.readfile(project .. "/a.txt")
check("rejecting kept the file as it was", content[1] == "goodbye", content[1])

-- 5. The agents view's source lists and folds the session.
local transcript = require("claude_agents.agents.transcript")
local listed = nil
wait(10000, function()
  for _, row in ipairs(transcript.list(project)) do
    if row.id == session_id then
      listed = row
      return true
    end
  end
  return false
end)
check("the session is listed beside Claude's", listed ~= nil)
local summary = nil
if listed then
  transcript.summary(listed.path, function(sum)
    summary = sum
  end)
  wait(15000, function()
    return summary ~= nil
  end)
end
check("its transcript folds", summary ~= nil)
-- SMOKE_DUMP=<file>: keep the transcript as written and the fold, to look at.
local dump = os.getenv("SMOKE_DUMP")
if dump and listed then
  local store = require("claude_agents.agents.opencode_store")
  vim.fn.writefile(vim.split(store.content(listed.path), "\n"), dump)
  vim.fn.writefile(
    vim.split(vim.inspect(summary and { files = summary.files, events = summary.events }), "\n"),
    dump .. ".fold"
  )
end
if summary then
  -- Keyed as OpenCode spells the session's directory (symlinks resolved).
  local file = summary.files[project .. "/a.txt"]
    or summary.files[require("claude_agents.opencode").canonical(project) .. "/a.txt"]
  -- One edit counted: the rejected one changed nothing (and, as for Claude, a
  -- declined file tool leaves no row of its own).
  check(
    "the fold counts the accepted edit, and only it",
    file and file.added == 1 and file.removed == 1 and #file.edits == 1,
    file and vim.inspect(file)
  )
  check("the session has a title", summary.title ~= nil, summary.title)
end

-- 6. The agents view: an OpenCode agent started there, its edit in a float.
vim.fn.writefile({ "one" }, project .. "/b.txt")
local agents_view = require("claude_agents.agents_view")
local model_mod = require("claude_agents.agents.model")
local registry = require("claude_agents.agents.registry")
local agent_id = nil
local opened_view = pcall(vim.cmd, "ClaudeCodeAgents")
check("the agents view opens", opened_view and agents_view.is_open())
if agents_view.is_open() then
  agents_view.new_agent("smoke")
  agent_id = model_mod.selected()
  check("a new agent got an OpenCode id", agent_id ~= nil and agent_id:match("^ses_") ~= nil, agent_id)
  check("its terminal runs", agent_id ~= nil and registry.is_live(agent_id))
  check(
    "the agent's session is followed",
    agent_id ~= nil and require("claude_agents.opencode.bridge").get(agent_id) ~= nil
  )
  local agent_connected = wait(20000, function()
    local inst = agent_id and require("claude_agents").instance_for_session(agent_id)
    local clients = inst and inst.server and inst.server.state.server and inst.server.state.server.clients or {}
    for _, client in pairs(clients) do
      if client.handshake_complete and client.tokenless then
        return true
      end
    end
    return false
  end)
  check("the agent's TUI connected to its own editor server", agent_connected)
  local row_mark = nil
  for _, row in ipairs(model_mod.rows()) do
    if row.session_id == agent_id then
      row_mark = row.mark or row.profile_mark or true
    end
  end
  check("the agent has a row in the list", row_mark ~= nil)

  api.call_sync("POST", "/api/session/" .. agent_id .. "/prompt", {
    body = { text = "Use the edit tool to replace the word one with two in b.txt. Do nothing else." },
  }, 10000)
  local agent_buf = nil
  wait(90000, function()
    agent_buf = proposal_buffer()
    return agent_buf ~= nil
  end)
  check("the agent's edit opened a review diff", agent_buf ~= nil)
  if agent_buf then
    -- As for a Claude agent: a float inside the view with unified.nvim, in the
    -- tab the view was opened from with the native provider — never a pane.
    -- `bufwinid` looks in the current tab only; the native diff is in another.
    local win = vim.fn.win_findbuf(agent_buf)[1] or -1
    local in_float = win ~= -1 and vim.api.nvim_win_get_config(win).relative ~= ""
    local win_tab = win ~= -1 and vim.api.nvim_win_get_tabpage(win) or nil
    local outside = win_tab ~= nil and not agents_view.is_view_tab(win_tab)
    local where = {}
    if win_tab then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(win_tab)) do
        local ok_pv, pv = pcall(vim.api.nvim_win_get_var, w, "claudecode_live_preview")
        where[#where + 1] = string.format(
          "%d:%s%s",
          w,
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)), ":t"),
          (ok_pv and pv) and "[pane]" or ""
        )
      end
    end
    check(
      "it is not put into one of the agents view's panes",
      in_float or outside,
      string.format(
        "win %d in tab %s (view tab: %s): %s",
        win,
        tostring(win_tab),
        tostring(agents_view.is_view_tab(win_tab)),
        table.concat(where, " ")
      )
    )
    vim.api.nvim_buf_call(agent_buf, function()
      vim.cmd("write")
    end)
  end
  local agent_wrote = wait(30000, function()
    local ok, b = pcall(vim.fn.readfile, project .. "/b.txt")
    return ok and b[1] == "two"
  end)
  check("accepting it let the agent write the file", agent_wrote)
  wait(60000, function()
    local entry = model_mod.status_of(agent_id)
    return entry and (entry.state == "done" or entry.state == "idle")
  end)
  local entry = model_mod.status_of(agent_id)
  check(
    "the agent's row finished its turn",
    entry and (entry.state == "done" or entry.state == "idle"),
    entry and entry.state
  )
  registry.stop(agent_id)
  api.call_sync("DELETE", "/api/session/" .. agent_id, nil, 5000)
end

-- 7. Tidy up.
unsub()
pcall(vim.cmd, "ClaudeCodeClose")
local job = vim.b[vim.api.nvim_get_current_buf()].terminal_job_id
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local ok, id = pcall(function()
    return vim.b[b].terminal_job_id
  end)
  if ok and id then
    pcall(vim.fn.jobstop, id)
  end
end
_ = job
api.call_sync("DELETE", "/api/session/" .. session_id, nil, 5000)
vim.fn.delete(project, "rf")
print(string.format("%d event types seen; %s", #events_seen, failures == 0 and "ALL PASSED" or (failures .. " FAILED")))
vim.cmd(failures == 0 and "qa!" or "cq!")
