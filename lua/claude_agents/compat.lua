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

---Install the loader once. Neovim runs LuaJIT or Lua 5.1, whose searcher list
---is `package.loaders`.
function M.install()
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
