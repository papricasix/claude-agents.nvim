--- Module to manage a dedicated vertical split terminal for Claude Code.
--- Supports Snacks.nvim or a native Neovim terminal fallback.
--- @module 'claude_agents.terminal'

local M = {}

local claudecode_main = require("claude_agents")
local utils = require("claude_agents.utils")

---@type ClaudeCodeTerminalConfig
local defaults = {
  split_side = "right",
  split_width_percentage = 0.30,
  provider = "auto",
  show_native_term_exit_tip = true,
  terminal_cmd = nil,
  provider_opts = {
    external_terminal_cmd = nil,
  },
  auto_close = true,
  env = {},
  snacks_win_opts = {},
  fix_streamed_paste = "auto", -- work around Neovim <0.12.2 paste fragmentation (#161): true|false|"auto"
  -- Working directory control
  cwd = nil, -- static cwd override
  git_repo_cwd = false, -- resolve to git root when spawning
  cwd_provider = nil, -- function(ctx) -> cwd string
}

M.defaults = defaults

-- Lazy load providers
local providers = {}

---Loads a terminal provider module
---@param provider_name string The name of the provider to load
---@return ClaudeCodeTerminalProvider? provider The provider module, or nil if loading failed
local function load_provider(provider_name)
  if not providers[provider_name] then
    local ok, provider = pcall(require, "claude_agents.terminal." .. provider_name)
    if ok then
      providers[provider_name] = provider
    else
      return nil
    end
  end
  return providers[provider_name]
end

---Validates and enhances a custom table provider with smart defaults
---@param provider ClaudeCodeTerminalProvider The custom provider table to validate
---@return ClaudeCodeTerminalProvider? provider The enhanced provider, or nil if invalid
---@return string? error Error message if validation failed
local function validate_and_enhance_provider(provider)
  if type(provider) ~= "table" then
    return nil, "Custom provider must be a table"
  end

  -- Required functions that must be implemented
  local required_functions = {
    "setup",
    "open",
    "close",
    "simple_toggle",
    "focus_toggle",
    "get_active_bufnr",
    "is_available",
  }

  -- Validate all required functions exist and are callable
  for _, func_name in ipairs(required_functions) do
    local func = provider[func_name]
    if not func then
      return nil, "Custom provider missing required function: " .. func_name
    end
    -- Check if it's callable (function or table with __call metamethod)
    local is_callable = type(func) == "function"
      or (type(func) == "table" and getmetatable(func) and getmetatable(func).__call)
    if not is_callable then
      return nil, "Custom provider field '" .. func_name .. "' must be callable, got: " .. type(func)
    end
  end

  -- Create enhanced provider with defaults for optional functions
  -- Note: Don't deep copy to preserve spy functions in tests
  local enhanced_provider = provider

  -- Add default toggle function if not provided (calls simple_toggle for backward compatibility)
  if not enhanced_provider.toggle then
    enhanced_provider.toggle = function(cmd_string, env_table, effective_config)
      return enhanced_provider.simple_toggle(cmd_string, env_table, effective_config)
    end
  end

  -- Add default test function if not provided
  if not enhanced_provider._get_terminal_for_test then
    enhanced_provider._get_terminal_for_test = function()
      return nil
    end
  end

  return enhanced_provider, nil
end

---Gets the effective terminal provider, guaranteed to return a valid provider
---Falls back to native provider if configured provider is unavailable
---@return ClaudeCodeTerminalProvider provider The terminal provider module (never nil)
local function get_provider()
  local logger = require("claude_agents.logger")

  -- Handle custom table provider
  if type(defaults.provider) == "table" then
    local custom_provider = defaults.provider --[[@as ClaudeCodeTerminalProvider]]
    local enhanced_provider, error_msg = validate_and_enhance_provider(custom_provider)
    if enhanced_provider then
      -- Check if custom provider is available
      local is_available_ok, is_available = pcall(enhanced_provider.is_available)
      if is_available_ok and is_available then
        logger.debug("terminal", "Using custom table provider")
        return enhanced_provider
      else
        local availability_msg = is_available_ok and "provider reports not available" or "error checking availability"
        logger.warn(
          "terminal",
          "Custom table provider configured but " .. availability_msg .. ". Falling back to 'native'."
        )
      end
    else
      logger.warn("terminal", "Invalid custom table provider: " .. error_msg .. ". Falling back to 'native'.")
    end
    -- Fall through to native provider
  elseif defaults.provider == "auto" then
    -- Try snacks first, then fallback to native silently
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    end
    -- Fall through to native provider
  elseif defaults.provider == "snacks" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    else
      logger.warn("terminal", "'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.")
    end
  elseif defaults.provider == "external" then
    local external_provider = load_provider("external")
    if external_provider then
      -- Check availability based on our config instead of provider's internal state
      local external_cmd = defaults.provider_opts and defaults.provider_opts.external_terminal_cmd

      local has_external_cmd = false
      if type(external_cmd) == "function" then
        has_external_cmd = true
      elseif type(external_cmd) == "string" and external_cmd ~= "" and external_cmd:find("%%s") then
        has_external_cmd = true
      end

      if has_external_cmd then
        return external_provider
      else
        logger.warn(
          "terminal",
          "'external' provider configured, but provider_opts.external_terminal_cmd not properly set. Falling back to 'native'."
        )
      end
    end
  elseif defaults.provider == "native" then
    -- noop, will use native provider as default below
    logger.debug("terminal", "Using native terminal provider")
  elseif defaults.provider == "none" then
    local none_provider = load_provider("none")
    if none_provider then
      logger.debug("terminal", "Using no-op terminal provider ('none')")
      return none_provider
    else
      logger.warn("terminal", "'none' provider configured but failed to load. Falling back to 'native'.")
    end
  elseif type(defaults.provider) == "string" then
    logger.warn(
      "terminal",
      "Invalid provider configured: " .. tostring(defaults.provider) .. ". Defaulting to 'native'."
    )
  else
    logger.warn(
      "terminal",
      "Invalid provider type: " .. type(defaults.provider) .. ". Must be string or table. Defaulting to 'native'."
    )
  end

  local native_provider = load_provider("native")
  if not native_provider then
    error("ClaudeCode: Critical error - native terminal provider failed to load")
  end
  return native_provider
end

---Builds the effective terminal configuration by merging defaults with overrides
---@param opts_override table? Optional overrides for terminal appearance
---@return table config The effective terminal configuration
local function build_config(opts_override)
  local effective_config = vim.deepcopy(defaults)
  if type(opts_override) == "table" then
    local validators = {
      split_side = function(val)
        return val == "left" or val == "right"
      end,
      split_width_percentage = function(val)
        return type(val) == "number" and val > 0 and val < 1
      end,
      snacks_win_opts = function(val)
        return type(val) == "table"
      end,
      cwd = function(val)
        return val == nil or type(val) == "string"
      end,
      git_repo_cwd = function(val)
        return type(val) == "boolean"
      end,
      cwd_provider = function(val)
        local t = type(val)
        if t == "function" then
          return true
        end
        if t == "table" then
          local mt = getmetatable(val)
          return mt and mt.__call ~= nil
        end
        return false
      end,
    }
    -- The validators table is the whitelist of overridable keys. Gating on
    -- `effective_config[key] ~= nil` instead would silently drop every override
    -- whose default is nil -- which is exactly `cwd` and `cwd_provider`, so
    -- "open this terminal in that directory" quietly did nothing.
    for key, val in pairs(opts_override) do
      if validators[key] and validators[key](val) then
        effective_config[key] = val
      end
    end
  end
  -- Resolve cwd at config-build time so providers receive it directly
  local cwd_ctx = {
    file = (function()
      local path = vim.fn.expand("%:p")
      if type(path) == "string" and path ~= "" then
        return path
      end
      return nil
    end)(),
    cwd = vim.fn.getcwd(),
  }
  cwd_ctx.file_dir = cwd_ctx.file and vim.fn.fnamemodify(cwd_ctx.file, ":h") or nil

  local resolved_cwd = nil
  -- Prefer provider function, then static cwd, then git root via resolver
  if effective_config.cwd_provider then
    local ok_p, res = pcall(effective_config.cwd_provider, cwd_ctx)
    if ok_p and type(res) == "string" and res ~= "" then
      resolved_cwd = vim.fn.expand(res)
    end
  end
  if not resolved_cwd and type(effective_config.cwd) == "string" and effective_config.cwd ~= "" then
    resolved_cwd = vim.fn.expand(effective_config.cwd)
  end
  if not resolved_cwd and effective_config.git_repo_cwd then
    local ok_r, cwd_mod = pcall(require, "claude_agents.cwd")
    if ok_r and cwd_mod and type(cwd_mod.git_root) == "function" then
      resolved_cwd = cwd_mod.git_root(cwd_ctx.file_dir or cwd_ctx.cwd)
    end
  end

  return {
    split_side = effective_config.split_side,
    split_width_percentage = effective_config.split_width_percentage,
    auto_close = effective_config.auto_close,
    snacks_win_opts = effective_config.snacks_win_opts,
    cwd = resolved_cwd,
  }
end

---Checks if a terminal buffer is currently visible in any window
---@param bufnr number? The buffer number to check
---@return boolean True if the buffer is visible in any window, false otherwise
local function is_terminal_visible(bufnr)
  if not bufnr then
    return false
  end

  local bufinfo = vim.fn.getbufinfo(bufnr)
  return bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0
end

---Builds a `no_proxy` value that is guaranteed to exclude the loopback hosts
---(localhost, 127.0.0.1, ::1), merging the given existing values -- each a
---comma-separated list, nils allowed -- order-preserving and de-duplicated.
---@param ... string? Existing no_proxy/NO_PROXY values to merge ahead of the loopback hosts
---@return string combined
local function no_proxy_with_loopback(...)
  local entries = {}
  local seen = {}

  local function add_entry(entry)
    entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
    if entry ~= "" and not seen[entry] then
      seen[entry] = true
      entries[#entries + 1] = entry
    end
  end

  -- select(), not ipairs over {...}, so a nil source does not truncate the rest.
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "string" then
      for entry in value:gmatch("[^,]+") do
        add_entry(entry)
      end
    end
  end

  for _, host in ipairs({ "localhost", "127.0.0.1", "::1" }) do
    add_entry(host)
  end

  return table.concat(entries, ",")
end

M._no_proxy_with_loopback = no_proxy_with_loopback

---Gets the claude command string and necessary environment variables
---@param cmd_args string? Optional arguments to append to the command
---@param effective_config table? The built terminal config (for the spawn cwd)
---@param instance table? Server instance this launch should talk to. Defaults to
---       the current tab's; agents mode passes its own so each agent connects to
---       its own server rather than sharing the tab's.
---@param launch { profile: string|table|nil, session_id: string|nil, name: string|nil }|nil
---       Which launch profile to run under (`profiles.resolve`: else the one the
---       resumed conversation last used, else `profiles.default`); the
---       conversation an agent launch names, and what a new one is called —
---       both of which decide or shape an OpenCode launch (see `backend`).
---@return string cmd_string The command string
---@return table env_table The environment variables table
---@return string|nil profile The name of the launch profile it runs under.
local function get_claude_command_and_env(cmd_args, effective_config, instance, launch)
  -- A tab's own Claude, as opposed to an agent, which brings its own instance.
  local for_tab = instance == nil
  -- Inline get_claude_command logic
  local cmd_from_config = defaults.terminal_cmd
  local base_cmd
  if not cmd_from_config or cmd_from_config == "" then
    base_cmd = "claude" -- Default if not configured
  else
    base_cmd = cmd_from_config
  end

  local cmd_string
  if cmd_args and cmd_args ~= "" then
    cmd_string = base_cmd .. " " .. cmd_args
  else
    cmd_string = base_cmd
  end

  -- Ensure a server exists for this launch before starting the CLI. Otherwise
  -- CLAUDE_CODE_SSE_PORT is unset and the CLI scans lock files, often
  -- connecting to another tab's server and routing all requests there.
  if not instance then
    instance = claudecode_main.get_instance()
    if not instance.server then
      local started = pcall(claudecode_main.start, false)
      if started then
        instance = claudecode_main.get_instance()
      end
    end
  end

  -- OpenCode instead of Claude: its own command, environment and session
  -- handling, from the same server instance.
  local ok_backend, backend = pcall(function()
    return require("claude_agents.backend").resolve({
      profile = launch and launch.profile,
      cmd_args = cmd_args,
      session_id = launch and launch.session_id,
      tab = for_tab and vim.api.nvim_get_current_tabpage() or nil,
    })
  end)
  if ok_backend and backend == "opencode" then
    return require("claude_agents.opencode.launch").build(cmd_args, {
      instance = instance,
      for_tab = for_tab,
      cwd = (effective_config and effective_config.cwd) or vim.fn.getcwd(),
      user_env = defaults.env,
      no_proxy = no_proxy_with_loopback,
      profile = launch and launch.profile,
      name = launch and launch.name,
      model = launch and launch.model,
    })
  end

  local sse_port_value = instance.port
  local env_table = {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
  }

  if sse_port_value then
    env_table["CLAUDE_CODE_SSE_PORT"] = tostring(sse_port_value)
  else
    -- Without the port the CLI falls back to scanning ~/.claude/ide/*.lock and
    -- attaches to whatever it finds — often another Neovim, whose windows would
    -- then receive this Claude's diffs and file opens. We still launch (a broken
    -- integration should not cost you the terminal) but never silently.
    require("claude_agents.logger").error(
      "terminal",
      "No Claude Code server for this tab: the CLI will search for another editor to attach to, "
        .. "so diffs and file opens may land in the wrong Neovim. Run :ClaudeCodeStart to fix this."
    )
  end

  -- Merge custom environment variables from config
  for key, value in pairs(defaults.env) do
    env_table[key] = value
  end

  -- Session persistence: name this tab's conversation (`--session-id`), or pick
  -- the one a restored Neovim session handed back (`--resume`). No-op when the
  -- feature is off or the command already chooses a conversation itself.
  local ss_ok, session_state = pcall(require, "claude_agents.session_state")
  if ss_ok then
    local session_args = session_state.launch_args(cmd_string, effective_config and effective_config.cwd)
    if session_args ~= "" then
      cmd_string = cmd_string .. " " .. session_args
    end
  end

  -- Launch profile: which account this Claude runs on. After the session flags,
  -- since a resumed conversation goes back to the profile it last ran under.
  local profiles = require("claude_agents.profiles")
  local argv = utils.shell_split(cmd_string)
  local profile = profiles.resolve(launch and launch.profile, argv)
  local parts = profiles.launch_parts(profile, argv)
  if parts then
    if parts.args ~= "" then
      cmd_string = cmd_string .. " " .. parts.args
    end
    for key, value in pairs(parts.env) do
      env_table[key] = value
    end
    if parts.workspace then
      env_table.ANTHROPIC_CUSTOM_HEADERS = profiles.custom_headers(
        env_table.ANTHROPIC_CUSTOM_HEADERS or os.getenv("ANTHROPIC_CUSTOM_HEADERS"),
        parts.workspace
      )
    end
  end

  -- Claude honours http_proxy/all_proxy with proxy-from-env semantics, and without a
  -- loopback exclusion it tunnels even its own ws://127.0.0.1:<port> IDE connection
  -- through the proxy, so the handshake never reaches our server and queued @ mentions
  -- time out (upstream issue #70). This runs after the config and profile merges and
  -- regardless of the inherited environment (termopen layers env_table over the
  -- parent's), and merges rather than clobbers every existing source.
  local combined_no_proxy =
    no_proxy_with_loopback(os.getenv("no_proxy"), os.getenv("NO_PROXY"), env_table["no_proxy"], env_table["NO_PROXY"])
  env_table["no_proxy"] = combined_no_proxy
  env_table["NO_PROXY"] = combined_no_proxy

  -- The plugin's hooks (live cursor, plan view, status, agents) and the profile's
  -- settings, merged with the user's own `--settings` into the one file the CLI
  -- reads: a second `--settings` would replace the first (see launch_settings).
  -- This single seam covers every provider, since they all launch from these values.
  local lc_ok, live_cursor = pcall(require, "claude_agents.live_cursor")
  local hooks = lc_ok and live_cursor.build_launch_hooks() or nil
  if hooks then
    for key, value in pairs(hooks.env) do
      env_table[key] = value
    end
  end
  if lc_ok then
    cmd_string = require("claude_agents.launch_settings").apply(cmd_string, {
      hooks = hooks and hooks.settings or nil,
      profile = parts and parts.settings or nil,
      cwd = (effective_config and effective_config.cwd) or vim.fn.getcwd(),
      write = live_cursor.write_settings_file,
    })
  end

  local profile_name = profile and profile.name or nil
  if for_tab then
    profiles.set_pending_tab_launch(
      vim.api.nvim_get_current_tabpage(),
      profile_name,
      profiles.session_of_argv(utils.shell_split(cmd_string))
    )
  end
  return cmd_string, env_table, profile_name
end

---What `<S-CR>` does in a Claude terminal: insert a newline rather than submit.
---
---Exported because it is applied through two different mechanisms — the snacks
---provider hands it to `snacks.win`'s `keys` spec, while agents mode binds it on
---the terminal buffer itself (the providers hold one terminal per tabpage, so
---agents place their own). The escape sequence and its 10ms gap are the part
---that must not drift between them: change it in one place and an agent's
---terminal would quietly behave differently from every other Claude.
function M.send_newline()
  -- OpenCode's prompt takes Ctrl+J as a newline (and reads a backslash as text).
  if vim.b.claudecode_backend == "opencode" then
    vim.api.nvim_feedkeys("\n", "t", true)
    return
  end
  vim.api.nvim_feedkeys("\\", "t", true)
  vim.defer_fn(function()
    vim.api.nvim_feedkeys("\r", "t", true)
  end, 10)
end

---The current tab's terminal buffer, if its provider has one.
---@return integer|nil
local function active_bufnr()
  local ok, bufnr = pcall(function()
    return get_provider().get_active_bufnr()
  end)
  return (ok and bufnr and vim.api.nvim_buf_is_valid(bufnr)) and bufnr or nil
end

---Record which tabpage a freshly opened terminal buffer belongs to.
---
---`TermClose` reports only the buffer, and by then the terminal may not be in any
---window, so the tab has to be stamped while we still know it. Every provider
---keys its state by the *current* tabpage, so that is this terminal's tab by
---construction. Read back by the `TermClose` watcher in `init.lua` to forget a
---conversation the user ended.
---
---Also the point where this tab first counts as "has a Claude", which is what
---status tracking reports until the CLI's own hooks start arriving, and where the
---launch profile the command was built with becomes the tab's.
---
---Called after **every** provider call that can start a process — `open`, both
---toggles, `ensure_visible`. Only `open` and `ensure_visible` used to stamp, so a
---Claude started by `:ClaudeCode` (a toggle) was never stamped: closing it did
---not forget its conversation, and its tab counted as having no Claude until a
---hook arrived. A stamp is taken only when the call produced a new buffer, since
---toggles mostly just hide and show the one that is there.
---@param before integer|nil The tab's terminal buffer before the provider call.
local function tag_terminal_tab(before)
  local bufnr = active_bufnr()
  if not bufnr or bufnr == before then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  pcall(function()
    vim.b[bufnr].claudecode_tab = tab
  end)
  pcall(function()
    require("claude_agents.status").note_launch(tab)
  end)
  pcall(function()
    require("claude_agents.profiles").note_tab_terminal(tab, bufnr)
  end)
  -- An OpenCode launch built for this tab is now running: follow its session.
  if package.loaded["claude_agents.opencode.launch"] then
    pcall(function()
      require("claude_agents.opencode.launch").tab_started(tab, bufnr)
    end)
  end
end

---Common helper to open terminal without focus if not already visible
---@param opts_override table? Optional config overrides
---@param cmd_args string? Optional command arguments
---@return boolean visible True if terminal was opened or already visible
local function ensure_terminal_visible_no_focus(opts_override, cmd_args)
  local provider = get_provider()

  -- Check if provider has an ensure_visible method
  if provider.ensure_visible then
    provider.ensure_visible()
    return true
  end

  local current = provider.get_active_bufnr()

  if is_terminal_visible(current) then
    -- Terminal is already visible, do nothing
    return true
  end

  -- Terminal is not visible, open it without focus
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args, effective_config)

  local before = active_bufnr()
  provider.open(cmd_string, claude_env_table, effective_config, false) -- false = don't focus
  tag_terminal_tab(before)
  return true
end

---Configures the terminal module.
---Merges user-provided terminal configuration with defaults and sets the terminal command.
---@param user_term_config ClaudeCodeTerminalConfig? Configuration options for the terminal.
---@param p_terminal_cmd string? The command to run in the terminal (from main config).
---@param p_env table? Custom environment variables to pass to the terminal (from main config).
function M.setup(user_term_config, p_terminal_cmd, p_env)
  if user_term_config == nil then -- Allow nil, default to empty table silently
    user_term_config = {}
  elseif type(user_term_config) ~= "table" then -- Warn if it's not nil AND not a table
    vim.notify("claude_agents.terminal.setup expects a table or nil for user_term_config", vim.log.levels.WARN)
    user_term_config = {}
  end

  if p_terminal_cmd == nil or type(p_terminal_cmd) == "string" then
    defaults.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "claude_agents.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    defaults.terminal_cmd = nil -- Fallback to default behavior
  end

  if p_env == nil or type(p_env) == "table" then
    defaults.env = p_env or {}
  else
    vim.notify(
      "claude_agents.terminal.setup: Invalid env provided: " .. tostring(p_env) .. ". Using empty table.",
      vim.log.levels.WARN
    )
    defaults.env = {}
  end

  for k, v in pairs(user_term_config) do
    if k == "split_side" then
      if v == "left" or v == "right" then
        defaults.split_side = v
      else
        vim.notify("claude_agents.terminal.setup: Invalid value for split_side: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "split_width_percentage" then
      if type(v) == "number" and v > 0 and v < 1 then
        defaults.split_width_percentage = v
      else
        vim.notify(
          "claude_agents.terminal.setup: Invalid value for split_width_percentage: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "provider" then
      if type(v) == "table" or v == "snacks" or v == "native" or v == "external" or v == "auto" or v == "none" then
        defaults.provider = v
      else
        vim.notify(
          "claude_agents.terminal.setup: Invalid value for provider: " .. tostring(v) .. ". Defaulting to 'native'.",
          vim.log.levels.WARN
        )
      end
    elseif k == "provider_opts" then
      -- Handle nested provider options
      if type(v) == "table" then
        defaults[k] = defaults[k] or {}
        for opt_k, opt_v in pairs(v) do
          if opt_k == "external_terminal_cmd" then
            if opt_v == nil or type(opt_v) == "string" or type(opt_v) == "function" then
              defaults[k][opt_k] = opt_v
            else
              vim.notify(
                "claude_agents.terminal.setup: Invalid value for provider_opts.external_terminal_cmd: "
                  .. tostring(opt_v),
                vim.log.levels.WARN
              )
            end
          else
            -- For other provider options, just copy them
            defaults[k][opt_k] = opt_v
          end
        end
      else
        vim.notify(
          "claude_agents.terminal.setup: Invalid value for provider_opts: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "show_native_term_exit_tip" then
      if type(v) == "boolean" then
        defaults.show_native_term_exit_tip = v
      else
        vim.notify(
          "claude_agents.terminal.setup: Invalid value for show_native_term_exit_tip: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "auto_close" then
      if type(v) == "boolean" then
        defaults.auto_close = v
      else
        vim.notify("claude_agents.terminal.setup: Invalid value for auto_close: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "snacks_win_opts" then
      if type(v) == "table" then
        defaults.snacks_win_opts = v
      else
        vim.notify("claude_agents.terminal.setup: Invalid value for snacks_win_opts", vim.log.levels.WARN)
      end
    elseif k == "fix_streamed_paste" then
      if type(v) == "boolean" or v == "auto" then
        defaults.fix_streamed_paste = v
      else
        vim.notify(
          "claude_agents.terminal.setup: Invalid value for fix_streamed_paste: "
            .. tostring(v)
            .. " (expected true, false, or 'auto')",
          vim.log.levels.WARN
        )
      end
    elseif k == "cwd" then
      if v == nil or type(v) == "string" then
        defaults.cwd = v
      else
        vim.notify("claude_agents.terminal.setup: Invalid value for cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "git_repo_cwd" then
      if type(v) == "boolean" then
        defaults.git_repo_cwd = v
      else
        vim.notify("claude_agents.terminal.setup: Invalid value for git_repo_cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "cwd_provider" then
      local t = type(v)
      if t == "function" then
        defaults.cwd_provider = v
      elseif t == "table" then
        local mt = getmetatable(v)
        if mt and mt.__call then
          defaults.cwd_provider = v
        else
          vim.notify(
            "claude_agents.terminal.setup: cwd_provider table is not callable (missing __call)",
            vim.log.levels.WARN
          )
        end
      else
        vim.notify("claude_agents.terminal.setup: Invalid cwd_provider type: " .. tostring(t), vim.log.levels.WARN)
      end
    else
      if k ~= "terminal_cmd" then
        vim.notify("claude_agents.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
      end
    end
  end

  -- Setup providers with config
  get_provider().setup(defaults)

  -- Streamed-paste compatibility shim for #161 (no-op on Neovim >= 0.12.2).
  require("claude_agents.terminal.paste_fix").apply(defaults.fix_streamed_paste)
end

---Opens or focuses the Claude terminal.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
---@param launch { profile: string|table|nil }|nil Launch profile for a Claude this starts.
function M.open(opts_override, cmd_args, launch)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args, effective_config, nil, launch)

  local before = active_bufnr()
  get_provider().open(cmd_string, claude_env_table, effective_config)
  tag_terminal_tab(before)
end

---Closes the managed Claude terminal if it's open and valid.
function M.close()
  get_provider().close()
end

---Simple toggle: always show/hide the Claude terminal regardless of focus.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.simple_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args, effective_config)

  local before = active_bufnr()
  get_provider().simple_toggle(cmd_string, claude_env_table, effective_config)
  tag_terminal_tab(before)
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.focus_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args, effective_config)

  local before = active_bufnr()
  get_provider().focus_toggle(cmd_string, claude_env_table, effective_config)
  tag_terminal_tab(before)
end

--- Tabs whose Claude is being restarted under another profile: [tabpage] = true.
--- Its process ending is not the user closing the conversation, so the
--- `TermClose` watcher must not forget it.
local restarting = {}

---@param tab integer|nil
---@return boolean
function M.is_restarting(tab)
  return restarting[tab or vim.api.nvim_get_current_tabpage()] == true
end

--- How long a stopped CLI may take to exit before it is killed outright (ms).
M._restart_grace_ms = 5000

---The process behind a terminal buffer, and its pid.
---@param bufnr integer
---@return integer|nil job
---@return integer|nil pid
local function terminal_job(bufnr)
  local ok, job = pcall(function()
    return vim.b[bufnr].terminal_job_id
  end)
  if not ok or type(job) ~= "number" then
    return nil, nil
  end
  local ok_pid, pid = pcall(vim.fn.jobpid, job)
  return job, (ok_pid and type(pid) == "number" and pid > 0) and pid or nil
end

---Stop a terminal's process and call `done` once it has exited.
---
---Waits for the exit rather than starting the next CLI straight away: two CLIs on
---one conversation interleave their writes to its transcript, and the CLI may
---hold writes until it exits. `TermClose` is the exit; a CLI still running after
---the grace period is killed outright.
---@param bufnr integer
---@param done fun()
function M._stop_and_wait(bufnr, done)
  local job, pid = terminal_job(bufnr)
  local finished = false
  local function finish()
    if finished then
      return
    end
    finished = true
    vim.schedule(done)
  end
  if not job or vim.fn.jobwait({ job }, 0)[1] ~= -1 then
    finish()
    return
  end
  pcall(vim.api.nvim_create_autocmd, "TermClose", {
    buffer = bufnr,
    once = true,
    callback = finish,
  })
  pcall(vim.fn.jobstop, job)
  vim.defer_fn(function()
    if finished then
      return
    end
    if pid then
      pcall((vim.uv or vim.loop).kill, pid, "sigkill")
    end
    vim.defer_fn(finish, 500)
  end, M._restart_grace_ms)
end

---Whether this tab has a Claude process running.
---@return boolean
function M.is_running()
  local bufnr = active_bufnr()
  if not bufnr then
    return false
  end
  local job = terminal_job(bufnr)
  return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
end

---The conversation this tab's Claude is having, as far as anything was told:
---the launch hook's report (`status`), or the id session persistence chose.
---@param tab integer
---@return string|nil
local function tab_session_id(tab)
  local ok_status, status = pcall(require, "claude_agents.status")
  local entry = ok_status and status.get and status.get(tab)
  if entry and type(entry.session_id) == "string" and entry.session_id ~= "" then
    return entry.session_id
  end
  local ok_ss, session_state = pcall(require, "claude_agents.session_state")
  local record = ok_ss and session_state.get(tab)
  if record and record.session_id then
    return record.session_id
  end
  local oc_launch = package.loaded["claude_agents.opencode.launch"]
  return oc_launch and oc_launch.tab_session(tab) or nil
end

---Start this tab's Claude under a launch profile, or switch the running one to it.
---
---Not running: started under the profile. Running under it already: shown.
---Running under another: restarted with its conversation carried on — after a
---question when it is busy or waiting on you, since that cuts a turn off.
---@param name string Profile name (or menu key).
function M.launch_profile(name)
  local profiles = require("claude_agents.profiles")
  local profile = profiles.get(name)
  if not profile then
    vim.notify("ClaudeCode: no launch profile called " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  -- The agents view's tab has no Claude of its own: there the command is about
  -- the selected agent, like every command typed from an agent's terminal.
  local ok_view, agents_view = pcall(require, "claude_agents.agents_view")
  if ok_view and agents_view.is_view_tab() then
    agents_view.resume_selected_as(profile.name)
    return
  end
  if profiles.refuse_if_missing(profile) then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  if not M.is_running() then
    M.open({}, nil, { profile = profile.name })
    return
  end
  if profiles.of_tab(tab) == profile.name then
    M.open({}, nil)
    return
  end
  local provider_name = defaults.provider
  if provider_name == "external" or provider_name == "none" then
    vim.notify("ClaudeCode: a Claude in an external terminal cannot be switched; close it first", vim.log.levels.WARN)
    return
  end
  local session_id = tab_session_id(tab)
  -- A conversation only continues in the CLI that holds it: switching to a
  -- profile on the other backend starts a new one there instead.
  local target_backend = profiles.backend(profile)
  local current_backend = session_id and require("claude_agents.opencode").backend_of(session_id) or nil
  local crosses = current_backend ~= nil and current_backend ~= target_backend
  if not session_id and not crosses then
    vim.notify(
      "ClaudeCode: cannot tell which conversation this tab's Claude is having, so it cannot be carried over "
        .. "(it is reported by status tracking). Close it and start it again under "
        .. profile.name,
      vim.log.levels.WARN
    )
    return
  end

  local function go()
    M.restart(profile.name, (not crosses) and session_id or nil)
  end
  local ok_status, status = pcall(require, "claude_agents.status")
  local entry = ok_status and status.get and status.get(tab)
  local state = entry and entry.state
  if crosses then
    local backend = require("claude_agents.backend")
    require("claude_agents.agents.confirm").ask({
      title = "Switch to " .. backend.label(target_backend),
      message = {
        "Restart this tab in " .. backend.label(target_backend) .. " under " .. profile.name .. "?",
        "That starts a new conversation; this " .. backend.label(current_backend) .. " one can be resumed later.",
      },
      confirm = "restart",
    }, function(yes)
      if yes then
        go()
      end
    end)
    return
  end
  if state == "busy" or state == "waiting" then
    require("claude_agents.agents.confirm").ask({
      title = "Switch account",
      message = {
        "This Claude is " .. (state == "busy" and "working" or "waiting on you") .. ".",
        "Restart it under " .. profile.name .. "? The conversation carries on.",
      },
      confirm = "restart",
    }, function(yes)
      if yes then
        go()
      end
    end)
    return
  end
  go()
end

---Pick a launch profile for this tab's Claude from the profile menu.
function M.choose_profile()
  local ok_view, agents_view = pcall(require, "claude_agents.agents_view")
  if ok_view and agents_view.is_view_tab() then
    agents_view.resume_as_menu()
    return
  end
  local profiles = require("claude_agents.profiles")
  local running = M.is_running()
  local current = running and profiles.of_tab() or profiles.default_name()
  local notes = {}
  if running and current then
    notes[current] = "running"
  end
  require("claude_agents.profile_menu").open({
    title = running and "Switch this Claude to" or "Start Claude as",
    current = current,
    notes = notes,
    on_pick = M.launch_profile,
  })
end

---Restart this tab's Claude under another launch profile, carrying its
---conversation on with `--resume`.
---
---Needs the conversation id, which the CLI reports through the launch hook
---(`status`, on by default) or session persistence chose itself.
---@param profile_name string
---@param session_id string
---@param on_done fun(ok: boolean, err: string|nil)|nil
function M.restart(profile_name, session_id, on_done)
  on_done = on_done or function() end
  local tab = vim.api.nvim_get_current_tabpage()
  local bufnr = active_bufnr()
  -- nil: a fresh conversation (the profile runs the other backend). OpenCode's
  -- launch reads `--resume <ses_…>` as its own `--session`.
  local resume_args = session_id and ("--resume " .. session_id) or nil
  if not bufnr then
    M.open({}, resume_args, { profile = profile_name })
    on_done(true)
    return
  end
  restarting[tab] = true
  M._stop_and_wait(bufnr, function()
    -- The dead terminal goes, so the provider forgets it and opens a new one
    -- rather than showing the old buffer's "[Process exited]".
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    if vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_set_current_tabpage, tab)
      if not session_id then
        -- The conversation stays where it was; this tab starts a new one.
        pcall(function()
          require("claude_agents.session_state").forget(tab)
        end)
      end
      M.open({}, resume_args, { profile = profile_name })
    end
    restarting[tab] = nil
    on_done(true)
  end)
end

---Toggle open terminal without focus if not already visible, otherwise do nothing.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle_open_no_focus(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Ensures terminal is visible without changing focus. Creates if necessary, shows if hidden.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.ensure_visible(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Toggles the Claude terminal open or closed (legacy function - use simple_toggle or focus_toggle).
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle(opts_override, cmd_args)
  -- Default to simple toggle for backward compatibility
  M.simple_toggle(opts_override, cmd_args)
end

---Build the command line and environment a Claude launch needs, without opening
---anything.
---
---This is the same construction the providers get — server ensured, SSE port and
---IDE-integration vars set, user `env` merged, session-persistence flags and the
---launch hook appended. Agents mode needs it because it places its own terminals:
---the providers hold exactly one terminal per tabpage, and agents mode runs
---several in one tab.
---@param cmd_args string? Extra arguments (e.g. "--resume <id>").
---@param opts { overrides: table?, cwd: string?, instance: table?, profile: string|table|nil, session_id: string?, name: string? }|nil
---@return string cmd_string
---@return table env_table
---@return table effective_config The resolved terminal config, including the spawn cwd.
---@return string|nil profile The launch profile it runs under.
function M.build_launch(cmd_args, opts)
  opts = opts or {}
  local effective_config = build_config(opts.overrides)
  if type(opts.cwd) == "string" and opts.cwd ~= "" then
    effective_config.cwd = vim.fn.expand(opts.cwd)
  end
  local cmd_string, env_table, profile = get_claude_command_and_env(
    cmd_args,
    effective_config,
    opts.instance,
    { profile = opts.profile, session_id = opts.session_id, name = opts.name }
  )
  return cmd_string, env_table, effective_config, profile
end

---Gets the buffer number of the currently active Claude Code terminal.
---This checks both Snacks and native fallback terminals.
---@return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  return get_provider().get_active_bufnr()
end

---Gets the managed terminal instance for testing purposes.
-- NOTE: This function is intended for use in tests to inspect internal state.
-- The underscore prefix indicates it's not part of the public API for regular use.
---@return table|nil terminal The managed terminal instance, or nil.
function M._get_managed_terminal_for_test()
  local provider = get_provider()
  if provider and provider._get_terminal_for_test then
    return provider._get_terminal_for_test()
  end
  return nil
end

return M
