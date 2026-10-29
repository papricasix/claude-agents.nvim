---@brief [[
--- Open files in the Neovim hosting a conversation, when the user asks the model
--- to ("open the parser in a float", "show me a.lua and b.lua side by side").
---
--- The CLI shows the model only `getDiagnostics` and `executeCode` of the IDE
--- connection's tools (2.1.312), so the plugin's own `openFile` is the CLI's
--- alone. This is reached instead through a second MCP server every launch
--- registers (`mcp_config`): the same WebSocket server on `handshake.TOOLS_PATH`,
--- under a name of its own. Each tab's Claude and each agent has its own server
--- instance, so the instance that answers is the Claude that asked.
---
--- Placement rules, in order:
---
--- * A single file already visible in a window (any tab) is jumped to rather
---   than opened a second time — unless the call asked for a float or a split,
---   which is a request to see it there. Diff windows, live previews and the
---   agents panes do not count; the plugin's own floats do. `tab` is not such a
---   request: models pass it when nobody asked for anything.
--- * `tab` opens a new tab after the asker's tab, several files side by side
---   (`arrangement = "vertical"`), stacked (`"horizontal"`) or in a grid
---   (`"grid"`, `grid_shape`: 4 → 2×2).
--- * `float` shows one file over the current screen; `q` closes it.
--- * `split`/`vsplit` put each file in a split of its own beside the editor
---   window closest to the asker's terminal, in the asker's tab. No other window
---   changes size. A tab that owns its layout (the agents view) has nothing to
---   split, so there they become a tab with that arrangement.
---
--- `focus = false` leaves the cursor where it was. A float always takes focus:
--- one left unfocused over the terminal being typed in could not be closed with
--- `q`.
---@brief ]]
---@module 'claude_agents.open_files'

local logger = require("claude_agents.logger")
local utils = require("claude_agents.utils")

local M = {}

M.LAYOUTS = { "tab", "float", "split", "vsplit" }
M.ARRANGEMENTS = { "vertical", "horizontal", "grid" }
M.DEFAULTS = { enabled = true, layout = "tab", focus = true, server_name = "nvim" }

--- Lines a call asked to be shown, until the cursor moves.
M.HIGHLIGHT = "ClaudeCodeOpenRange"

--- JSON-RPC-style codes, as the tool handler reports them.
M.INVALID = -32602
M.FAILED = -32000

local ns = vim.api.nvim_create_namespace("claudecode_open_files")

---@return table opts `M.DEFAULTS` under the user's `open_files`.
function M.opts()
  local main = package.loaded["claude_agents"]
  local config = main and main.state and main.state.config
  local user = config and config.open_files
  return vim.tbl_extend("force", M.DEFAULTS, type(user) == "table" and user or {})
end

---@return boolean
function M.enabled()
  return M.opts().enabled ~= false
end

---What a launch adds to `--mcp-config` so its CLI can reach `open_files`: the
---instance's own server, on the tool path, with its token.
---@param instance { port: integer|nil, auth_token: string|nil }|nil
---@return table|nil config nil when disabled or the instance has no server.
function M.mcp_config(instance)
  if not M.enabled() or not instance or not instance.port or not instance.auth_token then
    return nil
  end
  local handshake = require("claude_agents.server.handshake")
  return {
    mcpServers = {
      [M.opts().server_name] = {
        type = "ws",
        url = ("ws://127.0.0.1:%d%s"):format(instance.port, handshake.TOOLS_PATH),
        headers = { ["x-claude-code-ide-authorization"] = instance.auth_token },
      },
    },
  }
end

--------------------------------------------------------------------------------
-- Who asked
--------------------------------------------------------------------------------

---@class ClaudeCodeOpenAsker
---@field tab integer|nil Tabpage the asking Claude belongs to.
---@field kind "tab"|"agent"|nil
---@field session_id string|nil
---@field cwd string|nil Where relative paths are taken from.
---@field term_win integer|nil The window showing its terminal, if one does.

