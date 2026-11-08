---@brief [[
--- The few lines of "what the command printed before the pipe" a float shows
--- (`agents/live_output`).
---
--- Real lines in the shell and tool floats — they can be searched and yanked,
--- and a panel is only ever a handful of lines rewritten a few times a second.
--- Virtual lines in a subagent's transcript, which is rewritten from its first
--- changed line on every tick and keeps folds: lines inserted there would make
--- each of those rewrites start above them.
---@brief ]]
---@module 'claude_agents.agents.live_panel'

local ansi = require("claude_agents.agents.ansi")
local live_output = require("claude_agents.agents.live_output")
local tools = require("claude_agents.agents.tools")
local utils = require("claude_agents.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("claudecode_agents_live_panel")

--- Longest command label the panel's rule carries.
local LABEL_LIMIT = 48

---`1,204`.
---@param n integer
---@return string
local function grouped(n)
  local text = tostring(math.floor(n))
  while true do
    local next_text, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    text = next_text
    if count == 0 then
      return text
    end
  end
end

---@param name string
---@return string
local function hl(name)
  local ok, render = pcall(require, "claude_agents.agents.render")
  return ok and render.highlight(name) or "Comment"
end

---The panel's rule: which command, and how much it has printed.
---@param out ClaudeCodeLiveOutput
---@return string
function M.header(out)
  local parts = { utils.truncate(out.label:gsub("%s+", " "), LABEL_LIMIT), "before the pipe" }
  parts[#parts + 1] = out.total == 1 and "1 line" or (grouped(out.total) .. " lines")
  return tools.rule(table.concat(parts, " · "))
end

---A panel's lines and marks, rows counted from its first line; nothing when
---there is nothing to show.
---@param out ClaudeCodeLiveOutput|nil
---@return string[] lines
---@return table[] marks
function M.build(out)
  if not out or #out.lines == 0 then
    return {}, {}
  end
  local body, body_marks = ansi.parse(out.lines)
  local header = M.header(out)
  local lines = { header }
  local marks = { { row = 0, col = 0, end_col = #header, hl = hl("time") } }
  for _, line in ipairs(body) do
    lines[#lines + 1] = line
  end
  for _, mark in ipairs(body_marks) do
    marks[#marks + 1] = { row = mark.row + 1, col = mark.col, end_col = mark.end_col, hl = mark.hl }
  end
  lines[#lines + 1] = ""
  return lines, marks
end

---The same panel as virtual lines, quiet, under a line of a transcript.
---@param out ClaudeCodeLiveOutput|nil
---@param indent string|nil
---@return table[]|nil virt_lines
function M.virt_lines(out, indent)
  if not out or #out.lines == 0 then
    return nil
  end
  indent = indent or "  "
  local quiet = hl("time")
  local body = ansi.parse(out.lines)
  local virt = { { { indent .. M.header(out), quiet } } }
  for _, line in ipairs(body) do
    virt[#virt + 1] = { { indent .. line, quiet } }
  end
  return virt
end

--------------------------------------------------------------------------------
-- A panel of real lines in a buffer
--------------------------------------------------------------------------------

local attached = 0

---@param buf integer
---@param fn fun()
local function with_modifiable(buf, fn)
  local ok_get, was = pcall(vim.api.nvim_get_option_value, "modifiable", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(fn)
  pcall(vim.api.nvim_set_option_value, "modifiable", ok_get and was or false, { buf = buf })
end

---Keep a call's panel at a row of a buffer, as its output changes.
---
---It takes no lines until there is something to show, and says how many it
---took or gave back through `on_resize`, so the owner can move what it keeps
---below it.
---@param buf integer
---@param opts { row: integer|(fun(): integer), session_id: string?, tool_id: string,
---             hint: { command: string?, at: number? }?, on_resize: (fun(delta: integer))? }
---@return { rows: integer, detach: fun() }
function M.attach(buf, opts)
  attached = attached + 1
  local name = "live_panel:" .. attached
  local panel = { rows = 0 }
  local shown

  function panel.detach()
    live_output.on_change(name, nil)
  end

  local function paint()
    if not vim.api.nvim_buf_is_valid(buf) then
      return panel.detach()
    end
    local lines, marks = M.build(live_output.get(opts.session_id, opts.tool_id, opts.hint))
    local key = table.concat(lines, "\n")
    if key == shown then
      return
    end
    shown = key
    local row = type(opts.row) == "function" and opts.row() or opts.row
    local before = panel.rows
    with_modifiable(buf, function()
      vim.api.nvim_buf_set_lines(buf, row, row + before, false, lines)
    end)
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, row, row + math.max(before, #lines))
    for _, mark in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row + mark.row, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        priority = 100,
      })
    end
    panel.rows = #lines
    if panel.rows ~= before and opts.on_resize then
      opts.on_resize(panel.rows - before)
    end
  end

  panel.paint = paint
  live_output.on_change(name, function(changed)
    if changed[opts.tool_id] then
      paint()
    end
  end)
  pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf,
    once = true,
    callback = panel.detach,
  })
  paint()
  return panel
end

return M
