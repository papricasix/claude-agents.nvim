-- Notes `open_files` leaves in a file, checked in a real Neovim: they are
-- extmarks, virtual lines, reloads and windows, none of which the unit suite's
-- mocked `vim` has.
--
--   nvim --headless -u NONE -l tests/nvim/notes_check.lua
--
-- Exits non-zero on the first failure. Driven by tests/integration/open_files_nvim_spec.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false

local notes = require("claude_agents.notes")
local open_files = require("claude_agents.open_files")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function file(name, lines)
  local path = dir .. "/" .. name
  local out = {}
  for i = 1, lines or 40 do
    out[i] = ("%s line %d"):format(name, i)
  end
  vim.fn.writefile(out, path)
  return path
end
local a, b = file("a.lua"), file("b.lua")

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then
    error("FAILED: " .. what, 2)
  end
end

---Notes switched by a stand-in for the plugin's applied config.
local function configure(notes_opts)
  package.loaded["claude_agents"] = notes_opts and { state = { config = { open_files = { notes = notes_opts } } } }
    or nil
end

local function reset()
  notes.clear_all()
  notes.toggle(false)
  configure(nil)
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function claude_tab()
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("botright vsplit")
  local term = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term, buf)
  vim.api.nvim_open_term(buf, {})
  vim.b[buf].claudecode_tab = tab
  vim.api.nvim_win_set_width(term, 60)
  vim.api.nvim_set_current_win(term)
  return tab
end

local function asker(tab, extra)
  return vim.tbl_extend("force", open_files.asker({ tab = tab, kind = "tab" }), extra or {})
end

