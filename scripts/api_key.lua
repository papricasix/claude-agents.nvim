-- claudecode.nvim API key helper (cross-platform).
--
-- A launch profile with `auth = "api"` hands the Claude CLI this script as its
-- `apiKeyHelper`, run as:
--
--   nvim --headless -u NONE -l <this-file> get <entry>
--
-- It reads the key stored under `<entry>` in the OS keychain and prints it to
-- the CLI. The plugin itself never sees the key. `check <entry>` and
-- `check-cmd <command>` describe a key without printing it, for `:checkhealth`
-- and the profile menu. The logic lives in `lua/claude_agents/api_key.lua`.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:gsub("[/\\]scripts[/\\]api_key%.lua$", "")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local code = require("claude_agents.api_key").main(arg or {})
io.stdout:flush()
io.stderr:flush()
os.exit(code)