---@param tab integer
---@return integer|nil win The window in `tab` showing that tab's own Claude.
local function tab_terminal_window(tab)
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tab)
  if not ok then
    return nil
  end
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      vim.bo[buf].buftype == "terminal"
      and vim.b[buf].claudecode_tab == tab
      and vim.b[buf].claudecode_agent_session == nil
    then
      return win
    end
  end
  return nil
end

---The asker, from the request context a server instance set before dispatching.
---@param rc ClaudeCodeRequestContext|nil
---@return ClaudeCodeOpenAsker
function M.asker(rc)
  rc = rc or {}
  local tab = rc.tab
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
    tab = vim.api.nvim_get_current_tabpage()
  end
  local asker = { tab = tab, kind = rc.kind, session_id = rc.session_id }
  if rc.kind == "agent" and rc.session_id then
    local ok, registry = pcall(require, "claude_agents.agents.registry")
    local term = ok and registry.get(rc.session_id) or nil
    if term then
      asker.cwd = term.cwd
      if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
        asker.term_win = vim.fn.win_findbuf(term.bufnr)[1]
      end
    end
  else
    asker.term_win = tab_terminal_window(tab)
  end
  if not asker.cwd then
    asker.cwd = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))
  end
  return asker
end

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

---@param path string
---@return boolean
local function is_absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

---A path as given, made absolute against the asker's directory. `~` is expanded
---and nothing else: `vim.fn.expand` would read `$post` in `routes/$post.tsx` as
---a variable.
---@param path string
---@param cwd string|nil
---@return string
local function resolve(path, cwd)
  local out = utils.expand_tilde(path)
  if not is_absolute(out) and type(cwd) == "string" and cwd ~= "" then
    out = cwd:gsub("[/\\]$", "") .. "/" .. out
  end
  return out
end

---@param path string
---@return string
local function file_key(path)
  return utils.path_key(vim.loop.fs_realpath(path) or path)
end

---@param n any
---@return integer|nil
local function positive_int(n)
  if type(n) ~= "number" or n ~= n or n < 1 then
    return nil
  end
  return math.floor(n)
end

--------------------------------------------------------------------------------
-- Cursor and range
--------------------------------------------------------------------------------

--- buf -> augroup id of the highlight shown there.
local marks = {}

---@param buf integer
local function clear_range(buf)
  local group = marks[buf]
  if not group then
    return
  end
  marks[buf] = nil
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  pcall(vim.api.nvim_del_augroup_by_id, group)
end

---Highlight `first`..`last` in `buf` until the cursor moves off where the call
---put it (in `win`), or anywhere in another window showing the buffer.
---@param win integer
---@param buf integer
---@param first integer
---@param last integer
local function mark_range(win, buf, first, last)
  clear_range(buf)
  -- Defined on use: `:colorscheme` clears every group, a default link included.
  pcall(vim.api.nvim_set_hl, 0, M.HIGHLIGHT, { link = "Visual", default = true })
  for row = first, last do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, { line_hl_group = M.HIGHLIGHT, priority = 150 })
  end
  local ok_group, group = pcall(vim.api.nvim_create_augroup, "ClaudeCodeOpenRange" .. buf, { clear = true })
  if not ok_group then
    return
  end
  marks[buf] = group
  local placed = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      -- Placing the cursor is itself reported as a move, once.
      if vim.api.nvim_get_current_win() == win then
        local now = vim.api.nvim_win_get_cursor(win)
        if now[1] == placed[1] and now[2] == placed[2] then
          return
        end
      end
      clear_range(buf)
    end,
    desc = "Drop the range Claude opened this file at once the cursor moves",
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      clear_range(buf)
    end,
  })
end

---Put the cursor on the file's first asked line (first non-blank, folds open,
---centred) and highlight through `end_line`.
---@param win integer
---@param file { line: integer|nil, end_line: integer|nil }
local function place_cursor(win, file)
  if not file.line or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local count = vim.api.nvim_buf_line_count(buf)
  local line = math.min(file.line, count)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, win, { line, (text:find("%S") or 1) - 1 })
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zvzz")
  end)
  if file.end_line and file.end_line > line then
    mark_range(win, buf, line, math.min(file.end_line, count))
  elseif file.end_line then
    mark_range(win, buf, line, line)
  end
end

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

