---@brief [[
--- A small centred float over a buffer we rendered ourselves: the shell of the
--- single-key menus (`gs` in the agents view, the launch-profile menu).
---
--- Floated by `snacks.win` when snacks is there and by `nvim_open_win`
--- otherwise, so both paths look identical inside the border. `q` and `<Esc>`
--- dismiss it either way; what the keys inside it do is the caller's business.
---@brief ]]
---@module 'claude_agents.menu_float'

local utils = require("claude_agents.utils")

local M = {}

---@class ClaudeCodeMenuFloat
---@field win integer
---@field buf integer|nil The buffer, when it is ours to delete (snacks owns it otherwise).
---@field close fun()

---Size the float to its lines, within the editor.
---@param lines string[]
---@return integer width, integer height
function M.dimensions(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local columns = vim.o.columns or 80
  local rows = vim.o.lines or 24
  return math.max(24, math.min(width + 2, math.floor(columns * 0.8))), math.min(#lines, math.floor(rows * 0.8))
end

---@param buf integer
---@param opts { title: string, lines: string[], lnum: integer, on_dismiss: fun()|nil }
---@return ClaudeCodeMenuFloat|nil
local function open_snacks(buf, opts)
  local ok, snacks_win = pcall(require, "snacks.win")
  if not ok or type(snacks_win) ~= "table" then
    return nil
  end
  local width, height = M.dimensions(opts.lines)
  local win = snacks_win({
    buf = buf,
    title = " " .. opts.title .. " ",
    title_pos = "center",
    border = "rounded",
    width = width,
    height = height,
    enter = true,
    backdrop = 60,
    zindex = 60,
    wo = { wrap = false, cursorline = true },
    keys = {
      q = "close",
      ["<Esc>"] = "close",
    },
    on_close = function()
      if opts.on_dismiss then
        opts.on_dismiss()
      end
    end,
  })
  if not win then
    return nil
  end
  pcall(vim.api.nvim_win_set_cursor, win.win, { opts.lnum, 0 })
  return {
    win = win.win,
    -- snacks owns the buffer's lifetime once it is handed over.
    buf = nil,
    close = function()
      win:close()
    end,
  }
end

---@param buf integer
---@param opts { title: string, lines: string[], lnum: integer, on_dismiss: fun()|nil }
---@return ClaudeCodeMenuFloat|nil
local function open_native(buf, opts)
  local width, height = M.dimensions(opts.lines)
  local columns = vim.o.columns or 80
  local rows = vim.o.lines or 24
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height) / 2) - 1),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    zindex = 60,
  })
  if not ok or not win then
    return nil
  end
  utils.set_win_option(win, "cursorline", true)
  pcall(vim.api.nvim_win_set_cursor, win, { opts.lnum, 0 })
  local handle = {
    win = win,
    buf = buf,
    close = function()
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end,
  }
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    pcall(vim.keymap.set, "n", lhs, function()
      if opts.on_dismiss then
        opts.on_dismiss()
      else
        handle.close()
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "Close this menu" })
  end
  return handle
end

---Float a menu buffer.
---
---`on_dismiss` is called when the user dismisses it (`q`, `<Esc>`, or snacks
---closing it some other way); it is expected to close the float, which a native
---float's `q` does by itself when there is no such callback.
---@param buf integer
---@param opts { title: string, lines: string[], lnum: integer, on_dismiss: fun()|nil }
---@return ClaudeCodeMenuFloat|nil
function M.open(buf, opts)
  return open_snacks(buf, opts) or open_native(buf, opts)
end

return M
