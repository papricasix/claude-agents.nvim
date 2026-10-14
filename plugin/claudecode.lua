if vim.fn.has("nvim-0.10.0") ~= 1 then
  vim.api.nvim_err_writeln("Claude Code requires Neovim >= 0.10.0")
  return
end

if vim.g.loaded_claudecode then
  return
end
vim.g.loaded_claudecode = 1

-- The module was called `claudecode` before; a config that still requires
-- `claudecode.<mod>` gets the `claude_agents` module, with a one-time warning.
require("claude_agents.compat").install()

--- Example: In your `init.lua`, you can set `vim.g.claudecode_auto_setup = { auto_start = true }`
--- to automatically start ClaudeCode when Neovim loads.
if vim.g.claudecode_auto_setup then
  vim.defer_fn(function()
    require("claude_agents").setup(vim.g.claudecode_auto_setup)
  end, 0)
end

-- Commands are now registered in lua/claude_agents/init.lua's _create_commands function
-- when require("claude_agents").setup() is called.
-- This file (plugin/claudecode.lua) is primarily for the load guard
-- and the optional auto-setup mechanism.

local main_module_ok, _ = pcall(require, "claude_agents")
if not main_module_ok then
  vim.notify("ClaudeCode: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
end
