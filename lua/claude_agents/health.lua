--- Health check for claude-agents.nvim, run via `:checkhealth claude_agents`.
---
--- Verifies the prerequisites (Neovim version, Claude CLI, terminal provider)
--- and reports live integration state -- every running instance's WebSocket
--- server, its lock file and whether a Claude is connected to it -- without
--- launching anything.
---@module 'claude_agents.health'
local M = {}

-- vim.health gained start/ok/warn/error in Neovim 0.10; older versions use report_* variants.
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error
local info = health.info or health.report_info or ok

---Extracts the executable (first token) from a command string.
---@param cmd string
---@return string executable
local function executable_of(cmd)
  assert(type(cmd) == "string" and cmd ~= "", "cmd must be a non-empty string")
  return cmd:match("^(%S+)") or cmd
end

-- 0.10 is the floor (the terminal-link capture registers a TermRequest
-- autocmd, which older versions reject). On 0.10 TermRequest hands over the
-- sequence as a bare string rather than `data.sequence`, so links never open.
local function check_neovim()
  if vim.fn.has("nvim-0.11.0") == 1 then
    ok("Neovim >= 0.11.0")
  elseif vim.fn.has("nvim-0.10.0") == 1 then
    warn("Neovim 0.10: clicking file paths in the Claude terminal needs 0.11")
  else
    error_("Neovim >= 0.10.0 is required")
  end
end

---@param claudecode table The main plugin module
---@return boolean set_up
local function check_setup(claudecode)
  if claudecode.state.initialized then
    ok("claude-agents.nvim " .. claudecode.version:string() .. " is set up")
    return true
  end
  error_(
    "setup() has not been called",
    { 'Call require("claude_agents").setup() (or use your plugin manager\'s opts)' }
  )
  return false
end

---@param config table The merged plugin config
local function check_cli(config)
  local terminal_cmd = config.terminal_cmd
  local cmd = (terminal_cmd and terminal_cmd ~= "") and terminal_cmd or "claude"
  local exe = executable_of(cmd)

  if vim.fn.executable(exe) ~= 1 then
    if config.backend == "opencode" then
      -- Only a launch under a Claude profile would need it.
      info(("Claude CLI not found ('%s'); only launches under a Claude profile need it"):format(exe))
      return
    end
    error_(("Claude CLI not found: '%s' is not executable"):format(exe), {
      "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
      "Or set `terminal_cmd` in setup() to the full path of the CLI",
    })
    return
  end

  ok(("Claude CLI found: %s (%s)"):format(exe, vim.fn.exepath(exe)))

  local version_ok, output = pcall(vim.fn.system, { exe, "--version" })
  if version_ok and vim.v.shell_error == 0 then
    info("CLI version: " .. vim.trim(output))
  else
    warn(("'%s --version' failed; the configured command may not be the Claude CLI"):format(exe))
  end
end

---@param config table The merged plugin config
local function check_terminal_provider(config)
  local provider = config.terminal and config.terminal.provider or "auto"
  if type(provider) == "table" then
    info("Terminal provider: custom (table)")
    return
  end

  if provider == "auto" or provider == "snacks" then
    local has_snacks = pcall(require, "snacks")
    if has_snacks then
      ok(("Terminal provider '%s': snacks.nvim available"):format(provider))
    elseif provider == "snacks" then
      error_("Terminal provider 'snacks' configured but snacks.nvim is not installed")
    else
      ok("Terminal provider 'auto': snacks.nvim not installed, will fall back to native terminal")
    end
  elseif provider == "external" then
    local cmd = config.terminal.provider_opts and config.terminal.provider_opts.external_terminal_cmd
    if cmd and (type(cmd) == "function" or cmd:find("%%s")) then
      ok("Terminal provider 'external' configured")
    else
      error_("Terminal provider 'external' requires provider_opts.external_terminal_cmd containing '%s'")
    end
  else
    ok(("Terminal provider: %s"):format(provider))
  end
end

---Features that only work with a plugin we do not depend on say so here rather
---than at the moment they silently fall back.
---@param config table The merged plugin config
local function check_optional_deps(config)
  local diff_opts = config.diff_opts or {}
  local wants_unified = diff_opts.provider == "unified" or diff_opts.layout == "float"
  local has_unified = pcall(require, "unified.diff")

  if has_unified then
    ok("unified.nvim available (inline diffs, live cursor edit previews, file history)")
  elseif wants_unified then
    warn("unified.nvim is not installed; inline/float diffs fall back to a two-window split", {
      "Install papricasix/unified.nvim for the inline renderer (the fork; the original lacks show_against_text)",
    })
  else
    info("unified.nvim not installed: diffs use the native two-window split")
  end

  if config.agents and config.agents.enabled and not pcall(require, "snacks") then
    info("snacks.nvim not installed: agents mode uses plain floating windows")
  end
end