---@param win integer
---@return boolean
local function is_float(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative ~= nil and cfg.relative ~= ""
end

---Whether a window counts as "the file is already open there".
---@param win integer
---@return boolean
local function shows_file(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if vim.api.nvim_get_option_value("diff", { win = win }) then
    return false
  end
  local ok, tags = pcall(function()
    return { preview = vim.w[win].claudecode_live_preview, float = vim.w[win].claudecode_float }
  end)
  if not ok then
    return false
  end
  -- The plugin's own floats are somewhere the file is open. Every other tagged
  -- window (live preview, plan view host, agents pane) is passing through.
  if tags.float then
    return true
  end
  if tags.preview or is_float(win) then
    return false
  end
  return true
end

---A window already showing `path`: in the asker's tab first, then the current
---one, then any.
---@param path string
---@param asker ClaudeCodeOpenAsker
---@return integer|nil
local function visible_window(path, asker)
  local want = file_key(path)
  local tabs, seen = {}, {}
  local function add(tab)
    if tab and not seen[tab] and vim.api.nvim_tabpage_is_valid(tab) then
      seen[tab] = true
      tabs[#tabs + 1] = tab
    end
  end
  add(asker.tab)
  add(vim.api.nvim_get_current_tabpage())
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    add(tab)
  end
  for _, tab in ipairs(tabs) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if name ~= "" and shows_file(win) and file_key(name) == want then
        return win
      end
    end
  end
  return nil
end

---Hold every window of `tab` outside `keep` at its size while `fn` runs, so
---`'equalalways'` and `wincmd =` share space among `keep` and what `fn` creates.
---@param tab integer
---@param keep table<integer, boolean>
---@param fn fun()
local function holding_others(tab, keep, fn)
  local saved = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if not keep[win] and not is_float(win) then
      saved[win] = {
        vim.api.nvim_get_option_value("winfixwidth", { win = win }),
        vim.api.nvim_get_option_value("winfixheight", { win = win }),
      }
      utils.set_win_option(win, "winfixwidth", true)
      utils.set_win_option(win, "winfixheight", true)
    end
  end
  local ok, err = pcall(fn)
  for win, values in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) then
      utils.set_win_option(win, "winfixwidth", values[1])
      utils.set_win_option(win, "winfixheight", values[2])
    end
  end
  if not ok then
    error(err, 0)
  end
end

---@param path string
---@return string
local function escape(path)
  return vim.fn.fnameescape(path)
end

---Why an Ex command failed, without Vim's `Vim(edit):` wrapping.
---@param err any
---@return string
local function reason(err)
  local text = tostring(err)
  return text:match("Vim%([^)]*%):(.*)$") or text
end

--------------------------------------------------------------------------------
-- Layouts
--------------------------------------------------------------------------------

---@alias ClaudeCodeOpenPlaced { win: integer, file: table }[] Each window with the file it shows, in file order.

---Rows and columns for `n` files in a grid: as square as it gets, filled row by
---row (4 → 2×2, 3 → 2 over 1, 6 → 3×2).
---@param n integer
---@return integer rows
---@return integer cols
function M.grid_shape(n)
  local cols = math.ceil(math.sqrt(n))
  return math.ceil(n / cols), cols
end

---Split `from` and open `path` in the new window.
---@param from integer
---@param cmd string `rightbelow vsplit ` or `belowright split `.
---@param path string
---@return integer|nil win
local function split_from(from, cmd, path)
  local ok, win = pcall(vim.api.nvim_win_call, from, function()
    vim.cmd(cmd .. escape(path))
    return vim.api.nvim_get_current_win()
  end)
  if not ok then
    logger.debug("open_files", "split failed: " .. tostring(win))
    return nil
  end
  return win
end

---@param files table[]
---@param arrangement string
---@param asker ClaudeCodeOpenAsker
---@return ClaudeCodeOpenPlaced|nil placed
---@return integer|nil tab
---@return string|nil err
---@return string[]|nil skipped Files there was no room for.
local function open_tab(files, arrangement, asker)
  local after = vim.api.nvim_tabpage_get_number(asker.tab)
  local ok, err = pcall(vim.cmd, ("%dtabedit %s"):format(after, escape(files[1].path)))
  if not ok then
    return nil, nil, reason(err)
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local first = vim.api.nvim_get_current_win()
  local placed, skipped = { { win = first, file = files[1] } }, {}
  local function place(from, cmd, file)
    local win = split_from(from, cmd, file.path)
    if win then
      placed[#placed + 1] = { win = win, file = file }
    else
      skipped[#skipped + 1] = file.path
    end
    return win
  end

  if arrangement == "grid" and #files > 2 then
    local rows, cols = M.grid_shape(#files)
    -- Every row first, while each is still the tab's full width; then each row
    -- is split across. The other order would leave the rows one column wide.
    local row_start = { first }
    for r = 2, rows do
      local file = files[(r - 1) * cols + 1]
      if file then
        row_start[r] = place(row_start[r - 1] or first, "belowright split ", file)
      end
    end
    for r = 1, rows do
      local left = row_start[r]
      for c = 2, cols do
        local file = files[(r - 1) * cols + c]
        if file and left then
          left = place(left, "rightbelow vsplit ", file) or left
        elseif file then
          skipped[#skipped + 1] = file.path
        end
      end
    end
    -- Rows were opened before their columns: back into file order.
    local order = {}
    for i, file in ipairs(files) do
      order[file] = i
    end
    table.sort(placed, function(a, b)
      return order[a.file] < order[b.file]
    end)
  else
    local split = arrangement == "horizontal" and "belowright split " or "rightbelow vsplit "
    local last = first
    for i = 2, #files do
      last = place(last, split, files[i]) or last
    end
  end
  pcall(vim.cmd, "wincmd =")
  return placed, tab, nil, skipped
end

---@param files table[]
---@param vertical boolean
---@param asker ClaudeCodeOpenAsker
---@return ClaudeCodeOpenPlaced|nil placed
---@return integer|nil anchor The window they were opened beside.
---@return string|nil err
---@return string[]|nil skipped
local function open_splits(files, vertical, asker)
  local tab = asker.tab
  local diff = require("claude_agents.diff")
  local anchor
  if asker.term_win and vim.api.nvim_win_is_valid(asker.term_win) then
    anchor = diff.find_window_closest_to_terminal(asker.term_win)
  else
    anchor = diff._find_main_editor_window(vim.api.nvim_tabpage_list_wins(tab))
  end

  local beside = vertical and "rightbelow vsplit " or "belowright split "
  -- Nothing to open beside but the terminal: the first file gets a window of its
  -- own along the far edge, and the rest split that one.
  local edge = vertical and "topleft vsplit " or "topleft split "
  local host = anchor or asker.term_win or vim.api.nvim_tabpage_list_wins(tab)[1]
  local placed, skipped = {}, {}
  local keep = anchor and { [anchor] = true } or {}
  local failure
  local ok = pcall(holding_others, tab, keep, function()
    for i, file in ipairs(files) do
      local cmd = (not anchor and i == 1) and edge or beside
      local ok_win, win_or_err = pcall(vim.api.nvim_win_call, host, function()
        vim.cmd(cmd .. escape(file.path))
        return vim.api.nvim_get_current_win()
      end)
      if ok_win then
        placed[#placed + 1] = { win = win_or_err, file = file }
        keep[win_or_err] = true
        host = win_or_err
      elseif #placed == 0 then
        failure = reason(win_or_err)
        return
      else
        skipped[#skipped + 1] = file.path
      end
    end
    pcall(vim.api.nvim_win_call, placed[1] and placed[1].win or host, function()
      vim.cmd("wincmd =")
    end)
  end)
  if failure or not ok or #placed == 0 then
    return nil, nil, failure or "could not split a window"
  end
  return placed, anchor, nil, skipped
end

---@param file table
---@param asker ClaudeCodeOpenAsker
---@return integer|nil win
local function open_float(file, asker)
  local diff = require("claude_agents.diff")
  local owner = diff._layout_owner(asker.tab)
  local agents_float = owner and owner.float_module == "claude_agents.agents.float"
  local note = (asker.kind == "agent" and asker.session_id) and ("·  " .. asker.session_id:sub(1, 8)) or nil
  local win
  if agents_float then
    local float = require("claude_agents.agents.float")
    local title = utils.path_title(file.path, asker.cwd, note, float.title_width())
    win = float.open_file(asker.session_id, file.path, nil, nil, title)
  else
    local float = require("claude_agents.float")
    local title = utils.path_title(file.path, asker.cwd, note, float.title_width())
    win = float.open_file({ path = file.path, title = title, session_id = asker.session_id })
  end
  if win then
    -- Asked for, not glimpsed: it belongs in `:ls` like any file you open.
    pcall(vim.api.nvim_set_option_value, "buflisted", true, { buf = vim.api.nvim_win_get_buf(win) })
  end
  return win
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---@param asker ClaudeCodeOpenAsker
---@param path string
---@return string
local function shown(asker, path)
  return utils.relative_path(path, asker.cwd)
end

---@param asker ClaudeCodeOpenAsker
---@param file table
---@return string
local function describe(asker, file)
  local text = shown(asker, file.path)
  if file.line and file.end_line and file.end_line > file.line then
    text = ("%s (lines %d-%d)"):format(text, file.line, file.end_line)
  elseif file.line then
    text = ("%s (line %d)"):format(text, file.line)
  end
  return text
end

---@param asker ClaudeCodeOpenAsker
---@param files table[]
---@return string
local function list(asker, files)
  local parts = {}
  for _, file in ipairs(files) do
    parts[#parts + 1] = describe(asker, file)
  end
  return table.concat(parts, ", ")
end

---@param items string[]
---@param value any
---@return boolean
local function contains(items, value)
  for _, item in ipairs(items) do
    if item == value then
      return true
    end
  end
  return false
end

---@param message string
---@param code integer|nil
---@return nil, { code: integer, message: string }
local function fail(message, code)
  return nil, { code = code or M.FAILED, message = message }
end

---Validate and resolve a request's files.
---@param raw any
---@param cwd string|nil
---@return table[]|nil files
---@return { code: integer, message: string }|nil err
local function read_files(raw, cwd)
  if type(raw) ~= "table" or #raw == 0 then
    return fail("files must be a non-empty list of { path, line?, end_line? }", M.INVALID)
  end
  local files, missing = {}, {}
  for i, entry in ipairs(raw) do
    if type(entry) == "string" then
      entry = { path = entry }
    end
    if type(entry) ~= "table" or type(entry.path) ~= "string" or entry.path == "" then
      return fail(("files[%d] needs a path"):format(i), M.INVALID)
    end
    local path = resolve(entry.path, cwd)
    local stat = vim.loop.fs_stat(path)
    if not stat then
      missing[#missing + 1] = path
    else
      local line = positive_int(entry.line)
      files[#files + 1] = {
        path = path,
        line = line,
        end_line = line and positive_int(entry.end_line) or nil,
        directory = stat.type == "directory",
      }
    end
  end
  if #missing > 0 then
    return fail("No such file: " .. table.concat(missing, ", "))
  end
  return files, nil
end

---Leave the cursor where it was before a layout moved it, terminal mode included.
---@param win integer
---@param terminal boolean
local function go_back(win, terminal)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_set_current_win, win)
  if terminal and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal" then
    pcall(vim.cmd, "startinsert")
  end
end

---Open files for the model.
---@param req { files: any, layout: string|nil, arrangement: string|nil, focus: boolean|nil }
---@param asker ClaudeCodeOpenAsker
---@return { message: string, layout: string, windows: integer[], tab: integer|nil, jumped: boolean }|nil
---@return { code: integer, message: string }|nil err
function M.open(req, asker)
  req = type(req) == "table" and req or {}
  local opts = M.opts()

  local layout = req.layout or opts.layout
  if not contains(M.LAYOUTS, layout) then
    return fail("layout must be one of: " .. table.concat(M.LAYOUTS, ", "), M.INVALID)
  end
  local arrangement = req.arrangement or "vertical"
  if not contains(M.ARRANGEMENTS, arrangement) then
    return fail("arrangement must be one of: " .. table.concat(M.ARRANGEMENTS, ", "), M.INVALID)
  end
  local focus = req.focus
  if type(focus) ~= "boolean" then
    focus = opts.focus ~= false
  end

  local files, err = read_files(req.files, asker.cwd)
  if not files then
    return nil, err
  end

  if layout == "float" and #files > 1 then
    return fail("A float shows one file; use layout 'tab' for several", M.INVALID)
  end

  -- Asked for by name, a float or a split is opened even for a file already on
  -- screen. Decided on what the call said, before the agents view turns a split
  -- into a tab.
  local asked_fresh = req.layout == "float" or req.layout == "split" or req.layout == "vsplit"

  -- A tab that owns its layout (the agents view) has no editor window to split.
  local owner = require("claude_agents.diff")._layout_owner(asker.tab)
  local note = ""
  if (layout == "split" or layout == "vsplit") and owner and owner.forbids_split then
    arrangement = layout == "split" and "horizontal" or "vertical"
    layout = "tab"
    note = " (this view has no window to split)"
  end

  local before_win = vim.api.nvim_get_current_win()
  local before_terminal = vim.fn.mode() == "t"

  if #files == 1 and not files[1].directory and not asked_fresh then
    local win = visible_window(files[1].path, asker)
    if win then
      if focus then
        pcall(vim.api.nvim_set_current_win, win)
      end
      place_cursor(win, files[1])
      local tabnr = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(win))
      return {
        message = ("%s was already open in tab %d; %s."):format(
          describe(asker, files[1]),
          tabnr,
          focus and "moved the cursor there" or "left the cursor where it was"
        ),
        layout = layout,
        windows = { win },
        tab = vim.api.nvim_win_get_tabpage(win),
        jumped = true,
      }
    end
  end

  if layout == "float" then
    local win = open_float(files[1], asker)
    if not win then
      return fail("Could not open a float for " .. files[1].path)
    end
    place_cursor(win, files[1])
    return {
      message = ("Opened %s in a float; q closes it."):format(describe(asker, files[1])),
      layout = layout,
      windows = { win },
      tab = vim.api.nvim_get_current_tabpage(),
      jumped = false,
    }
  end

  local placed, tab, open_err, skipped
  local where
  if layout == "tab" then
    placed, tab, open_err, skipped = open_tab(files, arrangement, asker)
    if placed then
      local how = ""
      if #placed > 2 and arrangement == "grid" then
        local rows, cols = M.grid_shape(#files)
        how = (", in a %d×%d grid"):format(cols, rows)
      elseif #placed > 1 then
        how = arrangement == "horizontal" and ", stacked" or ", side by side"
      end
      where = ("in a new tab (tab %d%s)%s"):format(vim.api.nvim_tabpage_get_number(tab), how, note)
    end
  else
    local anchor
    placed, anchor, open_err, skipped = open_splits(files, layout == "vsplit", asker)
    tab = asker.tab
    if placed then
      local anchor_name = anchor and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(anchor)) or ""
      where = ("in %s beside %s in tab %d"):format(
        #placed > 1 and "splits" or "a split",
        anchor_name ~= "" and shown(asker, anchor_name) or "the terminal",
        vim.api.nvim_tabpage_get_number(tab)
      )
    end
  end
  if not placed then
    return fail(("Could not open %s: %s"):format(files[1].path, tostring(open_err)))
  end

  local opened, wins = {}, {}
  for _, entry in ipairs(placed) do
    opened[#opened + 1] = entry.file
    wins[#wins + 1] = entry.win
    place_cursor(entry.win, entry.file)
  end

  if focus then
    pcall(vim.api.nvim_set_current_win, wins[1])
  else
    go_back(before_win, before_terminal)
  end

  local message = ("Opened %s %s; %s."):format(
    list(asker, opened),
    where,
    focus and "the cursor is in it" or "the cursor stayed where it was"
  )
  if skipped and #skipped > 0 then
    message = message .. " No room for: " .. table.concat(skipped, ", ") .. "."
  end
  return { message = message, layout = layout, windows = wins, tab = tab, jumped = false }
end

-- Exposed for tests.
M._resolve = resolve
M._visible_window = visible_window
M._clear_range = clear_range
M._ns = ns

return M
