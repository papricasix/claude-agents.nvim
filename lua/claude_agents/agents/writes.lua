---@brief [[
--- The files this Neovim wrote, and when.
---
--- A shell command's changes are what changed in the repository while it ran
--- (`transcript`'s `fold_bash_changes`), by the command or by anyone else. The
--- view can name some of the others — the other conversations it lists, and the
--- subagents of the selected one, from their own transcripts — and one more: this
--- editor, saving a buffer while an agent's command was running. That is the user
--- at work in the same tree, which is the ordinary case, and nothing in any
--- transcript records it.
---
--- `BufWritePost`, so a write that failed is not counted. The time is wall clock
--- with its fraction, the same clock the CLI stamps its transcript with. Kept in
--- memory only and for a bounded number of writes per file: the question is only
--- ever asked of a command's window, and a command older than this Neovim cannot
--- have been overlapped by its writes.
---@brief ]]
---@module 'claude_agents.agents.writes'

local utils = require("claude_agents.utils")

local M = {}

--- Writes remembered per file. A command's window is seconds to minutes; this many
--- saves of one file inside one of them is more than anyone types.
local KEEP = 32

--- [path key] = epoch seconds with their fraction, oldest first.
---@type table<string, number[]>
local by_file = {}

---@type integer|nil
local group = nil

---Now, in epoch seconds with the fraction. Injectable so a spec can set the clock.
---@return number
M._now = function()
  local uv = vim.uv or vim.loop
  local ok, sec, usec = pcall(function()
    return uv.gettimeofday()
  end)
  if ok and type(sec) == "number" then
    return sec + (tonumber(usec) or 0) / 1e6
  end
  return os.time()
end

---Record that `path` was written now.
---@param path string Absolute path.
---@param at number|nil Epoch seconds; now when omitted.
function M.note(path, at)
  if type(path) ~= "string" or path == "" then
    return
  end
  local key = utils.path_key(path)
  local list = by_file[key] or {}
  by_file[key] = list
  list[#list + 1] = at or M._now()
  if #list > KEEP then
    table.remove(list, 1)
  end
end

---Whether this Neovim wrote `path` between `from` and `to`, both included.
---@param path string
---@param from number Epoch seconds.
---@param to number Epoch seconds.
---@return boolean
function M.during(path, from, to)
  local list = type(path) == "string" and by_file[utils.path_key(path)] or nil
  for _, at in ipairs(list or {}) do
    if at >= from and at <= to then
      return true
    end
  end
  return false
end

---Start or stop listening. Armed while agents mode is enabled: a write made
---before the view was opened can still have landed inside a listed command.
---@param enabled boolean
function M.setup(enabled)
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
  if not enabled then
    return
  end
  local ok, id = pcall(vim.api.nvim_create_augroup, "ClaudeCodeAgentsWrites", { clear = true })
  if not ok then
    return
  end
  group = id
  pcall(vim.api.nvim_create_autocmd, "BufWritePost", {
    group = group,
    callback = function(args)
      local ok_name, name = pcall(vim.api.nvim_buf_get_name, args.buf)
      -- A scratch or special buffer writes no file of the project.
      if ok_name and name ~= "" and vim.bo[args.buf].buftype == "" then
        M.note(name)
      end
    end,
  })
end

---Forget everything (specs).
function M.reset()
  by_file = {}
end

return M
