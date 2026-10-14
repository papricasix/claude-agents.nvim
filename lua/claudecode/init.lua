-- The plugin's former module name. Its modules now live under `claude_agents`;
-- this file keeps a config's `require("claudecode")` working (warning once),
-- and `claude_agents.compat` does the same for `require("claudecode.<mod>")`.
local compat = require("claude_agents.compat")
compat.install()
return compat.load("claudecode")
