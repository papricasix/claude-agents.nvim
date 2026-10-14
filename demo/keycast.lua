-- Shows the keys a demo recording presses, with what each one does, in a badge
-- at the bottom of the screen: a GIF cannot show a keypress, and without it a
-- viewer sees the screen change and cannot tell why. Loaded by demo/init.lua.
--
-- Typed prompt text is not echoed (it is on screen in the terminal already);
-- shown are keys with a modifier, keys pressed in a pane or a float, Enter that
-- sends a prompt, and an Ex command when it runs.

local M = {}

local HOLD_MS = 1800
local SEQUENCE_MS = 600

-- What a key does, by where it is pressed. `float` is any of the view's
-- floating windows; `pane` matches every pane not named on its own.
local LABELS = {
  ["<C-N>"] = { any = "next session" },
  ["<C-P>"] = { any = "previous session" },
  ["<Tab>"] = { pane = "next pane", float = "fold / unfold" },
  ["<CR>"] = {
    center = "start this session",
    sessions = "show this session",
    feed = "open this call",
    changes = "what the session did to this file",
    subagents = "open this task",
    float = "open",
    terminal = "send",
  },
  ["<BS>"] = { float = "back" },
  ["q"] = { float = "close", pane = "close the view" },
  ["m"] = { pane = "flag this session" },
  ["M"] = { pane = "flag with a note" },
  ["a"] = { pane = "start a new agent" },
  ["A"] = { pane = "new agent named after this one" },
  ["i"] = { pane = "into the agent's terminal" },
  ["x"] = { pane = "stop this agent" },
  ["f"] = { pane = "filter: all / files / commands" },
  ["g."] = { pane = "name rows by type" },
  ["gc"] = { pane = "checkpoint" },
  ["gs"] = { pane = "sort / time window" },
  ["gf"] = { sessions = "search the conversations", pane = "open the file in a tab" },
  ["."] = { pane = "diff against git HEAD" },
  ["?"] = { pane = "help" },
  -- keytrans() spells Ctrl-\ as <C-Bslash>.
  ["<C-Bslash><C-N>"] = { any = "leave the terminal" },
}

local COMMANDS = {
  w = "accept the edit",
  q = "reject the edit",
}

local state = { win = nil, buf = nil, timer = nil, pending = "", pending_at = 0, ns = nil }

---`<C-N>` → `Ctrl-N`, `<CR>` → `Enter`, as a viewer reads them.
---@param keys string keytrans() form
---@return string
local function pretty(keys)
  local names = { CR = "Enter", Tab = "Tab", BS = "Backspace", Esc = "Esc", Space = "Space", Bslash = "\\" }
  return (
    keys
      :gsub("<([^>]+)>", function(inner)
        local mod, key = inner:match("^([CMSAD])%-(.+)$")
        if mod then
          local word = ({ C = "Ctrl", M = "Alt", S = "Shift", A = "Alt", D = "Cmd" })[mod]
          return word .. "-" .. (names[key] or key) .. " "
        end
        return (names[inner] or inner) .. " "
      end)
      :gsub("%s+$", "")
  )
end

---Where a key lands: a pane's name, "float", "terminal", or nil for anywhere else.
---@return string|nil
local function context()
  local win = vim.api.nvim_get_current_win()
  if vim.w[win].claudecode_float then
    return "float"
  end
  local pane = vim.w[win].claudecode_agents
  if pane and pane ~= "center" then
    return pane
  end
  if vim.bo.buftype == "terminal" then
    return "terminal"
  end
  return pane
end

---@param keys string
---@param where string|nil
---@return string|nil
local function label_for(keys, where)
  local entry = LABELS[keys]
  if not entry then
    return nil
  end
  if entry.any then
    return entry.any
  end
  if where and entry[where] then
    return entry[where]
  end
  if where and where ~= "terminal" and where ~= "float" and entry.pane then
    return entry.pane
  end
  return nil
end

local function hide()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    -- `noautocmd`: the agents view restores its pane sizes whenever a window in
    -- its tab closes, and the badge is not one of its windows.
    vim.cmd("noautocmd call nvim_win_close(" .. state.win .. ", v:true)")
  end
  state.win = nil
end

---@param keys string
---@param label string|nil
local function show(keys, label)
  local key_text = " " .. pretty(keys) .. " "
  local text = label and (key_text .. "  " .. label .. " ") or key_text

  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(state.buf, state.ns, 0, 0, { end_col = #key_text, hl_group = "DemoKeycastKey" })

  local width = vim.fn.strdisplaywidth(text)
  local config = {
    relative = "editor",
    row = vim.o.lines - 5,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 250,
  }
  -- A float lives in one tabpage; the agents view opens its own.
  if
    state.win
    and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_win_set_config(state.win, config)
  else
    hide()
    config.noautocmd = true
    state.win = vim.api.nvim_open_win(state.buf, false, config)
    vim.wo[state.win].winhighlight = "NormalFloat:DemoKeycast,FloatBorder:DemoKeycastBorder"
    -- Not a window anything should open a file in.
    vim.w[state.win].claudecode_live_preview = true
  end

  state.timer = state.timer or vim.uv.new_timer()
  state.timer:stop()
  state.timer:start(HOLD_MS, 0, vim.schedule_wrap(hide))
end

local function on_key(_, typed)
  if not typed or typed == "" then
    return
  end
  local keys = vim.fn.keytrans(typed)
  local mode = vim.api.nvim_get_mode().mode
  local where = context()

  -- An Ex command is shown when it runs, by what it is.
  if mode:sub(1, 1) == "c" then
    if keys == "<CR>" and vim.fn.getcmdtype() == ":" then
      local cmd = vim.fn.getcmdline()
      local label = COMMANDS[vim.trim(cmd)]
      vim.schedule(function()
        show(":" .. cmd .. " <CR>", label)
      end)
    end
    return
  end

  -- In a terminal, what is typed is the prompt: only modified keys and the
  -- Enter that sends it are shown.
  if mode == "t" then
    local modified = keys:match("^<[CMAD]%-") ~= nil
    if not modified and keys ~= "<CR>" then
      return
    end
  elseif mode ~= "n" and mode ~= "nt" then
    return
  end
  if mode == "n" and keys == ":" then
    return -- the command line shows itself
  end

  -- Two keys in quick succession are one sequence (`g.`, `gc`, `<C-\><C-N>`).
  local now = vim.uv.now()
  local sequence = keys
  if state.pending ~= "" and now - state.pending_at < SEQUENCE_MS and LABELS[state.pending .. keys] then
    sequence = state.pending .. keys
  end
  state.pending, state.pending_at = keys, now

  -- A key's first half waits for its second rather than flashing on its own.
  if sequence == "g" or sequence == "<C-Bslash>" then
    return
  end
  -- In a terminal's normal mode a key means what it means in any editor window.
  local ctx = where
  if mode == "t" then
    ctx = "terminal"
  elseif where == "terminal" then
    ctx = nil
  end
  local label = label_for(sequence, ctx)
  vim.schedule(function()
    show(sequence, label)
  end)
end

function M.setup()
  state.ns = vim.api.nvim_create_namespace("demo_keycast")
  vim.api.nvim_set_hl(0, "DemoKeycast", { link = "NormalFloat", default = true })
  vim.api.nvim_set_hl(0, "DemoKeycastBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "DemoKeycastKey", { link = "Title", default = true })
  vim.on_key(on_key, state.ns)
end

return M
