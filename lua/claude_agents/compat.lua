--- The plugin's former module name, `claudecode`, kept working.
---
--- The fork renamed its Lua module to `claude_agents` so that lazy.nvim finds it
--- from the repository's name (claude-agents.nvim) without a `main` field.
--- Configs written for upstream claudecode.nvim, or for this fork before the
--- rename, still say `require("claudecode")` or `require("claudecode.status")`:
--- a package loader maps every such name onto its `claude_agents` module, so
--- both names hand out the very same table, and the first use warns once.
---@module 'claude_agents.compat'
local M = {}

local OLD = "claudecode"
local NEW = "claude_agents"

local warned = false

local function warn_once(name)
  if warned then
    return
  end
  warned = true
  vim.schedule(function()
    vim.notify(
      ("claude-agents.nvim: the Lua module is now %q; require(%q) still works, but rename it in your config."):format(
        NEW,
        name
      ),
      vim.log.levels.WARN
    )
  end)
end

---The `claude_agents` name for an old module name, or nil if it is not one.
---@param name string
---@return string|nil
function M.new_name(name)
  if name == OLD then
    return NEW
  end
  if name:sub(1, #OLD + 1) == OLD .. "." then
    return NEW .. name:sub(#OLD + 1)
  end
  return nil
end

---Load an old module name through its new one: same table, cached under both.
---@param name string
---@return any
function M.load(name)
  local new = M.new_name(name)
  warn_once(name)
  local mod = require(new)
  package.loaded[name] = mod
  return mod
end

local function searcher(name)
  if M.new_name(name) == nil then
    return nil
  end
  return function()
    return M.load(name)
  end
end

---Make `package.loaded["claudecode.<mod>"]` answer with the loaded
---`claude_agents` module. Configs look a module up there to act only when it is
---already loaded (a session manager's save hook, say), and that lookup never
---reaches a loader: without this it found nothing after the rename and the
---hook silently did nothing. Keys are only answered, never stored, and any
---`__index` already on the table is kept behind this one.
local function alias_loaded()
  local loaded = package.loaded
  local mt = getmetatable(loaded)
  if mt and mt.__claude_agents_alias then
    return
  end
  if not mt then
    mt = {}
    setmetatable(loaded, mt)
  end
  local previous = mt.__index
  mt.__claude_agents_alias = true
  mt.__index = function(t, key)
    local new = type(key) == "string" and M.new_name(key) or nil
    local mod = new and rawget(t, new)
    if mod ~= nil then
      warn_once(key)
      return mod
    end
    if type(previous) == "function" then
      return previous(t, key)
    elseif type(previous) == "table" then
      return previous[key]
    end
    return nil
  end
end

---Install the loader and the `package.loaded` alias, once. Neovim runs LuaJIT
---or Lua 5.1, whose searcher list is `package.loaders`.
function M.install()
  alias_loaded()
  local loaders = package.loaders
  for _, loader in ipairs(loaders) do
    if loader == searcher then
      return
    end
  end
  table.insert(loaders, searcher)
end

---For the specs: forget that the warning was given.
function M._reset()
  warned = false
end

return M
