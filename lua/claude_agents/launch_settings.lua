---@brief [[
--- One `--settings` file per launch.
---
--- The CLI reads exactly one `--settings`: **a second one replaces the first
--- entirely**, hooks and env included, whichever order they come in (measured
--- against CLI 2.1.300 with two files each registering a `SessionStart` hook and
--- an env var — only the last file's hook ran and only its variable was set).
---
--- Four parties want settings on a launch: the plugin's hooks (status, live
--- cursor, plan view, agents mode), the plugin's own CLI settings (`bash_changes`
--- asks for `bashEditDiffEnabled`), a launch profile (`apiKeyHelper` and the env
--- that decides which account pays), and the user, through a `--settings` of
--- their own in `terminal_cmd` or `:ClaudeCode` arguments. Appending one flag per
--- party let the last one silently win: the user's own settings were dropped on
--- every launch the hooks were injected into, and a profile's flag would either
--- have killed the hooks or been killed by them — a session quietly running on
--- the wrong account. So the user's settings are read, the other two merged into
--- them, and the command carries one flag naming the result.
---@brief ]]
---@module 'claude_agents.launch_settings'

local logger = require("claude_agents.logger")
local utils = require("claude_agents.utils")

local M = {}

local FLAG = "--settings"

---Split the user's own `--settings` out of an argument vector.
---
---Both spellings the CLI accepts: `--settings <value>` and `--settings=<value>`.
---@param argv string[]
---@return string[] rest The vector without them.
---@return string[] sources Their values, in order.
function M.extract(argv)
  local rest, sources = {}, {}
  local i = 1
  while i <= #argv do
    local word = argv[i]
    if word == FLAG then
      if argv[i + 1] ~= nil then
        sources[#sources + 1] = argv[i + 1]
      end
      i = i + 2
    elseif word:sub(1, #FLAG + 1) == FLAG .. "=" then
      sources[#sources + 1] = word:sub(#FLAG + 2)
      i = i + 1
    else
      rest[#rest + 1] = word
      i = i + 1
    end
  end
  return rest, sources
end

---Read one `--settings` value: inline JSON, or a path to a JSON file.
---
---The CLI tells the two apart the same way (an object starts with `{`), and
---resolves a relative path against its own working directory — the directory the
---terminal is spawned in, which the caller passes.
---@param source string
---@param cwd string|nil
---@return table|nil settings
---@return string|nil err
function M.load(source, cwd)
  local text = source:gsub("^%s+", "")
  if text:sub(1, 1) ~= "{" then
    local path = utils.expand_tilde(source)
    local absolute = path:match("^/") or path:match("^%a:[/\\]") or path:match("^[/\\][/\\]")
    if not absolute and type(cwd) == "string" and cwd ~= "" then
      path = cwd .. "/" .. path
    end
    local f = io.open(path, "r")
    if not f then
      return nil, "cannot read " .. path
    end
    text = f:read("*a") or ""
    f:close()
  end
  local ok, decoded = pcall(vim.json.decode, text)
  -- An array decodes to a table too; settings are an object.
  if not ok or type(decoded) ~= "table" or decoded[1] ~= nil then
    return nil, "not a JSON object: " .. source
  end
  return decoded, nil
end

---Merge the plugin's hooks, its own settings and a profile's into the user's.
---
---The user's settings are the base: whatever they set stays set. Hooks are
---**added** per event (theirs run, ours run too). The plugin's own settings fill
---in only what the user left unset — a `bashEditDiffEnabled = false` of theirs
---stands. A profile's `apiKeyHelper` and `env` entries win, because choosing a
---profile is choosing which account pays, and a user-level helper or key left in
---force would quietly bill another one.
---@param user table|nil
---@param hooks table|nil `{ hooks = { [event] = { entry, ... } } }`
---@param profile table|nil `{ apiKeyHelper = string|nil, env = table|nil }`
---@param defaults table|nil Top-level settings the plugin wants, e.g. `{ bashEditDiffEnabled = true }`.
---@return table
function M.merge(user, hooks, profile, defaults)
  local out = vim.deepcopy(type(user) == "table" and user or {})
  if type(defaults) == "table" then
    for key, value in pairs(defaults) do
      if out[key] == nil then
        out[key] = value
      end
    end
  end
  if type(hooks) == "table" and type(hooks.hooks) == "table" then
    if type(out.hooks) ~= "table" then
      out.hooks = {}
    end
    for event, entries in pairs(hooks.hooks) do
      local list = type(out.hooks[event]) == "table" and out.hooks[event] or {}
      for _, entry in ipairs(entries) do
        list[#list + 1] = entry
      end
      out.hooks[event] = list
    end
  end
  if type(profile) == "table" then
    if profile.apiKeyHelper ~= nil then
      out.apiKeyHelper = profile.apiKeyHelper
    end
    if type(profile.env) == "table" and next(profile.env) ~= nil then
      if type(out.env) ~= "table" then
        out.env = {}
      end
      for key, value in pairs(profile.env) do
        out.env[key] = value
      end
    end
  end
  return out
end

---Give a launch command exactly one `--settings`.
---
---Untouched when neither the hooks, the plugin's settings nor the profile has
---anything to add: a user's own flag then stays exactly as they wrote it.
---Otherwise the user's flags are read and removed, and one flag naming the merged
---file is appended. A flag of theirs that cannot be read is reported and left out
---— it would have been replaced by ours anyway, which is what every launch did
---before this existed.
---@param cmd_string string
---@param parts { hooks: table|nil, defaults: table|nil, profile: table|nil, cwd: string|nil, write: fun(settings: table): string|nil }
---@return string cmd_string
function M.apply(cmd_string, parts)
  local has_hooks = type(parts.hooks) == "table"
  local defaults = type(parts.defaults) == "table" and next(parts.defaults) ~= nil and parts.defaults or nil
  local profile = parts.profile
  local has_profile = type(profile) == "table"
    and (profile.apiKeyHelper ~= nil or (type(profile.env) == "table" and next(profile.env) ~= nil))
  if not has_hooks and not defaults and not has_profile then
    return cmd_string
  end

  local argv = utils.shell_split(cmd_string)
  local rest, sources = M.extract(argv)
  local user = nil
  if #sources > 0 then
    -- The CLI would read the last one alone; so do we.
    local source = sources[#sources]
    local loaded, err = M.load(source, parts.cwd)
    if loaded then
      user = loaded
    else
      logger.error(
        "terminal",
        "Your --settings could not be read and is left out of this launch (" .. tostring(err) .. ")"
      )
    end
  end

  local path = parts.write(M.merge(user, parts.hooks, has_profile and profile or nil, defaults))
  if not path then
    -- Nothing to point at: hand back what the user asked for rather than a launch
    -- missing their settings too.
    return cmd_string
  end

  local words = {}
  if #sources > 0 then
    for _, word in ipairs(rest) do
      words[#words + 1] = utils.shell_quote(word)
    end
  else
    -- Nothing removed, so the user's own quoting stands as written.
    words[1] = cmd_string
  end
  words[#words + 1] = FLAG .. " " .. utils.shell_quote(path)
  return table.concat(words, " ")
end

return M
