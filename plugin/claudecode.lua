if vim.fn.has("nvim-0.10.0") ~= 1 then
  vim.api.nvim_err_writeln("Claude Code requires Neovim >= 0.10.0")
  return
end

if vim.g.loaded_claudecode then
  return
end
vim.g.loaded_claudecode = 1

--- Example: In your `init.lua`, you can set `vim.g.claudecode_auto_setup = { auto_start = true }`
--- to automatically start ClaudeCode when Neovim loads.
if vim.g.claudecode_auto_setup then
  vim.defer_fn(function()
    require("claudecode").setup(vim.g.claudecode_auto_setup)
  end, 0)
end

-- Commands are now registered in lua/claudecode/init.lua's _create_commands function
-- when require("claudecode").setup() is called.
-- This file (plugin/claudecode.lua) is primarily for the load guard
-- and the optional auto-setup mechanism.

local main_module_ok, _ = pcall(require, "claudecode")
if not main_module_ok then
  vim.notify("ClaudeCode: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
end
