-- Development spec shared by the oil, mini-files, nvim-tree and netrw
-- fixtures, each of which links to it from lua/plugins/dev-claudecode.lua.
--
-- Loads the plugin from the checkout the fixture lives in: the `vv` launcher
-- sets XDG_CONFIG_HOME to the fixtures/ directory, so the repository root is
-- its parent. That holds for a plain checkout and for a git worktree alike.
local repo_root = vim.fn.fnamemodify(vim.env.XDG_CONFIG_HOME or vim.fn.getcwd(), ":h")

return {
  "papricasix/claude-agents.nvim",
  dir = repo_root,
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },

    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },

    { "<leader>as", "<cmd>ClaudeCodeAdd %<cr>", mode = "n", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file from tree",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },

    { "<leader>ao", "<cmd>ClaudeCodeOpen<cr>", desc = "Open Claude" },
    { "<leader>aq", "<cmd>ClaudeCodeClose<cr>", desc = "Close Claude" },
    { "<leader>ai", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude Status" },
    { "<leader>aS", "<cmd>ClaudeCodeStart<cr>", desc = "Start Claude Server" },
    { "<leader>aQ", "<cmd>ClaudeCodeStop<cr>", desc = "Stop Claude Server" },

    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  ---@type PartialClaudeCodeConfig
  opts = {
    focus_after_send = true,
    -- log_level = "debug",
    -- terminal = { provider = "native", auto_close = false },
  },
}
