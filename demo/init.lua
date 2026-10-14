-- Neovim config the README's demo media is recorded with (`demo/render.sh`).
-- Not meant as a user config: no plugin manager, everything from fixed paths.
--
-- Environment, all set by render.sh:
--   DEMO_UNIFIED, DEMO_SNACKS, DEMO_COLORSCHEME_DIR  plugin checkouts to load
--   DEMO_COLORSCHEME                                 colorscheme name
--   DEMO_PERMISSION                                  claude --permission-mode for this shot

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)

for _, var in ipairs({ "DEMO_UNIFIED", "DEMO_SNACKS", "DEMO_COLORSCHEME_DIR" }) do
  local dir = vim.env[var]
  if dir and dir ~= "" then
    vim.opt.rtp:prepend(dir)
  end
end

vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 3
vim.o.showmode = false
vim.o.cmdheight = 1
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.mouse = ""
vim.o.splitright = true
vim.o.fillchars = "eob: "
vim.o.wrap = false
vim.o.showtabline = 0

-- Claude writes files behind Neovim's back; show its edits in the open window.
vim.o.autoread = true
vim.fn.timer_start(500, function()
  pcall(vim.cmd.checktime)
end, { ["repeat"] = -1 })

-- A terminal buffer is named after the binary it runs (`term://…//<pid>:<path to
-- claude>`), a path from the recording machine. The status line never shows it.
function _G.DemoStatusline()
  if vim.bo.buftype == "terminal" then
    return " Claude Code"
  end
  -- The agents view's panes and floats are named `claudecode://…` after what
  -- they show, the project's absolute path included.
  if vim.api.nvim_buf_get_name(0):match("^claudecode://") or vim.w.claudecode_agents then
    return " Claude agents"
  end
  local name = vim.fn.expand("%:.")
  return " " .. (name ~= "" and name or "[No Name]") .. "%m%=%l:%c "
end
vim.o.statusline = "%!v:lua.DemoStatusline()"

pcall(vim.cmd.colorscheme, vim.env.DEMO_COLORSCHEME or "habamax")

pcall(function()
  require("snacks").setup({})
end)
pcall(function()
  require("unified").setup({})
end)

-- The CLI loads only this project's settings and no MCP servers, so nothing of
-- the recording machine's own Claude setup (hooks, status line, plugins) shows.
-- No Bash: a command that asks for approval would stall a recording, and the
-- model's own look around (grep, git) differs from run to run.
local claude = "claude --model haiku --setting-sources project,local --strict-mcp-config --disallowedTools Bash"
if vim.env.DEMO_PERMISSION and vim.env.DEMO_PERMISSION ~= "" then
  claude = claude .. " --permission-mode " .. vim.env.DEMO_PERMISSION
end

require("claudecode").setup({
  log_level = "warn",
  terminal_cmd = claude,
  -- snacks titles the terminal window with the buffer name until Claude sets a
  -- title of its own; no title bar at all, for the same reason as the status line.
  terminal = { split_width_percentage = 0.45, snacks_win_opts = { wo = { winbar = "" } } },
  diff_opts = { provider = "unified" },
  live_cursor = { enabled = true, mode = "preview" },
  -- Drives the agents view's bullets from hooks, so busy and done are exact. A
  -- working session spins the CLI's own spinner, as Claude Code's prompt does.
  status = {
    enabled = true,
    icons = { busy = require("claudecode.status").SPINNER, waiting = "‼" },
    spinner_ms = 250,
  },
  -- Wide enough sidebars at 1400px that the seeded session titles fit whole.
  agents = { enabled = true, layout = { left_width = 0.255, right_width = 0.315 } },
})

vim.keymap.set("n", "<leader>ac", "<cmd>ClaudeCode<cr>")

-- The spinner in Claude's clay orange, the colour the CLI paints its own in.
vim.api.nvim_set_hl(0, "ClaudeCodeStatusBusy", { fg = "#d97757" })

-- Every key a recording presses is shown on screen, with what it does.
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/keycast.lua").setup()
