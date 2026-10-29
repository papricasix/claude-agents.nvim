-- Window placement of `open_files`, checked in a real Neovim: the unit suite's
-- `vim` is a mock, and tabs, splits, sizes and focus are what this feature is.
--
--   nvim --headless -u NONE -l tests/nvim/open_files_check.lua
--
-- Exits non-zero on the first failure. Driven by tests/integration/open_files_nvim_spec.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false

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
local a, b, c = file("a.lua"), file("b.lua"), file("c.lua")

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then
    error("FAILED: " .. what, 2)
  end
end

local function reset()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---A tab laid out like a Claude tab: an editor window and, on the right, the
---terminal of that tab's Claude.
local function claude_tab()
  local tab = vim.api.nvim_get_current_tabpage()
  local editor = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  local term = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term, buf)
  vim.api.nvim_open_term(buf, {})
  vim.b[buf].claudecode_tab = tab
  vim.api.nvim_win_set_width(term, 60)
  vim.api.nvim_set_current_win(term)
  return tab, editor, term
end

local function asker(tab)
  return open_files.asker({ tab = tab, kind = "tab" })
end

local function buf_path(win)
  return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
end

local function same(p, q)
  return vim.fn.resolve(p) == vim.fn.resolve(q)
end

-- A new tab, focused, cursor on the line, the range highlighted.
do
  reset()
  local tab = claude_tab()
  local result = assert(open_files.open({ files = { { path = a, line = 10, end_line = 12 } } }, asker(tab)))
  check(#vim.api.nvim_list_tabpages() == 2, "tab: a second tab")
  check(vim.api.nvim_tabpage_get_number(vim.api.nvim_get_current_tabpage()) == 2, "tab: placed after the asker's")
  check(same(buf_path(vim.api.nvim_get_current_win()), a), "tab: shows the file, focused")
  check(vim.api.nvim_win_get_cursor(0)[1] == 10, "tab: cursor on line 10")
  local marks = vim.api.nvim_buf_get_extmarks(0, open_files._ns, 0, -1, {})
  check(#marks == 3, "tab: lines 10-12 highlighted")
  check(result.message:find("a.lua %(lines 10%-12%)") ~= nil, "tab: message names the range")
  -- Placing the cursor is not a move; moving it is.
  vim.cmd("doautocmd CursorMoved")
  check(#vim.api.nvim_buf_get_extmarks(0, open_files._ns, 0, -1, {}) == 3, "range: survives its own placement")
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  vim.cmd("doautocmd CursorMoved")
  check(#vim.api.nvim_buf_get_extmarks(0, open_files._ns, 0, -1, {}) == 0, "range: cleared by a move")
end

-- focus = false: the tab is made, the cursor goes back to the terminal.
do
  reset()
  local tab, _, term = claude_tab()
  assert(open_files.open({ files = { { path = a } }, focus = false }, asker(tab)))
  check(#vim.api.nvim_list_tabpages() == 2, "background tab: made")
  check(vim.api.nvim_get_current_win() == term, "background tab: cursor back in the terminal")
end

-- Several files in one tab: side by side, or stacked; equal sizes.
for _, arrangement in ipairs({ "vertical", "horizontal" }) do
  reset()
  local tab = claude_tab()
  local result = assert(open_files.open({
    files = { { path = a }, { path = b }, { path = c } },
    arrangement = arrangement,
  }, asker(tab)))
  local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
  check(#wins == 3, arrangement .. ": three windows")
  check(same(buf_path(wins[1]), a) and same(buf_path(wins[3]), c), arrangement .. ": in file order")
  check(vim.api.nvim_get_current_win() == wins[1], arrangement .. ": cursor in the first")
  local p1, p2 = vim.api.nvim_win_get_position(wins[1]), vim.api.nvim_win_get_position(wins[2])
  if arrangement == "vertical" then
    check(p1[1] == p2[1] and p1[2] < p2[2], "vertical: side by side")
    local w1, w3 = vim.api.nvim_win_get_width(wins[1]), vim.api.nvim_win_get_width(wins[3])
    check(math.abs(w1 - w3) <= 1, "vertical: equal widths")
  else
    check(p1[2] == p2[2] and p1[1] < p2[1], "horizontal: stacked")
    check(result.message:find("stacked") ~= nil, "horizontal: message says stacked")
  end
end

-- A grid: rows and columns, in file order, row by row.
do
  check(select(2, open_files.grid_shape(4)) == 2 and open_files.grid_shape(4) == 2, "grid shape: 4 is 2x2")
  check(open_files.grid_shape(3) == 2 and select(2, open_files.grid_shape(3)) == 2, "grid shape: 3 is 2 over 1")
  check(open_files.grid_shape(6) == 2 and select(2, open_files.grid_shape(6)) == 3, "grid shape: 6 is 3x2")
  local d = file("d.lua")
  for _, case in ipairs({ { a, b, c, d }, { a, b, c } }) do
    reset()
    local tab = claude_tab()
    local files = {}
    for i, path in ipairs(case) do
      files[i] = { path = path, line = i + 1 }
    end
    local result = assert(open_files.open({ files = files, arrangement = "grid" }, asker(tab)))
    local n = #case
    check(result.message:find("grid") ~= nil, "grid " .. n .. ": message says so")
    check(#result.windows == n, "grid " .. n .. ": a window per file")
    local pos = {}
    for i, win in ipairs(result.windows) do
      check(same(buf_path(win), case[i]), "grid " .. n .. ": window " .. i .. " shows file " .. i)
      check(vim.api.nvim_win_get_cursor(win)[1] == i + 1, "grid " .. n .. ": file " .. i .. " on its line")
      pos[i] = vim.api.nvim_win_get_position(win)
    end
    check(pos[1][1] == pos[2][1] and pos[1][2] < pos[2][2], "grid " .. n .. ": 1 and 2 share the top row")
    check(pos[3][1] > pos[1][1] and pos[3][2] == pos[1][2], "grid " .. n .. ": 3 starts the second row")
    if n == 4 then
      check(pos[4][1] == pos[3][1] and pos[4][2] == pos[2][2], "grid 4: 4 under 2")
      local w1, w2 = vim.api.nvim_win_get_width(result.windows[1]), vim.api.nvim_win_get_width(result.windows[2])
      check(math.abs(w1 - w2) <= 1, "grid 4: equal columns")
    else
      check(
        vim.api.nvim_win_get_width(result.windows[3]) > vim.api.nvim_win_get_width(result.windows[1]),
        "grid 3: the last row spans"
      )
    end
    check(vim.api.nvim_get_current_win() == result.windows[1], "grid " .. n .. ": cursor in the first")
  end
end

-- Already visible: jumped to, nothing opened.
do
  reset()
  local tab, editor = claude_tab()
  vim.api.nvim_win_call(editor, function()
    vim.cmd("edit " .. vim.fn.fnameescape(b))
  end)
  vim.cmd("tabnew")
  local other = vim.api.nvim_get_current_tabpage()
  local result = assert(open_files.open({ files = { { path = b, line = 5 } } }, asker(other)))
  check(#vim.api.nvim_list_tabpages() == 2, "visible: no new tab")
  check(vim.api.nvim_get_current_win() == editor, "visible: cursor moved to it")
  check(vim.api.nvim_win_get_cursor(editor)[1] == 5, "visible: on the line")
  check(result.jumped == true, "visible: reported as a jump")

  -- focus = false: the line moves, the cursor stays.
  vim.api.nvim_set_current_tabpage(other)
  local here = vim.api.nvim_get_current_win()
  assert(open_files.open({ files = { { path = b, line = 7 } }, focus = false }, asker(tab)))
  check(vim.api.nvim_get_current_win() == here, "visible, background: cursor stays")
  check(vim.api.nvim_win_get_cursor(editor)[1] == 7, "visible, background: its window moved")

  -- A float or split asked for by name is opened anyway; `tab` still jumps,
  -- since models pass it when nobody asked for one.
  vim.api.nvim_set_current_tabpage(other)
  local result_float = assert(open_files.open({ files = { { path = b } }, layout = "float" }, asker(tab)))
  local float = vim.api.nvim_get_current_win()
  check(result_float.jumped == false, "visible, float asked for: not a jump")
  check(vim.api.nvim_win_get_config(float).relative ~= "", "visible, float asked for: a float")
  check(same(buf_path(float), b), "visible, float asked for: shows the file")
  vim.api.nvim_win_close(float, true)

  local before = #vim.api.nvim_tabpage_list_wins(tab)
  assert(open_files.open({ files = { { path = b } }, layout = "vsplit" }, asker(tab)))
  check(#vim.api.nvim_tabpage_list_wins(tab) == before + 1, "visible, vsplit asked for: a new split")

  local tabs = #vim.api.nvim_list_tabpages()
  local result_tab = assert(open_files.open({ files = { { path = b } }, layout = "tab" }, asker(tab)))
  check(result_tab.jumped == true and #vim.api.nvim_list_tabpages() == tabs, "visible, tab named: still a jump")
end

-- vsplit beside the editor window next to the terminal: the terminal keeps its
-- width and is never split, the new windows share the editor's room.
do
  reset()
  local tab, editor, term = claude_tab()
  local term_width = vim.api.nvim_win_get_width(term)
  assert(open_files.open({ files = { { path = a }, { path = b } }, layout = "vsplit" }, asker(tab)))
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  check(#vim.api.nvim_list_tabpages() == 1, "vsplit: no new tab")
  check(#wins == 4, "vsplit: two splits beside the editor")
  check(vim.api.nvim_win_get_width(term) == term_width, "vsplit: terminal width unchanged")
  check(
    vim.api.nvim_win_get_buf(term) ~= nil and vim.bo[vim.api.nvim_win_get_buf(term)].buftype == "terminal",
    "vsplit: terminal intact"
  )
  check(same(buf_path(vim.api.nvim_get_current_win()), a), "vsplit: cursor in the first file")
  local we, wa = vim.api.nvim_win_get_width(editor), vim.api.nvim_win_get_width(vim.api.nvim_get_current_win())
  check(math.abs(we - wa) <= 1, "vsplit: editor and splits share equally")
end

-- split in a tab holding only the terminal: a window of its own along the edge.
do
  reset()
  local tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_open_term(buf, {})
  vim.b[buf].claudecode_tab = tab
  local term = vim.api.nvim_get_current_win()
  assert(open_files.open({ files = { { path = a } }, layout = "split" }, asker(tab)))
  check(#vim.api.nvim_tabpage_list_wins(tab) == 2, "split, terminal only: one new window")
  check(vim.api.nvim_win_get_buf(term) == buf, "split, terminal only: terminal kept")
  check(vim.api.nvim_win_get_position(vim.api.nvim_get_current_win())[1] == 0, "split, terminal only: along the top")
end

-- A tab that owns its layout has nothing to split: a tab instead.
do
  reset()
  local tab = claude_tab()
  vim.api.nvim_tabpage_set_var(tab, "claudecode_layout_owner", { forbids_split = true, host = "float" })
  local result = assert(open_files.open({ files = { { path = a }, { path = b } }, layout = "split" }, asker(tab)))
  check(result.layout == "tab", "owned layout: became a tab")
  local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
  local p1, p2 = vim.api.nvim_win_get_position(wins[1]), vim.api.nvim_win_get_position(wins[2])
  check(p1[2] == p2[2] and p1[1] < p2[1], "owned layout: 'split' kept as stacked")
end

-- A float: one file, focused, listed; never two.
do
  reset()
  local tab = claude_tab()
  local result = assert(open_files.open({ files = { { path = c, line = 3 } }, layout = "float" }, asker(tab)))
  local win = vim.api.nvim_get_current_win()
  check(vim.api.nvim_win_get_config(win).relative ~= "", "float: a float, focused")
  check(same(buf_path(win), c), "float: shows the file")
  check(vim.bo[vim.api.nvim_win_get_buf(win)].buflisted, "float: buffer listed")
  check(vim.api.nvim_win_get_cursor(win)[1] == 3, "float: on the line")
  check(result.message:find("float") ~= nil, "float: message says so")
  local none, err = open_files.open({ files = { { path = a }, { path = b } }, layout = "float" }, asker(tab))
  check(none == nil and err.code == open_files.INVALID, "float: refuses two files")
end

-- Refusals and paths.
do
  reset()
  local tab = claude_tab()
  local none, err = open_files.open({ files = { { path = dir .. "/missing.lua" } } }, asker(tab))
  check(none == nil and err.message:find("No such file") ~= nil, "missing: refused")
  none, err = open_files.open({ files = {} }, asker(tab))
  check(none == nil and err.code == open_files.INVALID, "empty: refused")
  none, err = open_files.open({ files = { { path = a } }, layout = "diagonal" }, asker(tab))
  check(none == nil and err.code == open_files.INVALID, "bad layout: refused")

  local who = asker(tab)
  who.cwd = dir
  assert(open_files.open({ files = { { path = "b.lua" } } }, who))
  check(same(buf_path(vim.api.nvim_get_current_win()), b), "relative: taken from the asker's directory")
  check(open_files._resolve("routes/$post.tsx", "/p") == "/p/routes/$post.tsx", "paths: a literal $ survives")
end

vim.fn.delete(dir, "rf")
io.write(("ok %d checks\n"):format(checks))
