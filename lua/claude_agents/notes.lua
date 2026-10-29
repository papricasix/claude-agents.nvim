---@brief [[
--- Notes the model leaves in a file it opens (`open_files`, `files[i].notes`):
--- a few lines drawn above the line they are about, so the user reads them in
--- place.
---
--- * Drawn as a callout of virtual lines: a bar, a header naming who wrote it
---   (`✻ Claude`, an agent's name, `◇ OpenCode`) and the note's title, then the
---   text — indented to the code, wrapped to the narrowest window showing the
---   buffer, `code` and **bold** rendered. Past `max_lines` the rest waits behind
---   `:ClaudeCodeNotes expand`.
--- * The lines a note is about carry `range_mark`: a bar in the sign column, a
---   background, or coloured line numbers.
--- * A note lives until the user clears it or the conversation that wrote it
---   sends new notes for that file. Each note is one extmark spanning its lines,
---   so edits carry it along. A reload (the CLI writing the file) does not move
---   extmarks, and by `BufReadPre` the old text is gone, so the buffer's text is
---   kept from before (`snapshot`) and the notes are carried through a diff of
---   the two on `BufReadPost`.
---@brief ]]
---@module 'claude_agents.notes'

local logger = require("claude_agents.logger")
local utils = require("claude_agents.utils")

local M = {}

M.DEFAULTS = {
  enabled = true,
  range_mark = "bar",
  max_lines = 8,
  max_width = 100,
  keymaps = { next = "]n", prev = "[n" },
}

M.RANGE_MARKS = { "bar", "background", "number" }

M.SUBCOMMANDS = { "list", "clear", "toggle", "next", "prev", "expand", "collapse" }

M.HL = {
  body = "ClaudeCodeNote",
  bar = "ClaudeCodeNoteBar",
  header = "ClaudeCodeNoteHeader",
  code = "ClaudeCodeNoteCode",
  bold = "ClaudeCodeNoteBold",
  more = "ClaudeCodeNoteMore",
  range = "ClaudeCodeNoteRange",
}

local BAR = "▎"

--- Narrowest a note's text is wrapped to, however deep the code is indented.
local MIN_WIDTH = 20

--- Below git and diagnostic signs (6 and 10): a note lives until dismissed, and
--- in a one-wide sign column it must not hide what those say about the line.
local PRIORITY = 5

local ns = vim.api.nvim_create_namespace("claudecode_notes")

---@class ClaudeCodeNote
---@field id integer|nil Extmark id: the extmark is where the note is.
---@field owner string Whose notes these are; new notes from the same owner replace them.
---@field writer string Header label: `✻ Claude`, `✻ plan-2`, `◇ OpenCode`.
---@field title string|nil
---@field text string
---@field expanded boolean
---@field snap_row integer|nil 1-based first line in the buffer's snapshot.
---@field snap_end integer|nil

---@class ClaudeCodeNotesBuffer
---@field notes ClaudeCodeNote[]
---@field snapshot string[]|nil The buffer's lines as of the last change we saw.
---@field group integer Augroup of the buffer's autocmds.
---@field keys table<string, boolean> Keys bound on the buffer.

local state = {
  hidden = false,
  ---@type table<integer, ClaudeCodeNotesBuffer>
  bufs = {},
  ---@type table<integer, boolean>
  pending = {},
  global_group = nil,
}

---@return table opts `M.DEFAULTS` under the user's `open_files.notes`.
function M.opts()
  local user = require("claude_agents.open_files").opts().notes
  return vim.tbl_deep_extend("force", vim.deepcopy(M.DEFAULTS), type(user) == "table" and user or {})
end

---@return boolean
function M.enabled()
  return require("claude_agents.open_files").enabled() and M.opts().enabled ~= false
end

---Defined on use: `:colorscheme` clears every group, a default link included.
local function define_highlights()
  local function set(name, spec)
    spec.default = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  set(M.HL.body, { link = "DiagnosticVirtualTextInfo" })
  set(M.HL.bar, { link = "DiagnosticInfo" })
  set(M.HL.header, { link = "DiagnosticInfo" })
  set(M.HL.code, { link = "String" })
  set(M.HL.bold, { bold = true })
  set(M.HL.more, { link = "Comment" })
  set(M.HL.range, { link = "Visual" })
end

--------------------------------------------------------------------------------
-- Reading a request
--------------------------------------------------------------------------------

---@param n any
---@return integer|nil
local function positive_int(n)
  if type(n) ~= "number" or n ~= n or n < 1 then
    return nil
  end
  return math.floor(n)
end

---@param text any
---@return string|nil
local function one_line(text)
  if type(text) ~= "string" then
    return nil
  end
  local out = vim.trim((text:gsub("%s+", " ")))
  return out ~= "" and out or nil
end

---A request's `notes`, checked.
---@param raw any
---@return { line: integer, end_line: integer|nil, title: string|nil, text: string }[]|nil notes
---@return string|nil err What is wrong, naming the entry (`notes[2] needs …`).
function M.parse(raw)
  if type(raw) ~= "table" then
    return nil, "notes must be a list of { line, end_line?, title?, text }"
  end
  local out = {}
  for i, entry in ipairs(raw) do
    local line = type(entry) == "table" and positive_int(entry.line) or nil
    local text = type(entry) == "table" and type(entry.text) == "string" and vim.trim(entry.text) or ""
    if not line or text == "" then
      return nil, ("notes[%d] needs a line and a text"):format(i)
    end
    local end_line = positive_int(entry.end_line)
    out[#out + 1] = {
      line = line,
      end_line = end_line and end_line > line and end_line or nil,
      title = one_line(entry.title),
      text = text,
    }
  end
  return out, nil
end

--------------------------------------------------------------------------------
-- Laying text out
--------------------------------------------------------------------------------

---@param text string
---@return integer
local function cells(text)
  return vim.api.nvim_strwidth(text)
end

---The inline runs of one line of a note: `code` spans, **bold**, plain text.
---Markup that is not closed is text.
---@param text string
---@param bold boolean|nil Inside `**`.
---@param out table|nil
---@return { text: string, code: boolean, bold: boolean }[]
function M._inline(text, bold, out)
  out = out or {}
  bold = bold == true
  local i, n, from = 1, #text, 1
  local function plain(to)
    if to >= from then
      out[#out + 1] = { text = text:sub(from, to), code = false, bold = bold }
    end
  end
  while i <= n do
    if text:sub(i, i) == "`" then
      local ticks = text:match("^`+", i)
      local close = text:find(ticks, i + #ticks, true)
      if close then
        plain(i - 1)
        local inner = text:sub(i + #ticks, close - 1)
        -- One space either side lets a span begin or end with a backtick.
        if inner:match("^ .* $") and inner:match("%S") then
          inner = inner:sub(2, -2)
        end
        out[#out + 1] = { text = inner, code = true, bold = bold }
        i = close + #ticks
        from = i
      else
        i = i + #ticks
      end
    elseif not bold and text:sub(i, i + 1) == "**" then
      local close = text:find("**", i + 2, true)
      if close and close > i + 2 then
        plain(i - 1)
        M._inline(text:sub(i + 2, close - 1), true, out)
        i = close + 2
        from = i
      else
        i = i + 2
      end
    else
      i = i + 1
    end
  end
  plain(n)
  return out
end

---Words of a line's runs: the pieces between spaces. A code span is never split.
---@param runs { text: string, code: boolean, bold: boolean }[]
---@return table[][]
local function words(runs)
  local list, cur = {}, nil
  local function add(piece)
    cur = cur or {}
    cur[#cur + 1] = piece
  end
  local function flush()
    if cur then
      list[#list + 1] = cur
      cur = nil
    end
  end
  for _, run in ipairs(runs) do
    if run.code then
      add(run)
    else
      local pos = 1
      while pos <= #run.text do
        local s, e = run.text:find("%s+", pos)
        if not s then
          add({ text = run.text:sub(pos), code = false, bold = run.bold })
          break
        end
        if s > pos then
          add({ text = run.text:sub(pos, s - 1), code = false, bold = run.bold })
        end
        flush()
        pos = e + 1
      end
    end
  end
  flush()
  return list
end

---@param line { pieces: table[], width: integer }
---@param text string
---@param piece { code: boolean|nil, bold: boolean|nil, style: string|nil }
local function push(line, text, piece)
  local code, bold, style = piece.code == true, piece.bold == true, piece.style
  local last = line.pieces[#line.pieces]
  if last and last.code == code and last.bold == bold and last.style == style then
    last.text = last.text .. text
  else
    line.pieces[#line.pieces + 1] = { text = text, code = code, bold = bold, style = style }
  end
  line.width = line.width + cells(text)
end

---One line of a note's text in lines of at most `width` cells. A list item's
---continuation lines hang under its text, not under its marker.
---@param source string
---@param width integer
---@return { pieces: table[], width: integer }[]
local function wrap(source, width)
  local lead = source:match("^%s*")
  local marker = source:match("^%s*[-*+]%s+") or source:match("^%s*%d+[.)]%s+")
  local hang = math.min(cells(marker or lead), math.floor(width / 2))
  local out, line, has_word = {}, nil, false
  local function new_line(prefix)
    line = { pieces = {}, width = 0 }
    if prefix > 0 then
      push(line, string.rep(" ", prefix), {})
    end
    has_word = false
    out[#out + 1] = line
  end
  new_line(math.min(cells(lead), hang))

  for _, word in ipairs(words(M._inline(source:sub(#lead + 1)))) do
    local word_width = 0
    for _, piece in ipairs(word) do
      word_width = word_width + cells(piece.text)
    end
    if has_word and line.width + 1 + word_width > width then
      new_line(hang)
    end
    if has_word then
      push(line, " ", {})
    end
    if line.width + word_width <= width then
      for _, piece in ipairs(word) do
        push(line, piece.text, piece)
      end
    else
      -- Longer than a line: cut across lines.
      for _, piece in ipairs(word) do
        for char in piece.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          if line.width + cells(char) > width and line.width > hang then
            new_line(hang)
          end
          push(line, char, piece)
        end
      end
    end
    has_word = true
  end
  return out
end

---A note's text as display lines of at most `width` cells. Paragraphs keep one
---blank line between them; a line break is kept.
---@param text string
---@param width integer
---@return { pieces: table[], width: integer }[]
function M._layout(text, width)
  text = text:gsub("\r", ""):gsub("\t", "  "):gsub("[%z\1-\8\11\12\14-\31\127]", "")
  local lines, gap = {}, false
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if raw:match("^%s*$") then
      gap = #lines > 0
    else
      if gap then
        lines[#lines + 1] = { pieces = {}, width = 0 }
        gap = false
      end
      vim.list_extend(lines, wrap(raw, width))
    end
  end
  return lines
end

---@param piece table
---@return string[]
local function groups(piece)
  local out = { M.HL.body }
  if piece.style == "header" then
    out[#out + 1] = M.HL.header
    out[#out + 1] = M.HL.bold
  elseif piece.style == "more" then
    out[#out + 1] = M.HL.more
  end
  if piece.code then
    out[#out + 1] = M.HL.code
  end
  if piece.bold then
    out[#out + 1] = M.HL.bold
  end
  return out
end

---@param note ClaudeCodeNote
---@param width integer
---@return { pieces: table[], width: integer }
local function header_line(note, width)
  local line = { pieces = {}, width = 0 }
  push(line, utils.truncate(note.writer, width), { style = "header" })
  local room = width - line.width - 3
  if note.title and room >= 2 then
    push(line, " · " .. utils.truncate(note.title, room), { bold = true })
  end
  return line
end

---The virtual lines of a note: a block of the body's colour, each line led by
---the bar, padded to the widest so the block has a straight right edge.
---@param note ClaudeCodeNote
---@param indent integer Cells before the bar.
---@param width integer Cells of text.
---@param max_lines integer
---@return table[][]
local function render_note(note, indent, width, max_lines)
  local body = M._layout(note.text, width)
  local more = 0
  if not note.expanded and #body > max_lines then
    more = #body - max_lines
    body = vim.list_slice(body, 1, max_lines)
  end
  local rows = { header_line(note, width) }
  vim.list_extend(rows, body)
  if more > 0 then
    local line = { pieces = {}, width = 0 }
    local text = ("… %d more line%s · :ClaudeCodeNotes expand"):format(more, more == 1 and "" or "s")
    push(line, utils.truncate(text, width), { style = "more" })
    rows[#rows + 1] = line
  end
  local block = 0
  for _, row in ipairs(rows) do
    block = math.max(block, row.width)
  end
  local out = {}
  for _, row in ipairs(rows) do
    local chunks = {}
    if indent > 0 then
      chunks[1] = { string.rep(" ", indent) }
    end
    chunks[#chunks + 1] = { BAR, M.HL.bar }
    chunks[#chunks + 1] = { " ", M.HL.body }
    for _, piece in ipairs(row.pieces) do
      chunks[#chunks + 1] = { piece.text, groups(piece) }
    end
    chunks[#chunks + 1] = { string.rep(" ", block - row.width + 1), M.HL.body }
    out[#out + 1] = chunks
  end
  return out
end

--------------------------------------------------------------------------------
-- Extmarks
--------------------------------------------------------------------------------

---Text cells of the narrowest window showing `buf`: virtual lines belong to the
---buffer, so every window draws the same ones.
---@param buf integer
---@return integer
local function text_width(buf)
  local best
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local width = info.width - info.textoff
      best = best and math.min(best, width) or width
    end
  end
  return best or (vim.o.columns - 8)
end

---Indent of the code a note sits above: the line's own, or for a blank line the
---next one that has text.
---@param buf integer
---@param row integer 0-based.
---@return integer
local function indent_of(buf, row)
  local ok, indent = pcall(vim.api.nvim_buf_call, buf, function()
    local lnum = vim.fn.nextnonblank(row + 1)
    return lnum > 0 and vim.fn.indent(lnum) or 0
  end)
  return ok and indent or 0
end

---Where a note is now.
---@param buf integer
---@param note ClaudeCodeNote
---@return integer|nil row 0-based.
---@return integer|nil end_row
local function position(buf, note)
  if not note.id then
    return nil
  end
  local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, ns, note.id, { details = true })
  if not ok or not mark or not mark[1] then
    return nil
  end
  local end_row = mark[3] and mark[3].end_row or mark[1]
  return mark[1], math.max(end_row, mark[1])
end

---Draw `note` over `row`..`end_row` (0-based, clamped to the buffer).
---@param buf integer
---@param note ClaudeCodeNote
---@param row integer
---@param end_row integer
---@param width integer|nil Text cells of the buffer's narrowest window.
local function set_mark(buf, note, row, end_row, width)
  local last = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  row = math.max(0, math.min(row, last))
  end_row = math.max(row, math.min(end_row, last))
  local mark = {
    id = note.id,
    end_row = end_row,
    end_col = 0,
    -- A line opened at the start of the last line keeps that line in the range.
    end_right_gravity = true,
    priority = PRIORITY,
  }
  if not state.hidden then
    local o = M.opts()
    define_highlights()
    local avail = width or text_width(buf)
    -- Bar, its space, and one cell of padding on the right.
    local room = avail - 3
    local indent = math.max(0, math.min(indent_of(buf, row), room - MIN_WIDTH))
    local text = math.max(1, math.min(o.max_width, room - indent))
    mark.virt_lines = render_note(note, indent, text, o.max_lines)
    mark.virt_lines_above = true
    if o.range_mark == "bar" then
      mark.sign_text = BAR
      mark.sign_hl_group = M.HL.bar
    elseif o.range_mark == "background" then
      mark.line_hl_group = M.HL.range
    elseif o.range_mark == "number" then
      mark.number_hl_group = M.HL.bar
    end
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, mark)
  if ok then
    note.id = id
  else
    logger.debug("notes", "could not draw a note: " .. tostring(id))
  end
end

---@param buf integer
local function render(buf)
  local entry = state.bufs[buf]
  if not entry or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local width = text_width(buf)
  for _, note in ipairs(entry.notes) do
    local row, end_row = position(buf, note)
    if row then
      set_mark(buf, note, row, end_row, width)
    end
  end
end

---Render `buf` once the current event is done (several events often land
---together: a resize reports every window).
---@param buf integer|nil nil for every buffer with notes.
local function schedule_render(buf)
  local targets = {}
  if buf then
    targets[1] = buf
  else
    for b in pairs(state.bufs) do
      targets[#targets + 1] = b
    end
  end
  for _, b in ipairs(targets) do
    if not state.pending[b] then
      state.pending[b] = true
      vim.schedule(function()
        state.pending[b] = nil
        render(b)
      end)
    end
  end
end

---Keep the buffer's text and where each note is in it: the reload that the CLI's
---own edits cause replaces the text before any event can read it.
---@param buf integer
local function snapshot(buf)
  local entry = state.bufs[buf]
  if not entry or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  entry.snapshot = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, note in ipairs(entry.notes) do
    local row, end_row = position(buf, note)
    if row then
      note.snap_row, note.snap_end = row + 1, end_row + 1
    end
  end
end

---After a reload: carry each note from where it was in the old text to the
---same code in the new.
---@param buf integer
local function carry_through_reload(buf)
  local entry = state.bufs[buf]
  if not entry or not entry.snapshot then
    return
  end
  local new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = utils.line_hunks(entry.snapshot, new)
  local width = text_width(buf)
  for _, note in ipairs(entry.notes) do
    local from, to = note.snap_row, note.snap_end
    if from then
      local row = hunks and utils.map_line(hunks, from, #new) or math.min(from, #new)
      local last = hunks and utils.map_line(hunks, to, #new) or math.min(to, #new)
      set_mark(buf, note, row - 1, math.max(last, row) - 1, width)
    end
  end
  snapshot(buf)
end

--------------------------------------------------------------------------------
-- Buffers
--------------------------------------------------------------------------------

---@param buf integer
local function unbind_keys(buf)
  local entry = state.bufs[buf]
  if not entry then
    return
  end
  for lhs in pairs(entry.keys) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  entry.keys = {}
end

---Drop everything about `buf`.
---@param buf integer
local function forget(buf)
  local entry = state.bufs[buf]
  if not entry then
    return
  end
  unbind_keys(buf)
  pcall(vim.api.nvim_del_augroup_by_id, entry.group)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  end
  state.bufs[buf] = nil
end

---`keymaps.next`/`prev` on `buf`, unless the buffer already maps the key itself.
---@param buf integer
local function bind_keys(buf)
  local entry = state.bufs[buf]
  local keymaps = M.opts().keymaps
  if not entry or type(keymaps) ~= "table" then
    return
  end
  for _, spec in ipairs({ { keymaps.next, 1, "next" }, { keymaps.prev, -1, "previous" } }) do
    local lhs, direction, word = spec[1], spec[2], spec[3]
    if type(lhs) == "string" and lhs ~= "" and not entry.keys[lhs] then
      local ok, existing = pcall(vim.api.nvim_buf_call, buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      local taken = ok and type(existing) == "table" and existing.buffer == 1
      if not taken then
        vim.keymap.set("n", lhs, function()
          M.jump(direction, vim.v.count1)
        end, { buffer = buf, silent = true, desc = "Claude: " .. word .. " note" })
        entry.keys[lhs] = true
      end
    end
  end
end

local function ensure_global_autocmds()
  if state.global_group then
    return
  end
  state.global_group = vim.api.nvim_create_augroup("ClaudeCodeNotes", { clear = true })
  -- Widths change: the narrowest window showing a buffer is what notes wrap to.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "WinClosed" }, {
    group = state.global_group,
    callback = function()
      if next(state.bufs) then
        schedule_render()
      end
    end,
    desc = "Re-wrap Claude's notes to the windows showing them",
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.global_group,
    callback = function()
      define_highlights()
    end,
    desc = "Define the highlight groups of Claude's notes again",
  })
end

---@param buf integer
---@return ClaudeCodeNotesBuffer
local function ensure_buffer(buf)
  local entry = state.bufs[buf]
  if entry then
    return entry
  end
  ensure_global_autocmds()
  local group = vim.api.nvim_create_augroup("ClaudeCodeNotes" .. buf, { clear = true })
  entry = { notes = {}, snapshot = nil, group = group, keys = {} }
  state.bufs[buf] = entry
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      schedule_render(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    group = group,
    buffer = buf,
    callback = function()
      snapshot(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    buffer = buf,
    callback = function()
      carry_through_reload(buf)
    end,
    desc = "Carry Claude's notes through a reload of the file",
  })
  -- `:edit` unloads and loads in one go; only a buffer still unloaded afterwards
  -- has lost its notes.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
          forget(buf)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      forget(buf)
    end,
  })
  return entry
end

--------------------------------------------------------------------------------
-- Placing and clearing
--------------------------------------------------------------------------------

---Replace `owner`'s notes in `buf` with `notes`. An empty list only removes.
---Notes being written un-hide every note: they were sent to be read.
---@param buf integer A loaded buffer.
---@param owner string
---@param writer string
---@param notes { line: integer, end_line: integer|nil, title: string|nil, text: string }[]
---@return integer placed
function M.set(buf, owner, writer, notes)
  local entry = state.bufs[buf]
  if entry then
    local kept = {}
    for _, note in ipairs(entry.notes) do
      if note.owner == owner then
        if note.id then
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, note.id)
        end
      else
        kept[#kept + 1] = note
      end
    end
    entry.notes = kept
  end
  if #notes == 0 then
    if entry and #entry.notes == 0 then
      forget(buf)
    end
    return 0
  end

  entry = ensure_buffer(buf)
  local was_hidden = state.hidden
  state.hidden = false
  local width = text_width(buf)
  for _, spec in ipairs(notes) do
    local note = {
      owner = owner,
      writer = writer,
      title = spec.title,
      text = spec.text,
      expanded = false,
    }
    set_mark(buf, note, spec.line - 1, (spec.end_line or spec.line) - 1, width)
    if note.id then
      entry.notes[#entry.notes + 1] = note
    end
  end
  bind_keys(buf)
  snapshot(buf)
  if was_hidden then
    for other in pairs(state.bufs) do
      if other ~= buf then
        render(other)
      end
    end
  end
  return #notes
end

---Remove every note in `buf`.
---@param buf integer
---@return integer removed
function M.clear(buf)
  local entry = state.bufs[buf]
  local count = entry and #entry.notes or 0
  forget(buf)
  return count
end

---Remove every note everywhere.
---@return integer removed
function M.clear_all()
  local count = 0
  for _, buf in ipairs(vim.tbl_keys(state.bufs)) do
    count = count + M.clear(buf)
  end
  return count
end

---Show the notes above the window's first line too. Lines above the top of a
---window are filler, drawn only as far as `topfill` says: a note above line 1
---would otherwise never be seen, and one above the line a jump scrolled to the
---top would be cut off.
---@param win integer
function M.reveal(win)
  if state.hidden or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not state.bufs[buf] then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    local view = vim.fn.winsaveview()
    local top = view.topline - 1
    local filler = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { top, 0 }, { details = true })) do
      local details = mark[4]
      if details.virt_lines and details.virt_lines_above then
        filler = filler + #details.virt_lines
      end
    end
    -- Only while the cursor stays on screen.
    if filler > view.topfill and vim.fn.winline() + filler - view.topfill <= vim.api.nvim_win_get_height(win) then
      vim.fn.winrestview({ topline = view.topline, topfill = filler })
    end
  end)
end

--------------------------------------------------------------------------------
-- Reading the notes
--------------------------------------------------------------------------------

---Every note in `buf`, where it is now, in line order.
---@param buf integer
---@return { row: integer, end_row: integer, note: ClaudeCodeNote }[]
local function placed(buf)
  local entry = state.bufs[buf]
  local out = {}
  for _, note in ipairs(entry and entry.notes or {}) do
    local row, end_row = position(buf, note)
    if row then
      out[#out + 1] = { row = row, end_row = end_row, note = note }
    end
  end
  table.sort(out, function(a, b)
    return a.row < b.row
  end)
  return out
end

---What the notes in `buf` are, for tests and the agents view.
---@param buf integer
---@return { line: integer, end_line: integer, writer: string, title: string|nil, text: string, owner: string, expanded: boolean }[]
function M.items(buf)
  local out = {}
  for _, at in ipairs(placed(buf)) do
    out[#out + 1] = {
      line = at.row + 1,
      end_line = at.end_row + 1,
      writer = at.note.writer,
      title = at.note.title,
      text = at.note.text,
      owner = at.note.owner,
      expanded = at.note.expanded,
    }
  end
  return out
end

---@return boolean
function M.is_hidden()
  return state.hidden
end

---The note the cursor is on: the innermost one whose lines hold it, else the
---nearest above, else the nearest below.
---@param buf integer
---@param row integer 0-based.
---@return ClaudeCodeNote|nil
local function note_at(buf, row)
  local list = placed(buf)
  local best
  for _, at in ipairs(list) do
    if at.row <= row and row <= at.end_row then
      best = at
    end
  end
  if not best then
    for _, at in ipairs(list) do
      if at.row <= row then
        best = at
      end
    end
  end
  best = best or list[1]
  return best and best.note or nil
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

---Move the cursor to the `count`th note after (1) or before (-1) it, wrapping
---around the buffer with `'wrapscan'`.
---@param direction integer
---@param count integer|nil
function M.jump(direction, count)
  local buf = vim.api.nvim_get_current_buf()
  local rows, seen = {}, {}
  for _, at in ipairs(placed(buf)) do
    if not seen[at.row] then
      seen[at.row] = true
      rows[#rows + 1] = at.row
    end
  end
  if #rows == 0 then
    logger.info("notes", "No Claude notes in this buffer")
    return
  end
  local start = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target = start
  for _ = 1, math.max(count or 1, 1) do
    local found
    if direction > 0 then
      for _, row in ipairs(rows) do
        if row > target then
          found = row
          break
        end
      end
      found = found or (vim.o.wrapscan and rows[1] or nil)
    else
      for i = #rows, 1, -1 do
        if rows[i] < target then
          found = rows[i]
          break
        end
      end
      found = found or (vim.o.wrapscan and rows[#rows] or nil)
    end
    if not found then
      break
    end
    target = found
  end
  if target == start then
    return
  end
  vim.cmd("normal! m'")
  local text = vim.api.nvim_buf_get_lines(buf, target, target + 1, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { target + 1, (text:find("%S") or 1) - 1 })
  vim.cmd("normal! zv")
  M.reveal(vim.api.nvim_get_current_win())
end

---Show a note whole (`expanded = true`) or cut at `max_lines` again.
---@param expanded boolean
---@param all boolean Every note everywhere, not the one at the cursor.
function M.set_expanded(expanded, all)
  if all then
    for buf, entry in pairs(state.bufs) do
      for _, note in ipairs(entry.notes) do
        note.expanded = expanded
      end
      render(buf)
    end
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local note = note_at(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not note then
    logger.info("notes", "No Claude notes in this buffer")
    return
  end
  note.expanded = expanded
  render(buf)
  M.reveal(vim.api.nvim_get_current_win())
end

---Hide every note without losing it, or show them again.
---@param hidden boolean|nil nil toggles.
function M.toggle(hidden)
  if hidden == nil then
    hidden = not state.hidden
  end
  state.hidden = hidden
  for buf in pairs(state.bufs) do
    render(buf)
  end
end

---One line for a note in the quickfix list: its header, then its text.
---@param note ClaudeCodeNote
---@return string
local function summary(note)
  local head = note.writer .. (note.title and (" · " .. note.title) or "")
  return head .. " — " .. vim.trim((note.text:gsub("%s+", " ")))
end

---Every note in the quickfix list, by file and line.
---@return integer count
function M.list()
  local items = {}
  local bufs = vim.tbl_keys(state.bufs)
  table.sort(bufs, function(a, b)
    return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
  end)
  for _, buf in ipairs(bufs) do
    for _, at in ipairs(placed(buf)) do
      items[#items + 1] = {
        bufnr = buf,
        lnum = at.row + 1,
        end_lnum = at.end_row + 1,
        col = 1,
        text = summary(at.note),
      }
    end
  end
  if #items == 0 then
    logger.info("notes", "No Claude notes")
    return 0
  end
  vim.fn.setqflist({}, " ", { title = "Claude notes", items = items })
  vim.cmd("botright copen")
  return #items
end

---`:ClaudeCodeNotes [list|clear[!]|toggle|next|prev|expand[!]|collapse[!]]`.
---@param args string|nil
---@param bang boolean|nil
function M.command(args, bang)
  local sub = vim.trim(args or "")
  if sub == "" or sub == "list" then
    M.list()
  elseif sub == "clear" then
    local count = bang and M.clear_all() or M.clear(vim.api.nvim_get_current_buf())
    logger.debug("notes", ("cleared %d note(s)"):format(count))
  elseif sub == "toggle" then
    M.toggle()
    logger.info("notes", state.hidden and "Claude notes hidden" or "Claude notes shown")
  elseif sub == "next" then
    M.jump(1, 1)
  elseif sub == "prev" then
    M.jump(-1, 1)
  elseif sub == "expand" then
    M.set_expanded(true, bang == true)
  elseif sub == "collapse" then
    M.set_expanded(false, bang == true)
  else
    logger.warn("command", "ClaudeCodeNotes: unknown subcommand '" .. sub .. "'")
  end
end

-- Exposed for tests.
M._ns = ns
M._state = state

return M
