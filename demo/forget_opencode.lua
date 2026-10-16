-- Delete the demo project's OpenCode sessions from OpenCode's service, as
-- render.sh removes its Claude transcripts: nothing from an earlier run shows,
-- and nothing of the demo stays in the OpenCode history of whoever records it.
-- Quiet when OpenCode, or its service, is not there; never starts the service.
--
-- Usage: nvim --headless -u NONE -l demo/forget_opencode.lua <project-dir>

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)

local project = arg[1]
-- Like render.sh's forget_transcripts: refuses anything that is not the demo
-- project, so a wrong argument can never widen into someone's own sessions.
if type(project) ~= "string" or not project:match("/acme%-shop/?$") then
  io.stderr:write("forget_opencode.lua: refusing to forget sessions of '" .. tostring(project) .. "'\n")
  os.exit(1)
end

local opencode = require("claude_agents.opencode")
if not opencode.available() then
  return
end
local api = require("claude_agents.opencode.api")

-- Under both spellings: OpenCode keeps a session under its real path (on macOS
-- `/private/tmp/…` for `/tmp/…`).
local dirs = { project }
local real = opencode.canonical(project)
if real ~= project then
  dirs[2] = real
end

local forgotten = 0
for _, dir in ipairs(dirs) do
  local query = { directory = dir, parentID = "null", limit = 200 }
  local err, sessions = api.call_sync("GET", "/api/session", { query = query, no_start = true }, 5000)
  for _, session in ipairs(not err and type(sessions) == "table" and sessions or {}) do
    local where = type(session.location) == "table" and session.location.directory or ""
    if where:match("/acme%-shop/?$") and type(session.id) == "string" then
      -- Its subagents' sessions go with it.
      if not api.call_sync("DELETE", "/api/session/" .. session.id, { no_start = true }, 5000) then
        forgotten = forgotten + 1
      end
    end
  end
end
if forgotten > 0 then
  print("forgot " .. forgotten .. " OpenCode session(s) of " .. project)
end

-- OpenCode's TUI remembers the tabs it had open in each directory
-- (`<state>/<channel>/tui/tabs.json`, keyed by directory): a deleted session's
-- tab would still show, dimmed, beside the next recording's. Only the project's
-- own entries go.
local state_dir = require("claude_agents.opencode.service").state_dir()
for _, file in ipairs(vim.fn.glob(state_dir .. "/*/tui/tabs.json", false, true)) do
  local handle = io.open(file, "r")
  local text = handle and handle:read("*a")
  if handle then
    handle:close()
  end
  local ok, tabs = pcall(vim.json.decode, text or "")
  if ok and type(tabs) == "table" and type(tabs.cwd) == "table" then
    local changed = false
    for _, dir in ipairs(dirs) do
      if tabs.cwd[dir] ~= nil then
        tabs.cwd[dir] = nil
        changed = true
      end
    end
    if changed then
      handle = io.open(file, "w")
      if handle then
        handle:write(vim.json.encode(tabs))
        handle:close()
      end
    end
  end
end
