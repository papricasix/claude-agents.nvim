---@brief [[
--- The launch-profile menu: which account a Claude starts (or carries on) under.
---
--- One window for every door — `ga`/`gi` in the agents view, `:ClaudeCodeProfile`
--- for a tab's Claude — so they look and answer the same. Single-key like the
--- `gs` menu (each profile's `key`, `<CR>` on the cursor row), floated by
--- `menu_float`.
---
--- An api profile's row says whether its key is stored, asked of the helper
--- script when the menu opens (`profiles.check`) so the key never passes through
--- Neovim; the row repaints when the answer lands.
---@brief ]]
---@module 'claude_agents.profile_menu'

local profiles = require("claude_agents.profiles")

local M = {}

--- Same glyph the agents view marks its selected row with.
local CURRENT_MARK = "❯"
local FOOTER = "<CR> takes the row · q cancels"

local GROUPS = {
  ClaudeCodeProfileKey = "Special",
  ClaudeCodeProfileCurrent = "Title",
  ClaudeCodeProfileNote = "Comment",
  ClaudeCodeProfileWarn = "DiagnosticWarn",
}

local function define_groups()
  for group, link in pairs(GROUPS) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
end

---@type { win: integer|nil, buf: integer|nil, close: fun()|nil, repaint: fun()|nil }|nil
local shown = nil

---What a profile's row says after its name.
---@param profile ClaudeCodeProfile
---@param note string|nil The caller's word on it ("last run", "running").
---@return string text
---@return string|nil warn A problem worth its own colour.
local function trailer(profile, note)
  local parts = {}
  if note and note ~= "" then
    parts[#parts + 1] = note
  end
  local warn
  if profile.backend == "opencode" then
    parts[#parts + 1] = "OpenCode"
    if type(profile.model) == "string" and profile.model ~= "" then
      parts[#parts + 1] = profile.model
    end
    if type(profile.agent) == "string" and profile.agent ~= "" then
      parts[#parts + 1] = profile.agent
    end
  end
  if profile.auth == "api" then
    local check = profiles.check_state(profile.name)
    if not check then
      parts[#parts + 1] = "checking key…"
    elseif check.state == "missing" then
      warn = "no key stored"
    elseif check.state == "error" then
      warn = "key check failed"
    elseif check.shape ~= "ok" then
      warn = "key looks unusual"
    end
  end
  return table.concat(parts, " · "), warn
end

---Lines, highlights, and which line offers which profile.
---@param list ClaudeCodeProfile[]
---@param opts { current: string|nil, notes: table<string, string>|nil }
---@return string[] lines
---@return table[] marks `{ row, col, end_col, hl }`, 0-based rows.
---@return table<integer, string> by_line 1-based line -> profile name
function M.render(list, opts)
  local notes = opts.notes or {}
  local name_width, mark_width = 0, 0
  for _, profile in ipairs(list) do
    name_width = math.max(name_width, vim.fn.strdisplaywidth(profile.name))
    mark_width = math.max(mark_width, vim.fn.strdisplaywidth(profiles.mark(profile)))
  end

  local lines, marks, by_line = { "" }, {}, {}
  for _, profile in ipairs(list) do
    local is_current = opts.current ~= nil and profile.name == opts.current
    local gutter = is_current and (CURRENT_MARK .. " ") or "  "
    local accel = profile.key or " "
    local name_pad = string.rep(" ", name_width - vim.fn.strdisplaywidth(profile.name))
    local mark = profiles.mark(profile)
    local mark_pad = string.rep(" ", mark_width - vim.fn.strdisplaywidth(mark))
    local note, warn = trailer(profile, notes[profile.name])
    local tail = note
    if warn then
      tail = (tail ~= "" and (tail .. " · ") or "") .. warn
    end

    local line = gutter .. accel .. "  " .. profile.name
    local row = #lines
    local accel_at = #gutter
    local name_at = accel_at + #accel + 2
    if mark ~= "" or tail ~= "" then
      line = line .. name_pad .. (mark_width > 0 and ("   " .. mark .. mark_pad) or "")
      local mark_at = #line - #mark - #mark_pad
      if mark ~= "" then
        marks[#marks + 1] = { row = row, col = mark_at, end_col = mark_at + #mark, hl = "ClaudeCodeProfileMark" }
      end
      if tail ~= "" then
        local tail_at = #line + 3
        line = line .. "   " .. tail
        local warn_at = warn and (#line - #warn) or #line
        if warn_at > tail_at then
          marks[#marks + 1] = { row = row, col = tail_at, end_col = warn_at, hl = "ClaudeCodeProfileNote" }
        end
        if warn then
          marks[#marks + 1] = { row = row, col = warn_at, end_col = #line, hl = "ClaudeCodeProfileWarn" }
        end
      end
    end
    lines[#lines + 1] = line
    by_line[#lines] = profile.name

    if is_current then
      marks[#marks + 1] = { row = row, col = 0, end_col = #CURRENT_MARK, hl = "ClaudeCodeProfileCurrent" }
    end
    if profile.key then
      marks[#marks + 1] = { row = row, col = accel_at, end_col = accel_at + #accel, hl = "ClaudeCodeProfileKey" }
    end
    marks[#marks + 1] = {
      row = row,
      col = name_at,
      end_col = name_at + #profile.name,
      hl = is_current and "ClaudeCodeProfileCurrent" or "Normal",
    }
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. FOOTER
  marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], hl = "ClaudeCodeProfileNote" }
  return lines, marks, by_line
end

---@param buf integer
---@param lines string[]
---@param marks table[]
local function paint(buf, lines, marks)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ns = vim.api.nvim_create_namespace("claudecode_profile_menu")
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
  end
end

---Close the open menu, if any.
function M.close()
  local open = shown
  shown = nil
  if not open then
    return
  end
  if open.close then
    pcall(open.close)
  end
  if open.buf and vim.api.nvim_buf_is_valid(open.buf) then
    pcall(vim.api.nvim_buf_delete, open.buf, { force = true })
  end
end

---@return boolean
function M.is_open()
  return shown ~= nil and shown.win ~= nil and vim.api.nvim_win_is_valid(shown.win)
end

---Show the menu. A second call while it is open closes it.
---@param opts { title: string, current: string|nil, notes: table<string, string>|nil, on_pick: fun(name: string) }
---  `current` is the row the cursor starts on and the one marked `❯`; `notes`
---  adds a word to a row by profile name.
---@return boolean shown
function M.open(opts)
  if M.is_open() then
    M.close()
    return false
  end
  shown = nil
  local list = profiles.list()
  if #list == 0 then
    vim.notify("ClaudeCode: no launch profiles are configured", vim.log.levels.WARN)
    return false
  end
  define_groups()

  local lines, marks, by_line = M.render(list, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    return false
  end
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-profiles", { buf = buf })
  paint(buf, lines, marks)

  -- Answered at most once, however the window goes away; out of the closing
  -- keymap, since what comes next opens windows and starts processes.
  local answered = false
  local function pick(name)
    if answered or not name then
      return
    end
    answered = true
    M.close()
    vim.schedule(function()
      pcall(opts.on_pick, name)
    end)
  end
  for _, profile in ipairs(list) do
    if profile.key then
      pcall(vim.keymap.set, "n", profile.key, function()
        pick(profile.name)
      end, { buffer = buf, nowait = true, silent = true, desc = "Claude: run as " .. profile.name })
    end
  end
  pcall(vim.keymap.set, "n", "<CR>", function()
    local win = shown and shown.win
    local lnum = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_cursor(win)[1] or 1
    pick(by_line[lnum])
  end, { buffer = buf, nowait = true, silent = true, desc = "Claude: run as the profile under the cursor" })

  local lnum = 2
  for line, name in pairs(by_line) do
    if name == opts.current then
      lnum = line
    end
  end

  local float = require("claude_agents.menu_float").open(buf, {
    title = opts.title,
    lines = lines,
    lnum = lnum,
    on_dismiss = function()
      if shown and shown.buf then
        M.close()
      else
        shown = nil
      end
    end,
  })
  if not float then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end
  shown = float

  -- Ask after whether each api profile's key is there; repaint as answers land.
  for _, profile in ipairs(list) do
    if profile.auth == "api" and not profiles.check_state(profile.name) then
      profiles.check(profile, function()
        if shown == float and vim.api.nvim_buf_is_valid(buf) then
          local fresh_lines, fresh_marks = M.render(list, opts)
          paint(buf, fresh_lines, fresh_marks)
        end
      end)
    end
  end
  return true
end

return M
