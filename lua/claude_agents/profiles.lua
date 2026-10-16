---@brief [[
--- Launch profiles: which account a Claude runs on, chosen per launch.
---
--- A profile is a name, a menu key, `auth = "subscription" | "api"`, and
--- optionally a model, extra arguments and environment. Plain launches (`a`,
--- `:ClaudeCode`) use `profiles.default`, which is nil out of the box: the plugin
--- then touches nothing and the CLI decides, as it always has. `ga`/`gi` in the
--- agents view and `:ClaudeCodeProfile` start or switch a Claude under a profile.
---
--- What a profile does to a launch (measured against CLI 2.1.300):
---   * `api`: an `apiKeyHelper` in the launch's `--settings` — the CLI uses it in
---     preference to the claude.ai login, with no approval prompt — running
---     `scripts/api_key.lua get <entry>` against the OS keychain, or the profile's
---     own `api_key_cmd`.
---   * `subscription`: `apiKeyHelper = ""`, which switches off one set in the
---     user's settings, so the claude.ai login is used.
---   * both blank `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`, in the process
---     environment and in the settings' `env`: an approved key in the environment
---     outranks a helper, and an empty value reads as unset (the CLI tests it for
---     truth). `api` also blanks `CLAUDE_CODE_OAUTH_TOKEN`, a subscription token.
---
--- A conversation remembers the profile it last ran under (`remember`, kept in
--- `stdpath("cache")/claudecode/profiles.json`), so resuming it — `i` in the
--- agents view, a restored Neovim session — goes back to the same account.
--- Switching a running conversation to another profile restarts it with
--- `--resume`, which the CLI carries on across accounts (signed thinking blocks
--- included; measured both ways).
---@brief ]]
---@module 'claude_agents.profiles'

local store_io = require("claude_agents.store_io")
local utils = require("claude_agents.utils")

local M = {}

--- What exists when the config names no profiles.
M.BUILTIN = {
  { name = "subscription", key = "s", auth = "subscription" },
  { name = "API key", key = "a", auth = "api", keychain = "default" },
}

--- Added to the built-ins when OpenCode is installed (or is the backend): a
--- launch under it runs OpenCode, on whatever model and agent OpenCode is set to.
M.OPENCODE_BUILTIN = { name = "OpenCode", key = "o", backend = "opencode" }

--- Keys the profile menu needs for itself: moving the cursor (`hjkl`) and
--- closing (`q`). A profile bound to one of them would take it from the menu.
M.RESERVED_KEYS = { h = true, j = true, k = true, l = true, q = true }

--- The mark an `api` profile carries unless it sets its own: what a session
--- costs per token is worth seeing on its row.
M.API_MARK = "$"

local STORE_VERSION = 1

--- How long a key check is believed (seconds). Long enough that opening the menu
--- twice runs it once, short enough that storing a key shows on the next open.
local CHECK_TTL = 30

---@class ClaudeCodeProfile
---@field name string
---@field key string|nil Single-key accelerator in the profile menu.
---@field backend "claude"|"opencode"|nil Which CLI a launch under it runs; nil is Claude.
---@field agent string|nil OpenCode: the agent its sessions start with (`build`, `plan`, …).
---@field auth "subscription"|"api"|nil Claude only.
---@field keychain string|nil Keychain entry (api; "default" when neither this nor api_key_cmd is set).
---@field api_key_cmd string|nil A command printing the key (api).
---@field model string|nil Passed as `--model` unless the command already has one.
---@field args string|nil Extra CLI arguments.
---@field env table<string, string>|nil Extra environment.
---@field workspace string|nil Sent as `anthropic-workspace-id` (organisation-level keys).
---@field mark string|nil Shown on the rows of sessions run under it.

---@type ClaudeCodeProfile[]
local profiles = vim.deepcopy(M.BUILTIN)
---@type string|nil
local default_name = nil

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