---Every note extmark in `buf`, with its virtual lines as plain text.
local function marks(buf)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, notes._ns, 0, -1, { details = true })) do
    local d = mark[4]
    local lines = {}
    for i, chunks in ipairs(d.virt_lines or {}) do
      local text = ""
      for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
      end
      lines[i] = text
    end
    out[#out + 1] = { row = mark[2], end_row = d.end_row, details = d, lines = lines }
  end
  return out
end

local function trimmed(text)
  return (text:gsub("%s+$", ""))
end

-- Reading a request.
do
  local parsed = assert(notes.parse({ { line = 3, end_line = 2, title = "  Two\nwords ", text = " body " } }))
  check(parsed[1].end_line == nil, "parse: an end before the line is dropped")
  check(parsed[1].title == "Two words", "parse: title on one line")
  check(parsed[1].text == "body", "parse: text trimmed")
  local none, err = notes.parse({ { line = 3 } })
  check(none == nil and err:find("notes%[1%]"), "parse: a note without text is refused, by index")
  check(notes.parse("x") == nil, "parse: not a list is refused")
end

-- Laying text out.
do
  local runs = notes._inline("see `x.y` and **bold `c`** or `open")
  check(runs[2].code and runs[2].text == "x.y", "inline: a code span")
  check(runs[4].bold and runs[4].text == "bold " and runs[5].bold and runs[5].code, "inline: code inside bold")
  check(runs[#runs].text:find("`open", 1, true), "inline: an unclosed backtick is text")

  local function texts(lines)
    local out = {}
    for i, line in ipairs(lines) do
      local text = ""
      for _, piece in ipairs(line.pieces) do
        text = text .. piece.text
      end
      out[i] = text
    end
    return out
  end
  local lines = notes._layout("one two three four five six seven eight nine ten", 20)
  for _, line in ipairs(lines) do
    check(line.width <= 20, "layout: no line wider than the width")
  end
  check(#lines == 3, "layout: wrapped by words")
  local list = texts(notes._layout("- first item that is long enough to wrap\n\nnext paragraph", 20))
  check(list[1]:sub(1, 2) == "- " and list[2]:sub(1, 2) == "  ", "layout: a list item hangs")
  check(vim.tbl_contains(list, ""), "layout: a blank line between paragraphs")
  local long = notes._layout(string.rep("x", 50), 20)
  check(#long == 3 and long[1].width == 20, "layout: a word longer than a line is cut")
  local code = texts(notes._layout("a `call(x, y)` b", 8))
  check(
    vim.tbl_contains(code, "call(x, y)") or code[2]:find("call", 1, true),
    "layout: a code span is not split at spaces"
  )
end

-- A note above its line, drawn as a callout; the range wears the bar.
do
  reset()
  local tab = claude_tab()
  local result = assert(open_files.open({
    files = {
      {
        path = a,
        notes = {
          { line = 12, end_line = 14, title = "Retry loop", text = "Retries three times, then gives **up**." },
          { line = 30, text = "Second." },
        },
      },
    },
  }, asker(tab)))
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  check(vim.api.nvim_win_get_cursor(win)[1] == 12, "no line: the cursor goes to the first note")
  check(result.message:find("Showed 2 notes", 1, true), "message: counts the notes")
  local m = marks(buf)
  check(#m == 2, "two notes, two extmarks")
  check(m[1].row == 11 and m[1].end_row == 13, "note 1 spans lines 12-14")
  check(m[1].details.virt_lines_above, "drawn above its line")
  check(trimmed(m[1].lines[1]) == "▎ ✻ Claude · Retry loop", "header: writer and title")
  check(trimmed(m[1].lines[2]) == "▎ Retries three times, then gives up.", "body: markup rendered, not shown")
  check(
    #m[1].lines[1] == #m[1].lines[2] or vim.fn.strdisplaywidth(m[1].lines[1]) == vim.fn.strdisplaywidth(m[1].lines[2]),
    "the block is padded to one width"
  )
  check(m[1].details.sign_text and m[1].details.sign_text:find("▎"), "range: a bar in the sign column")
  local items = notes.items(buf)
  check(items[2].line == 30 and items[2].title == nil, "items: line order")

  -- The bar spans the range: the sign shows on every line of it. Asked of the
  -- extmarks, not the screen: headless 0.12.2 corrupts its heap when a redrawn
  -- `nvim_open_term` buffer is deleted (`reset`).
  local signs = 0
  for lnum = 12, 15 do
    local placed = vim.api.nvim_buf_get_extmarks(buf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, {
      details = true,
      type = "sign",
      overlap = true,
    })
    for _, mark in ipairs(placed) do
      if mark[4].ns_id == notes._ns then
        signs = signs + 1
      end
    end
  end
  check(signs >= 3, "range: the sign covers lines 12-14")

  -- ]n / [n, with wrapping.
  check(vim.fn.maparg("]n", "n", false, true).buffer == 1, "keys: ]n bound on the buffer")
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  notes.jump(1, 1)
  check(vim.api.nvim_win_get_cursor(win)[1] == 12, "]n: to the first note")
  notes.jump(1, 1)
  check(vim.api.nvim_win_get_cursor(win)[1] == 30, "]n: to the next")
  notes.jump(1, 1)
  check(vim.api.nvim_win_get_cursor(win)[1] == 12, "]n: wraps around")
  notes.jump(-1, 1)
  check(vim.api.nvim_win_get_cursor(win)[1] == 30, "[n: back, wrapping")

  -- Edits carry the note along.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new 1", "new 2" })
  check(marks(buf)[1].row == 13, "an edit above moves the note")

  -- The quickfix list.
  check(notes.list() == 2, "list: both notes")
  local qf = vim.fn.getqflist()
  check(
    qf[1].lnum == 14 and qf[1].text:find("Retry loop", 1, true) and qf[1].text:find("Retries", 1, true),
    "list: header and text, where the note is now"
  )
  vim.cmd("cclose")

  -- Hidden and shown again; new notes show everything again.
  notes.toggle()
  check(#marks(buf) == 2 and #marks(buf)[1].lines == 0 and not marks(buf)[1].details.sign_text, "toggle: hidden")
  check(notes.is_hidden(), "toggle: says so")
  open_files.open({ files = { { path = b, notes = { { line = 2, text = "elsewhere" } } } } }, asker(tab))
  check(not notes.is_hidden() and #marks(buf)[1].lines > 0, "new notes: everything shown again")

  -- Clear: marks and keys gone.
  notes.clear(buf)
  check(#marks(buf) == 0, "clear: no marks left")
  check(
    vim.tbl_isempty(vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("]n", "n", false, true)
    end)),
    "clear: keys unbound"
  )
end

-- Replaced per conversation and file; an empty list removes; others stay.
do
  reset()
  local tab = claude_tab()
  local mine = asker(tab)
  open_files.open(
    { files = { { path = a, notes = { { line = 5, text = "first" }, { line = 6, text = "x" } } } } },
    mine
  )
  local buf = vim.api.nvim_get_current_buf()
  open_files.open({ files = { { path = a, notes = { { line = 8, text = "second" } } } } }, mine)
  local items = notes.items(buf)
  check(#items == 1 and items[1].text == "second", "replace: the conversation's earlier notes go")
  local agent = asker(tab, { kind = "agent", session_id = "0123456789abcdef" })
  open_files.open({ files = { { path = a, notes = { { line = 20, text = "agent's" } } } } }, agent)
  items = notes.items(buf)
  check(#items == 2, "replace: another conversation's notes stay")
  check(items[2].writer == "✻ 01234567", "agent: named in the header")
  open_files.open({ files = { { path = a } } }, mine)
  check(#notes.items(buf) == 2, "no notes field: nothing changes")
  local result = assert(open_files.open({ files = { { path = a, notes = {} } } }, mine))
  items = notes.items(buf)
  check(#items == 1 and items[1].text == "agent's", "empty list: only the asker's notes go")
  check(result.message:find("Removed your notes", 1, true), "empty list: said")
  local oc = asker(tab, { backend = "opencode" })
  open_files.open({ files = { { path = a, notes = { { line = 3, text = "oc" } } } } }, oc)
  check(notes.items(buf)[1].writer == "◇ OpenCode", "OpenCode: its own header")
end

-- Width: wrapped to the narrowest window showing the buffer; long notes cut.
do
  reset()
  local tab = claude_tab()
  configure({ max_lines = 2, max_width = 30 })
  local text = string.rep("word ", 40)
  open_files.open({ files = { { path = a, notes = { { line = 10, text = text } } } } }, asker(tab))
  local buf = vim.api.nvim_get_current_buf()
  local m = marks(buf)[1]
  check(#m.lines == 4, "max_lines: header, two lines, the rest counted")
  check(m.lines[4]:find("more lines", 1, true), "max_lines: says how many more")
  for _, line in ipairs(m.lines) do
    check(vim.fn.strdisplaywidth(line) <= 30 + 4, "max_width: no wider")
  end
  notes.set_expanded(true, false)
  check(#marks(buf)[1].lines > 4, "expand: the whole note")
  notes.set_expanded(false, true)
  check(#marks(buf)[1].lines == 4, "collapse!: cut again")

  configure({ max_width = 200 })
  vim.cmd("vertical resize 50")
  vim.cmd("doautocmd WinResized")
  vim.wait(50)
  local narrow = vim.api.nvim_win_get_width(0) - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
  for _, line in ipairs(marks(buf)[1].lines) do
    check(vim.fn.strdisplaywidth(line) <= narrow, "resize: re-wrapped to the window")
  end
end

-- Indented code: the note is indented with it.
do
  reset()
  local path = dir .. "/indented.lua"
  vim.fn.writefile({ "local function f()", "    return 1", "end" }, path)
  local tab = claude_tab()
  open_files.open({ files = { { path = path, notes = { { line = 2, text = "returns one" } } } } }, asker(tab))
  local line = marks(vim.api.nvim_get_current_buf())[1].lines[1]
  check(line:find("^    ▎") ~= nil, "indent: at the code's indent")
end

-- Range marks, as configured.
for _, case in ipairs({
  { "background", "line_hl_group" },
  { "number", "number_hl_group" },
  { false, nil },
}) do
  reset()
  local tab = claude_tab()
  configure({ range_mark = case[1] })
  open_files.open({ files = { { path = a, notes = { { line = 4, end_line = 6, text = "t" } } } } }, asker(tab))
  local d = marks(vim.api.nvim_get_current_buf())[1].details
  if case[2] then
    check(d[case[2]] ~= nil and not d.sign_text, "range_mark " .. tostring(case[1]) .. ": " .. case[2])
  else
    check(not d.sign_text and not d.line_hl_group and not d.number_hl_group, "range_mark false: nothing")
  end
end

-- A note above line 1 is scrolled into view.
do
  reset()
  local tab = claude_tab()
  open_files.open({ files = { { path = a, notes = { { line = 1, text = "top of the file" } } } } }, asker(tab))
  check(vim.fn.winsaveview().topfill >= 2, "line 1: shown above it")
end

-- The CLI writing the file reloads it: notes follow their code.
do
  reset()
  local path = file("reload.lua", 30)
  local tab = claude_tab()
  vim.o.autoread = true
  open_files.open({
    files = { { path = path, notes = { { line = 10, end_line = 11, text = "ten" }, { line = 20, text = "twenty" } } } },
  }, asker(tab))
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.fn.readfile(path)
  table.insert(lines, 1, "inserted 1")
  table.insert(lines, 1, "inserted 2")
  table.remove(lines, 17) -- reload.lua line 15
  lines[20] = "changed" -- was line 19
  vim.uv.sleep(1100)
  vim.fn.writefile(lines, path)
  vim.cmd("checktime")
  local items = notes.items(buf)
  check(items[1].line == 12 and items[1].end_line == 13, "reload: the first note moved down two")
  check(
    vim.api.nvim_buf_get_lines(buf, items[2].line - 1, items[2].line, false)[1] == "reload.lua line 20",
    "reload: the second note is still on its code"
  )
  vim.uv.sleep(1100)
  table.insert(lines, 1, "top")
  vim.fn.writefile(lines, path)
  vim.cmd("edit")
  vim.wait(20)
  items = notes.items(buf)
  check(#items == 2 and items[1].line == 13, ":edit: kept and carried")
  vim.cmd("bwipeout!")
  check(notes._state.bufs[buf] == nil, "wipeout: forgotten")
end

-- Directories, switched off, and refusals.
do
  reset()
  local tab = claude_tab()
  local result =
    assert(open_files.open({ files = { { path = dir, notes = { { line = 1, text = "x" } } } } }, asker(tab)))
  check(result.message:find("shown in files only", 1, true), "directory: notes dropped, said")
  reset()
  tab = claude_tab()
  configure({ enabled = false })
  result = assert(open_files.open({ files = { { path = a, notes = { { line = 3, text = "x" } } } } }, asker(tab)))
  check(#marks(vim.api.nvim_get_current_buf()) == 0, "off: nothing drawn")
  check(result.message:find("switched off", 1, true), "off: said")
  configure(nil)
  local none, err = open_files.open({ files = { { path = a, notes = { { text = "no line" } } } } }, asker(tab))
  check(
    none == nil and err.code == open_files.INVALID and err.message:find("files%[1%]%.notes%[1%]"),
    "refused: names it"
  )
end

-- The command.
do
  reset()
  local tab = claude_tab()
  open_files.open(
    { files = { { path = a, notes = { { line = 3, text = "x" }, { line = 9, text = "y" } } } } },
    asker(tab)
  )
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("normal! gg")
  notes.command("next")
  check(vim.api.nvim_win_get_cursor(0)[1] == 3, "command: next")
  notes.command("toggle")
  check(notes.is_hidden(), "command: toggle")
  notes.command("toggle")
  notes.command("clear", true)
  check(#notes.items(buf) == 0, "command: clear!")
end

vim.fn.delete(dir, "rf")
io.write(("ok %d checks\n"):format(checks))