---Launch profiles: what each is, and whether an API profile's key is stored.
---
---The key is asked of the helper script, which reports whether a key is there
---and what it looks like, never the key: nothing secret passes through Neovim
---even here.
local function check_profiles()
  local profiles = require("claude_agents.profiles")
  local api_key = require("claude_agents.api_key")
  local default = profiles.default_name()
  local backend = require("claude_agents.opencode").default_backend() == "opencode" and "OpenCode" or "the Claude CLI"
  info(
    "Plain launches ("
      .. (default and ("profile " .. default) or ("as configured: " .. backend .. " decides"))
      .. "). :ClaudeCodeProfile, and ga/gi in the agents view, pick one"
  )

  for _, profile in ipairs(profiles.list()) do
    local label = ("profile %q"):format(profile.name)
    if profile.backend == "opencode" then
      local detail = {}
      if profile.model then
        detail[#detail + 1] = "model " .. profile.model
      end
      if profile.agent then
        detail[#detail + 1] = "agent " .. profile.agent
      end
      ok(
        label
          .. ": runs OpenCode"
          .. (#detail > 0 and (" (" .. table.concat(detail, ", ") .. ")") or ", on OpenCode's own model and agent")
      )
    elseif profile.auth == "subscription" then
      ok(label .. ": your subscription (the claude.ai login)")
    else
      local source = profile.api_key_cmd and ("api_key_cmd: " .. profile.api_key_cmd)
        or ("keychain entry " .. api_key.SERVICE .. "/" .. profile.keychain)
      local check = profiles.check_sync(profile)
      if check.state == "found" and check.shape == "ok" then
        ok(("%s: API key found (%s, %d characters)"):format(label, source, check.length))
      elseif check.state == "found" then
        warn(
          ("%s: a key was found (%s) but does not look like an Anthropic API key (%s)"):format(
            label,
            source,
            check.shape
          ),
          { "The CLI takes the helper's whole output as the key: it must print the key and nothing else" }
        )
      elseif check.state == "missing" then
        warn(("%s: no API key stored (%s)"):format(label, source), {
          profile.api_key_cmd and "The command printed nothing"
            or ("Store it once, in a terminal: " .. api_key.store_command(profile.keychain)),
        })
      else
        error_(("%s: reading the key failed: %s"):format(label, check.detail or "unknown error"))
      end
    end
  end

  -- What plain launches run on, beyond what the plugin decides.
  if (os.getenv("ANTHROPIC_API_KEY") or "") ~= "" then
    warn("ANTHROPIC_API_KEY is set in Neovim's environment", {
      "Plain launches inherit it and run on that key (the CLI asks once to approve it), and every command Claude runs can read it",
      "Launch profiles blank it; storing the key in the keychain for an API profile keeps it out of the environment",
    })
  end
  local settings_path = require("claude_agents.utils").claude_config_dir() .. "/settings.json"
  local ok_read, lines = pcall(vim.fn.readfile, settings_path)
  if ok_read and type(lines) == "table" then
    local ok_json, settings = pcall(vim.json.decode, table.concat(lines, "\n"))
    if
      ok_json
      and type(settings) == "table"
      and type(settings.apiKeyHelper) == "string"
      and settings.apiKeyHelper ~= ""
    then
      info(
        "Your Claude settings set an apiKeyHelper: plain launches run on it, the subscription profile switches it off"
      )
    end
  end
end

---Each Claude the plugin is running -- a tab's own one and any agents -- has its
---own server, port, token and lock file, so the report is per instance.
---@param claudecode table The main plugin module
local function check_instances(claudecode)
  local lockfile = require("claude_agents.lockfile")
  local instances = {}
  for _, inst in pairs(claudecode.instances or {}) do
    instances[#instances + 1] = inst
  end

  if #instances == 0 then
    warn("No WebSocket server is running", {
      "A server starts per tab when that tab's Claude is launched (auto_start = true)",
      "Or start one manually with :ClaudeCodeStart",
    })
    return
  end

  table.sort(instances, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)

  for _, inst in ipairs(instances) do
    local label = inst.kind == "agent" and ("agent " .. tostring(inst.session_id)) or ("tab " .. tostring(inst.tab))
    local status = inst.server and inst.server.get_status() or { running = false }

    if not status.running then
      error_(("%s: server registered but not running"):format(label))
    else
      ok(("%s: WebSocket server on port %d"):format(label, status.port))

      local lock_path = lockfile.lock_dir .. "/" .. tostring(status.port) .. ".lock"
      if vim.fn.filereadable(lock_path) == 1 then
        ok(("%s: lock file present (%s)"):format(label, lock_path))
      else
        error_(("%s: lock file missing (%s)"):format(label, lock_path), {
          "Claude discovers this Neovim instance through the lock file",
          "Restart the integration with :ClaudeCodeStop and :ClaudeCodeStart",
        })
      end

      local connected = status.client_count and status.client_count > 0
      if connected then
        -- The tool server (`open_files`) is a second connection from the same CLI.
        local tool_conns = 0
        for _, client in ipairs(status.clients or {}) do
          if client.role == "tools" then
            tool_conns = tool_conns + 1
          end
        end
        if tool_conns > 0 then
          info(
            ("%s: %d client(s) connected (%d of them the open_files tool server)"):format(
              label,
              status.client_count,
              tool_conns
            )
          )
        else
          info(("%s: %d client(s) connected"):format(label, status.client_count))
        end
      else
        info(("%s: no Claude connected yet (launch one with :ClaudeCode)"):format(label))
      end

      local refused = status.tokenless_refused or 0
      if refused > 0 then
        -- `info` takes no advice list, so the explanation goes in the line.
        info(
          (
            "%s: refused %d connection(s) without the token, the last at %s. An OpenCode started inside a"
            .. " terminal this plugin launched (by its shell tool, say) inherits this port and retries every"
            .. " 10 seconds until it exits; nothing needs doing"
          ):format(label, refused, os.date("%H:%M:%S", status.tokenless_refused_at))
        )
      end
    end
  end
end

---OpenCode, when it is the backend or a profile runs it: the binary, its
---background service (asked, never started), and what the integration does.
---@param config table The merged plugin config
local function check_opencode(config)
  local opencode = require("claude_agents.opencode")
  local profiles = require("claude_agents.profiles")
  local wanted = config.backend == "opencode"
  for _, profile in ipairs(profiles.list()) do
    if profile.backend == "opencode" then
      wanted = true
    end
  end
  local exe = opencode.cmd_argv()[1]
  if vim.fn.executable(exe) ~= 1 then
    if wanted then
      error_(("OpenCode not found: '%s' is not executable"):format(exe), {
        "Install OpenCode: https://opencode.ai",
        "Or set `opencode.cmd` in setup() to the full path of the executable",
      })
    else
      info('OpenCode is not installed (optional: `backend = "opencode"` or an OpenCode profile runs it)')
    end
    return
  end
  ok(("OpenCode found: %s (%s)"):format(exe, vim.fn.exepath(exe)))
  local version_ok, output = pcall(vim.fn.system, { exe, "--version" })
  if version_ok and vim.v.shell_error == 0 then
    info("OpenCode version: " .. vim.trim(output))
  end
  info(
    wanted
        and ("Plain launches run " .. (config.backend == "opencode" and "OpenCode" or "Claude") .. "; profiles may pick the other")
      or "Plain launches run Claude; the built-in OpenCode profile runs OpenCode"
  )

  local service = require("claude_agents.opencode.service")
  local switched_off = service.disabled_sync(3000) == true
  if switched_off then
    warn("OpenCode's background service is disabled: its TUIs run private servers Neovim cannot reach", {
      "Status, diff review and the agents view need the shared service: `opencode service unset disabled`",
    })
  end
  local conn, reg_err = service.read_registration()
  if not conn then
    if not switched_off then
      local by_view = (config.opencode or {}).start_service ~= "launch"
      info(
        "OpenCode's background service is not running; the first OpenCode launch starts it"
          .. (by_view and ", and so does the agents view in a directory OpenCode ran in" or "")
          .. " ("
          .. tostring(reg_err)
          .. ")"
      )
    end
  else
    local err, data = require("claude_agents.opencode.api").call_sync("GET", "/api/info", { no_start = true }, 3000)
    if err then
      warn("OpenCode's service is registered at " .. conn.url .. " but does not answer: " .. tostring(err), {
        "Restart it with `opencode service restart`",
      })
    else
      ok(("OpenCode service at %s (%s)"):format(conn.url, type(data) == "table" and tostring(data.version) or "?"))
    end
  end

  local oc = config.opencode or {}
  if oc.review_edits == false then
    info("Edit review is off (`opencode.review_edits = false`): OpenCode edits as its own rules say")
  else
    ok("OpenCode's edits are reviewed as diffs in Neovim (`opencode.review_edits`)")
  end
  info(
    "OpenCode's TUI connects to Neovim without the lock file's token; each OpenCode launch lets exactly "
      .. "one such client in, on loopback, never from a browser (Origin header), and offers it no tools"
  )
end

function M.check()
  start("claude-agents.nvim")

  check_neovim()

  local loaded, claudecode = pcall(require, "claude_agents")
  if not loaded then
    error_("Could not load claudecode module: " .. tostring(claudecode))
    return
  end

  if not check_setup(claudecode) then
    return
  end

  check_cli(claudecode.state.config)
  check_terminal_provider(claudecode.state.config)
  check_optional_deps(claudecode.state.config)
  check_instances(claudecode)

  start("Launch profiles")
  check_profiles()

  start("OpenCode")
  check_opencode(claudecode.state.config)
end

return M