---@param entry table
---@return ClaudeCodeProfile
local function normalize(entry)
  local profile = vim.deepcopy(entry)
  if profile.auth == "api" and not profile.api_key_cmd and not profile.keychain then
    profile.keychain = "default"
  end
  return profile
end

--- Whether an executable is on PATH; false when it cannot be told. A seam for specs.
M._executable = function(exe)
  local ok, result = pcall(function()
    return vim.fn.executable(exe)
  end)
  return ok and result == 1
end

---The built-ins this Neovim can use: the Claude ones unless only OpenCode is
---there to run, and OpenCode's when it is installed or is the backend.
---@param config table|nil
---@return table[]
function M.builtin_list(config)
  config = type(config) == "table" and config or {}
  ---The executable a command line starts with.
  local function executable_of(cmd)
    local ok, words = pcall(utils.shell_split, cmd)
    if ok and type(words) == "table" and words[1] then
      return words[1]
    end
    return cmd:match("^%s*(%S+)")
  end
  local opencode_backend = config.backend == "opencode"
  local opencode_cmd = type(config.opencode) == "table" and config.opencode.cmd or "opencode"
  local opencode_exe = executable_of(type(opencode_cmd) == "string" and opencode_cmd or "opencode")
  local has_opencode = opencode_backend or (opencode_exe ~= nil and M._executable(opencode_exe))
  local claude_cmd = type(config.terminal_cmd) == "string" and config.terminal_cmd ~= "" and config.terminal_cmd
    or "claude"
  local claude_exe = executable_of(claude_cmd)
  local has_claude = not opencode_backend or (claude_exe ~= nil and M._executable(claude_exe))

  local list = {}
  if has_claude then
    for _, entry in ipairs(M.BUILTIN) do
      list[#list + 1] = entry
    end
  end
  if has_opencode then
    list[#list + 1] = M.OPENCODE_BUILTIN
  end
  return list
end

---@param config table|nil The full plugin config.
function M.setup(config)
  local opts = type(config) == "table" and type(config.profiles) == "table" and config.profiles or {}
  local list = type(opts.list) == "table" and opts.list or M.builtin_list(config)
  profiles = {}
  for _, entry in ipairs(list) do
    profiles[#profiles + 1] = normalize(entry)
  end
  default_name = type(opts.default) == "string" and opts.default or nil
  pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeProfileMark", { link = "Special", default = true })
end

---Every profile, in menu order. Copies.
---@return ClaudeCodeProfile[]
function M.list()
  return vim.deepcopy(profiles)
end

---Look a profile up by name, then by name ignoring case, then by its menu key.
---@param name string|table|nil A name, or a profile (handed back as found by its name).
---@return ClaudeCodeProfile|nil
function M.get(name)
  if type(name) == "table" then
    name = name.name
  end
  if type(name) ~= "string" or name == "" then
    return nil
  end
  for _, profile in ipairs(profiles) do
    if profile.name == name then
      return vim.deepcopy(profile)
    end
  end
  local lower = name:lower()
  for _, profile in ipairs(profiles) do
    if profile.name:lower() == lower then
      return vim.deepcopy(profile)
    end
  end
  for _, profile in ipairs(profiles) do
    if profile.key == name then
      return vim.deepcopy(profile)
    end
  end
  return nil
end

---The profile plain launches use; nil means "as configured", touching nothing.
---@return ClaudeCodeProfile|nil
function M.default()
  return M.get(default_name)
end

---@return string|nil
function M.default_name()
  return default_name
end

---Which CLI a launch under a profile runs.
---@param profile ClaudeCodeProfile|string|nil
---@return "claude"|"opencode"|nil backend nil for no profile.
function M.backend(profile)
  profile = type(profile) == "string" and M.get(profile) or profile
  if type(profile) ~= "table" then
    return nil
  end
  return profile.backend == "opencode" and "opencode" or "claude"
end

---What a session run under a profile is marked with; "" for none.
---@param profile ClaudeCodeProfile|string|nil
---@return string
function M.mark(profile)
  profile = type(profile) == "string" and M.get(profile) or profile
  if type(profile) ~= "table" then
    return ""
  end
  if type(profile.mark) == "string" then
    return profile.mark
  end
  return profile.auth == "api" and M.API_MARK or ""
end

--------------------------------------------------------------------------------
-- Which profile a conversation ran under (persisted)
--------------------------------------------------------------------------------

--- `[session_id] = { profile = name, at = epoch }`
---@type table<string, { profile: string, at: number }>
local sessions = {}
local loaded = false
---@type string|nil
local stamp = nil
---@type string|nil
local store_path = nil

--- The filesystem, as a seam for specs.
M._io = store_io

---@return string|nil path nil only when first asked from a fast context.
function M.store_path()
  if not store_path and not (vim.in_fast_event and vim.in_fast_event()) then
    store_path = vim.fn.stdpath("cache") .. "/claudecode/profiles.json"
  end
  return store_path
end

---@return boolean read false when the file exists and could not be read.
local function read_store()
  local path = M.store_path()
  if not path then
    return false
  end
  local seen = M._io.stat(path)
  local data = M._io.read(path)
  if data == nil and seen ~= nil then
    return false
  end
  local fresh = {}
  local ok, decoded = pcall(vim.json.decode, data or "")
  if ok and type(decoded) == "table" and decoded.version == STORE_VERSION and type(decoded.sessions) == "table" then
    for id, record in pairs(decoded.sessions) do
      if type(id) == "string" and type(record) == "table" and type(record.profile) == "string" then
        fresh[id] = { profile = record.profile, at = tonumber(record.at) or 0 }
      end
    end
  end
  sessions, stamp, loaded = fresh, seen, true
  return true
end

local function load()
  if not loaded then
    read_store()
  end
end

---Apply a change to the store as it is on disk now (another Neovim may have
---written since), and write it back.
---@param change fun(): boolean
local function mutate(change)
  if not read_store() or not change() then
    return
  end
  local ok, encoded = pcall(vim.json.encode, { version = STORE_VERSION, sessions = sessions })
  local path = M.store_path()
  if ok and path and M._io.write(path, encoded) ~= false then
    stamp = M._io.stat(path)
  end
end

---The profile a conversation last ran under, by name; nil when it never ran
---under one (or that profile no longer exists).
---@param session_id string|nil
---@return string|nil
function M.of(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  load()
  local record = sessions[session_id]
  return record and M.get(record.profile) and record.profile or nil
end

---Take in what another Neovim wrote since the store was last read: one stat,
---the file read again only when it moved. For a periodic tick (the session
---list's refresh); `of` itself asks nothing of the disk, since a list paint
---asks it once per row.
---@return boolean changed
function M.refresh()
  local path = M.store_path()
  if loaded and path and M._io.stat(path) == stamp then
    return false
  end
  return read_store()
end

---Record that a conversation runs under a profile.
---@param session_id string|nil
---@param name string|nil
function M.remember(session_id, name)
  if type(session_id) ~= "string" or session_id == "" or type(name) ~= "string" or name == "" then
    return
  end
  mutate(function()
    local record = sessions[session_id]
    if record and record.profile == name then
      return false
    end
    sessions[session_id] = { profile = name, at = os.time() }
    return true
  end)
end

---A conversation took over from another in the same process (`/clear`, a
---fork): it runs under the same profile.
---@param from string|nil
---@param to string|nil
function M.carry(from, to)
  local name = M.of(from)
  if name then
    M.remember(to, name)
  end
end

---Forget a conversation (it was deleted).
---@param session_id string|nil
function M.forget(session_id)
  if type(session_id) ~= "string" then
    return
  end
  load()
  if sessions[session_id] == nil and M._io.stat(M.store_path() or "") == stamp then
    return
  end
  mutate(function()
    if sessions[session_id] == nil then
      return false
    end
    sessions[session_id] = nil
    return true
  end)
end

--------------------------------------------------------------------------------
-- A tab's own Claude
--------------------------------------------------------------------------------

--- [tabpage] = profile name of the Claude running in it (absent: plain).
local tab_profiles = {}
--- [tabpage] = what the launch being built would run as, until its terminal exists.
local pending_tab = {}

---Note what the command being built for a tab would run under. Every terminal
---toggle rebuilds the command whether or not a process is started, so this only
---becomes the tab's once a fresh terminal appears (`note_tab_terminal`).
---@param tab integer
---@param name string|nil
---@param session_id string|nil
function M.set_pending_tab_launch(tab, name, session_id)
  pending_tab[tab] = { profile = name, session_id = session_id }
end

---A fresh terminal appeared in a tab: the pending launch is what it runs.
---@param tab integer
---@param bufnr integer|nil
function M.note_tab_terminal(tab, bufnr)
  local launch = pending_tab[tab]
  pending_tab[tab] = nil
  if not launch then
    return
  end
  tab_profiles[tab] = launch.profile
  if bufnr then
    pcall(function()
      vim.b[bufnr].claudecode_profile = launch.profile or ""
    end)
  end
  if launch.profile and launch.session_id then
    M.remember(launch.session_id, launch.profile)
  end
end

---The profile a tab's Claude runs under; nil for a plain launch or no Claude.
---@param tab integer|nil Defaults to the current tabpage.
---@return string|nil
function M.of_tab(tab)
  return tab_profiles[tab or vim.api.nvim_get_current_tabpage()]
end

---A tab's Claude reported the conversation it is having (its `SessionStart`):
---that conversation runs under the tab's profile. Covers a launch whose id we
---did not choose, and `/clear`.
---@param tab integer|nil
---@param session_id string|nil
function M.note_tab_session(tab, session_id)
  tab = tonumber(tab)
  local name = tab and tab_profiles[tab]
  if name then
    M.remember(session_id, name)
  end
end

---A tab's Claude ended.
---@param tab integer|nil
function M.forget_tab(tab)
  if tab then
    tab_profiles[tab] = nil
    pending_tab[tab] = nil
  end
end

--------------------------------------------------------------------------------
-- Launch
--------------------------------------------------------------------------------

---Plugin root, from this module's location.
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source or ""
  local file = src:gsub("^@", "")
  return (file:gsub("[/\\]lua[/\\]claude_agents[/\\]profiles%.lua$", ""))
end

---@return string
function M.helper_script()
  return plugin_root() .. "/scripts/api_key.lua"
end

---The `apiKeyHelper` an api profile hands the CLI.
---@param profile ClaudeCodeProfile
---@return string
function M.helper_command(profile)
  if type(profile.api_key_cmd) == "string" and profile.api_key_cmd ~= "" then
    return profile.api_key_cmd
  end
  local quote = utils.quote_for_cli_shell
  local nvim_bin = (vim.v and vim.v.progpath) or "nvim"
  return quote(nvim_bin) .. " --headless -u NONE -l " .. quote(M.helper_script()) .. " get " .. profile.keychain
end

---Which conversation a command names, and how.
---@param argv string[]
---@return string|nil session_id
function M.session_of_argv(argv)
  for i, word in ipairs(argv) do
    local flag, inline = word:match("^(%-%-[%w-]+)=(.*)$")
    flag = flag or word
    if flag == "--resume" or flag == "-r" or flag == "--session-id" then
      local value = inline or argv[i + 1]
      if type(value) == "string" and value:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
        return value
      end
    elseif flag == "--session" or flag == "-s" then
      -- OpenCode names its conversation with `--session <ses_…>`.
      local value = inline or argv[i + 1]
      if require("claude_agents.opencode").is_session_id(value) then
        return value
      end
    end
  end
  return nil
end

---@param argv string[]
---@param flag string
---@return boolean
local function has_flag(argv, flag)
  for _, word in ipairs(argv) do
    if word == flag or word:sub(1, #flag + 1) == flag .. "=" then
      return true
    end
  end
  return false
end

---Which profile a launch runs under: the one asked for, else the one the
---conversation it resumes last ran under, else the default (nil: plain).
---@param explicit string|ClaudeCodeProfile|nil
---@param argv string[]
---@return ClaudeCodeProfile|nil
function M.resolve(explicit, argv)
  if explicit ~= nil then
    return M.get(explicit)
  end
  local session_id = M.session_of_argv(argv)
  local name = session_id and M.of(session_id)
  if name then
    return M.get(name)
  end
  return M.default()
end

---`ANTHROPIC_CUSTOM_HEADERS` with the workspace header set, keeping every other
---header the user sends. The CLI reads it as `Name: Value` lines.
---@param existing string|nil
---@param workspace string
---@return string
function M.custom_headers(existing, workspace)
  local lines = {}
  for line in tostring(existing or ""):gmatch("[^\r\n]+") do
    if not line:lower():match("^%s*anthropic%-workspace%-id%s*:") then
      lines[#lines + 1] = line
    end
  end
  lines[#lines + 1] = "anthropic-workspace-id: " .. workspace
  return table.concat(lines, "\n")
end

---What a profile adds to a launch.
---@param profile ClaudeCodeProfile|nil
---@param argv string[] The command as built so far (an explicit `--model` wins).
---@return { args: string, env: table<string,string>, settings: table, workspace: string|nil }|nil
function M.launch_parts(profile, argv)
  if type(profile) ~= "table" then
    return nil
  end
  if profile.backend == "opencode" then
    -- OpenCode keeps its own credentials, so nothing is blanked or injected; the
    -- model and agent are set on the session through the API (the TUI has no
    -- flag for either), so they travel separately from the arguments.
    local env = {}
    for key, value in pairs(type(profile.env) == "table" and profile.env or {}) do
      env[key] = value
    end
    local provider, model = nil, nil
    if type(profile.model) == "string" then
      provider, model = profile.model:match("^([^/]+)/(.+)$")
    end
    return {
      args = (type(profile.args) == "string" and profile.args) or "",
      env = env,
      settings = nil,
      workspace = nil,
      model = provider and { providerID = provider, id = model } or nil,
      agent = (type(profile.agent) == "string" and profile.agent ~= "") and profile.agent or nil,
    }
  end
  local blank = { ANTHROPIC_API_KEY = "", ANTHROPIC_AUTH_TOKEN = "" }
  if profile.auth == "api" then
    blank.CLAUDE_CODE_OAUTH_TOKEN = ""
  end
  local env = vim.deepcopy(blank)
  local settings = { env = vim.deepcopy(blank) }
  settings.apiKeyHelper = profile.auth == "api" and M.helper_command(profile) or ""
  for key, value in pairs(type(profile.env) == "table" and profile.env or {}) do
    env[key] = value
  end

  local args = {}
  if type(profile.model) == "string" and profile.model ~= "" and not has_flag(argv, "--model") then
    args[#args + 1] = "--model " .. utils.shell_quote(profile.model)
  end
  if type(profile.args) == "string" and profile.args ~= "" then
    args[#args + 1] = profile.args
  end
  return {
    args = table.concat(args, " "),
    env = env,
    settings = settings,
    workspace = (type(profile.workspace) == "string" and profile.workspace ~= "") and profile.workspace or nil,
  }
end

--------------------------------------------------------------------------------
-- Is the key there? (asked of the helper, so the key never enters Neovim)
--------------------------------------------------------------------------------

---@class ClaudeCodeProfileCheck
---@field state "found"|"missing"|"error"
---@field shape string|nil `ok` | `unexpected` | `invalid` | `empty` when found.
---@field length integer|nil
---@field detail string|nil What went wrong.
---@field at number

--- [profile name] = last check
---@type table<string, ClaudeCodeProfileCheck>
local checks = {}

--- Injectable so specs drive checks without a process. Without a callback it
--- returns the job, whose `:wait()` answers.
M._system = function(argv, callback)
  return vim.system(argv, { text = true }, callback)
end

---@param res { code: integer, stdout: string|nil, stderr: string|nil }
---@return ClaudeCodeProfileCheck
function M._parse_check(res)
  local out = res.stdout or ""
  local length, shape = out:match("^found (%d+) (%S+)")
  if res.code == 0 and length then
    return { state = "found", length = tonumber(length), shape = shape, at = os.time() }
  end
  if out:match("^missing") then
    return { state = "missing", at = os.time() }
  end
  local detail = (res.stderr or ""):gsub("%s+$", "")
  return { state = "error", detail = detail ~= "" and detail or ("exit " .. tostring(res.code)), at = os.time() }
end

---The last check of a profile's key, if recent.
---@param name string
---@return ClaudeCodeProfileCheck|nil
function M.check_state(name)
  local check = checks[name]
  if check and os.time() - check.at <= CHECK_TTL then
    return check
  end
  return nil
end

---The helper command line that checks an api profile's key without printing it.
---@param profile ClaudeCodeProfile
---@return string[]
function M.check_argv(profile)
  local nvim_bin = (vim.v and vim.v.progpath) or "nvim"
  local argv = { nvim_bin, "--headless", "-u", "NONE", "-l", M.helper_script() }
  if type(profile.api_key_cmd) == "string" and profile.api_key_cmd ~= "" then
    argv[#argv + 1] = "check-cmd"
    argv[#argv + 1] = profile.api_key_cmd
  else
    argv[#argv + 1] = "check"
    argv[#argv + 1] = profile.keychain
  end
  return argv
end

---Check an api profile's key and wait for the answer (`:checkhealth`, which is
---synchronous).
---@param profile ClaudeCodeProfile
---@return ClaudeCodeProfileCheck
function M.check_sync(profile)
  local ok, result = pcall(function()
    return M._system(M.check_argv(profile)):wait(15000)
  end)
  if not ok or type(result) ~= "table" then
    return { state = "error", detail = tostring(result), at = os.time() }
  end
  local check = M._parse_check(result)
  checks[profile.name] = check
  return check
end

---Ask whether an api profile's key is there. Answers on the main loop; a
---subscription profile is answered at once with nil.
---@param profile ClaudeCodeProfile
---@param callback fun(check: ClaudeCodeProfileCheck|nil)
function M.check(profile, callback)
  if type(profile) ~= "table" or profile.auth ~= "api" then
    callback(nil)
    return
  end
  local argv = M.check_argv(profile)
  local ok, err = pcall(M._system, argv, function(res)
    vim.schedule(function()
      local check = M._parse_check(res)
      checks[profile.name] = check
      callback(check)
    end)
  end)
  if not ok then
    local check = { state = "error", detail = tostring(err), at = os.time() }
    checks[profile.name] = check
    callback(check)
  end
end

---What to tell the user when a profile's key is not stored.
---@param profile ClaudeCodeProfile
---@return string
function M.missing_message(profile)
  if profile.api_key_cmd then
    return string.format("Profile %q: its api_key_cmd printed no key.", profile.name)
  end
  local api_key = require("claude_agents.api_key")
  return string.format(
    "Profile %q has no API key stored. Store it once, in a terminal, with:\n  %s",
    profile.name,
    api_key.store_command(profile.keychain)
  )
end

---Whether a launch under this profile should be refused: its key is known to
---be missing. A check still running, or one that failed some other way, does
---not stop a launch — the CLI says what is wrong itself.
---@param profile ClaudeCodeProfile|nil
---@return boolean refused
function M.refuse_if_missing(profile)
  local check = profile and M.check_state(profile.name)
  if check and check.state == "missing" then
    vim.notify("ClaudeCode: " .. M.missing_message(profile), vim.log.levels.ERROR)
    return true
  end
  return false
end

---Test/reload helper.
function M._reset()
  profiles = vim.deepcopy(M.BUILTIN)
  default_name = nil
  sessions, loaded, stamp = {}, false, nil
  tab_profiles, pending_tab, checks = {}, {}, {}
end

return M
