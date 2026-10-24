describe("claude_agents.terminal (wrapper for Snacks.nvim)", function()
  local terminal_wrapper
  local spy
  local mock_snacks_module
  local mock_snacks_terminal
  local mock_claudecode_config_module
  local mock_snacks_provider
  local mock_native_provider
  local last_created_mock_term_instance
  local create_mock_terminal_instance
  local saved_main_config

  create_mock_terminal_instance = function(cmd, opts)
    --- Internal deepcopy for the mock's own use.
    --- Avoids recursion with spied vim.deepcopy.
    local function internal_deepcopy(tbl)
      if type(tbl) ~= "table" then
        return tbl
      end
      local status, plenary_tablex = pcall(require, "plenary.tablex")
      if status and plenary_tablex and plenary_tablex.deepcopy then
        return plenary_tablex.deepcopy(tbl)
      end
      local lookup_table = {}
      local function _copy(object)
        if type(object) ~= "table" then
          return object
        elseif lookup_table[object] then
          return lookup_table[object]
        end
        local new_table = {}
        lookup_table[object] = new_table
        for index, value in pairs(object) do
          new_table[_copy(index)] = _copy(value)
        end
        return setmetatable(new_table, getmetatable(object))
      end
      return _copy(tbl)
    end

    local instance = {
      winid = 1000 + math.random(100),
      buf = 2000 + math.random(100),
      _is_valid = true,
      _cmd_received = cmd,
      _opts_received = internal_deepcopy(opts),
      _on_close_callback = nil,

      valid = spy.new(function(self)
        return self._is_valid
      end),
      focus = spy.new(function(self) end),
      close = spy.new(function(self)
        if self._is_valid and self._on_close_callback then
          self._on_close_callback({ winid = self.winid })
        end
        self._is_valid = false
      end),
    }
    instance.win = instance.winid
    if opts and opts.win and opts.win.on_close then
      instance._on_close_callback = opts.win.on_close
    end
    last_created_mock_term_instance = instance
    return instance
  end

  before_each(function()
    _G.vim = require("tests.mocks.vim")

    local spy_instance_methods = {}
    local spy_instance_mt = { __index = spy_instance_methods }

    local function internal_deepcopy_for_spy_calls(tbl)
      if type(tbl) ~= "table" then
        return tbl
      end
      local status_plenary, plenary_tablex_local = pcall(require, "plenary.tablex")
      if status_plenary and plenary_tablex_local and plenary_tablex_local.deepcopy then
        return plenary_tablex_local.deepcopy(tbl)
      end
      local lookup_table_local = {}
      local function _copy_local(object)
        if type(object) ~= "table" then
          return object
        elseif lookup_table_local[object] then
          return lookup_table_local[object]
        end
        local new_table_local = {}
        lookup_table_local[object] = new_table_local
        for index, value in pairs(object) do
          new_table_local[_copy_local(index)] = _copy_local(value)
        end
        return setmetatable(new_table_local, getmetatable(object))
      end
      return _copy_local(tbl)
    end

    spy_instance_mt.__call = function(self, ...)
      table.insert(self.calls, { refs = internal_deepcopy_for_spy_calls({ ... }) })
      if self.fake_fn then
        return self.fake_fn(unpack({ ... }))
      end
    end

    function spy_instance_methods:reset()
      self.calls = {}
    end

    function spy_instance_methods:clear()
      self:reset()
    end

    function spy_instance_methods:was_called(count)
      local actual_count = #self.calls
      if count then
        assert(
          actual_count == count,
          string.format("Expected spy to be called %d time(s), but was called %d time(s).", count, actual_count)
        )
      else
        assert(actual_count > 0, "Expected spy to be called at least once, but was not called.")
      end
    end

    function spy_instance_methods:was_not_called()
      assert(#self.calls == 0, string.format("Expected spy not to be called, but was called %d time(s).", #self.calls))
    end

    function spy_instance_methods:was_called_with(...)
      local expected_args = { ... }
      local found_match = false
      local calls_repr = ""
      for i, call_info in ipairs(self.calls) do
        calls_repr = calls_repr .. "\n  Call " .. i .. ": {"
        for j, arg_ref in ipairs(call_info.refs) do
          calls_repr = calls_repr .. tostring(arg_ref) .. (j < #call_info.refs and ", " or "")
        end
        calls_repr = calls_repr .. "}"
      end

      if #self.calls == 0 and #expected_args == 0 then
        found_match = true
      elseif #self.calls > 0 then
        for _, call_info in ipairs(self.calls) do
          local actual_args = call_info.refs
          if #actual_args == #expected_args then
            local current_match = true
            for i = 1, #expected_args do
              if
                type(expected_args[i]) == "table"
                and getmetatable(expected_args[i])
                and getmetatable(expected_args[i]).__is_matcher
              then
                if not expected_args[i](actual_args[i]) then
                  current_match = false
                  break
                end
              elseif actual_args[i] ~= expected_args[i] then
                current_match = false
                break
              end
            end
            if current_match then
              found_match = true
              break
            end
          end
        end
      end
      local expected_repr = ""
      for i, arg in ipairs(expected_args) do
        expected_repr = expected_repr .. tostring(arg) .. (i < #expected_args and ", " or "")
      end
      assert(
        found_match,
        "Spy was not called with the expected arguments.\nExpected: {"
          .. expected_repr
          .. "}\nActual Calls:"
          .. calls_repr
      )
    end

    function spy_instance_methods:get_call(index)
      return self.calls[index]
    end

    spy = {
      new = function(fake_fn)
        local s = { calls = {}, fake_fn = fake_fn }
        setmetatable(s, spy_instance_mt)
        return s
      end,
      on = function(tbl, key)
        local original_fn = tbl[key]
        local spy_obj = spy.new(original_fn)
        tbl[key] = spy_obj
        return spy_obj
      end,
      restore = function() end,
      matching = {
        is_type = function(expected_type)
          local matcher_table = { __is_matcher = true }
          matcher_table.__call = function(self, val)
            return type(val) == expected_type
          end
          setmetatable(matcher_table, matcher_table)
          return matcher_table
        end,
        string = {
          match = function(pattern)
            local matcher_table = { __is_matcher = true }
            matcher_table.__call = function(self, actual_str)
              if type(actual_str) ~= "string" then
                return false
              end
              return actual_str:match(pattern) ~= nil
            end
            setmetatable(matcher_table, matcher_table)
            return matcher_table
          end,
        },
      },
    }

    package.loaded["claude_agents.terminal"] = nil
    package.loaded["claude_agents.terminal.snacks"] = nil
    package.loaded["claude_agents.terminal.native"] = nil
    package.loaded["claude_agents.server.init"] = nil
    package.loaded["snacks"] = nil
    package.loaded["claude_agents.config"] = nil
    package.loaded["claude_agents.logger"] = nil

    -- Mock logger
    package.loaded["claude_agents.logger"] = {
      debug = function() end,
      warn = function(context, message)
        vim.notify(message, vim.log.levels.WARN)
      end,
      error = function(context, message)
        vim.notify(message, vim.log.levels.ERROR)
      end,
    }

    -- Mock the server module
    local mock_server_module = {
      state = { port = 12345 },
    }
    package.loaded["claude_agents.server.init"] = mock_server_module

    mock_claudecode_config_module = {
      apply = spy.new(function(user_conf)
        local base_config = { terminal_cmd = "claude" }
        if user_conf and user_conf.terminal_cmd then
          base_config.terminal_cmd = user_conf.terminal_cmd
        end
        return base_config
      end),
    }
    package.loaded["claude_agents.config"] = mock_claudecode_config_module

    -- Mock the provider modules
    mock_snacks_provider = {
      setup = spy.new(function() end),
      open = spy.new(create_mock_terminal_instance),
      close = spy.new(function() end),
      toggle = spy.new(function(cmd, env_table, config, opts_override)
        return create_mock_terminal_instance(cmd, { env = env_table })
      end),
      simple_toggle = spy.new(function(cmd, env_table, config, opts_override)
        return create_mock_terminal_instance(cmd, { env = env_table })
      end),
      focus_toggle = spy.new(function(cmd, env_table, config, opts_override)
        return create_mock_terminal_instance(cmd, { env = env_table })
      end),
      get_active_bufnr = spy.new(function()
        return nil
      end),
      is_available = spy.new(function()
        return true
      end),
      _get_terminal_for_test = spy.new(function()
        return last_created_mock_term_instance
      end),
    }
    package.loaded["claude_agents.terminal.snacks"] = mock_snacks_provider

    mock_native_provider = {
      setup = spy.new(function() end),
      open = spy.new(function() end),
      close = spy.new(function() end),
      toggle = spy.new(function() end),
      simple_toggle = spy.new(function() end),
      focus_toggle = spy.new(function() end),
      get_active_bufnr = spy.new(function()
        return nil
      end),
      is_available = spy.new(function()
        return true
      end),
    }
    package.loaded["claude_agents.terminal.native"] = mock_native_provider

    mock_snacks_terminal = {
      open = spy.new(create_mock_terminal_instance),
      toggle = spy.new(function(cmd, opts)
        local existing_term = terminal_wrapper
          and terminal_wrapper._get_managed_terminal_for_test
          and terminal_wrapper._get_managed_terminal_for_test()
        if existing_term and existing_term._cmd_received == cmd then
          if existing_term._on_close_callback then
            existing_term._on_close_callback({ winid = existing_term.winid })
          end
          return nil
        end
        return create_mock_terminal_instance(cmd, opts)
      end),
    }
    mock_snacks_module = { terminal = mock_snacks_terminal }
    package.loaded["snacks"] = mock_snacks_module

    vim.g.claudecode_user_config = {}

    local original_mock_vim_deepcopy = _G.vim.deepcopy
    _G.vim.deepcopy = spy.new(function(tbl)
      if original_mock_vim_deepcopy then
        return original_mock_vim_deepcopy(tbl)
      else
        if type(tbl) ~= "table" then
          return tbl
        end
        local status_plenary, plenary_tablex_local = pcall(require, "plenary.tablex")
        if status_plenary and plenary_tablex_local and plenary_tablex_local.deepcopy then
          return plenary_tablex_local.deepcopy(tbl)
        end
        local lookup_table_local = {}
        local function _copy_local(object)
          if type(object) ~= "table" then
            return object
          elseif lookup_table_local[object] then
            return lookup_table_local[object]
          end
          local new_table_local = {}
          lookup_table_local[object] = new_table_local
          for index, value in pairs(object) do
            new_table_local[_copy_local(index)] = _copy_local(value)
          end
          return setmetatable(new_table_local, getmetatable(object))
        end
        return _copy_local(tbl)
      end
    end)
    vim.api.nvim_buf_get_option = spy.new(function(_bufnr, opt_name)
      if opt_name == "buftype" then
        return "terminal"
      end
      return nil
    end)
    vim.api.nvim_win_call = spy.new(function(_winid, func)
      func()
    end)
    vim.cmd = spy.new(function(_cmd_str) end)
    vim.notify = spy.new(function(_msg, _level) end)

    terminal_wrapper = require("claude_agents.terminal")
    -- Don't call setup({}) here to allow custom provider tests to work

    -- These specs are about how a command is composed. `bash_changes` adds a
    -- `--settings` of its own to every launch; it has specs of its own below.
    local main = require("claude_agents")
    saved_main_config = main.state.config
    main.state.config = { bash_changes = false }
  end)

  after_each(function()
    require("claude_agents").state.config = saved_main_config
    package.loaded["claude_agents.terminal"] = nil
    package.loaded["claude_agents.terminal.snacks"] = nil
    package.loaded["claude_agents.terminal.native"] = nil
    package.loaded["claude_agents.server.init"] = nil
    package.loaded["snacks"] = nil
    package.loaded["claude_agents.config"] = nil
    package.loaded["claude_agents.logger"] = nil
    if _G.vim and _G.vim._mock and _G.vim._mock.reset then
      _G.vim._mock.reset()
    end
    _G.vim = nil
    last_created_mock_term_instance = nil
  end)

  describe("terminal.setup", function()
    it("should store valid split_side and split_width_percentage", function()
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 0.5 })
      terminal_wrapper.open()
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("left", config_arg.split_side)
      assert.are.equal(0.5, config_arg.split_width_percentage)
    end)
    it("should ignore invalid split_side and use default", function()
      terminal_wrapper.setup({ split_side = "invalid_side", split_width_percentage = 0.5 })
      terminal_wrapper.open()
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("right", config_arg.split_side)
      assert.are.equal(0.5, config_arg.split_width_percentage)
      vim.notify:was_called_with(spy.matching.string.match("Invalid value for split_side"), vim.log.levels.WARN)
    end)

    it("should ignore invalid split_width_percentage and use default", function()
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 2.0 })
      terminal_wrapper.open()
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("left", config_arg.split_side)
      assert.are.equal(0.30, config_arg.split_width_percentage)
      vim.notify:was_called_with(
        spy.matching.string.match("Invalid value for split_width_percentage"),
        vim.log.levels.WARN
      )
    end)

    it("should ignore unknown keys", function()
      terminal_wrapper.setup({ unknown_key = "some_value", split_side = "left" })
      terminal_wrapper.open()
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("left", config_arg.split_side)
      vim.notify:was_called_with(
        spy.matching.string.match("Unknown configuration key: unknown_key"),
        vim.log.levels.WARN
      )
    end)

    it("should use defaults if user_term_config is not a table and notify", function()
      terminal_wrapper.setup("not_a_table")
      terminal_wrapper.open()
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("right", config_arg.split_side)
      assert.are.equal(0.30, config_arg.split_width_percentage)
      vim.notify:was_called_with(
        "claude_agents.terminal.setup expects a table or nil for user_term_config",
        vim.log.levels.WARN
      )
    end)
  end)

  describe("terminal.open", function()
    it(
      "should call Snacks.terminal.open with default 'claude' command if terminal_cmd is not set in main config",
      function()
        vim.g.claudecode_user_config = {}
        mock_claudecode_config_module.apply = spy.new(function()
          return { terminal_cmd = "claude" }
        end)
        package.loaded["claude_agents.config"] = mock_claudecode_config_module
        package.loaded["claude_agents.terminal"] = nil
        terminal_wrapper = require("claude_agents.terminal")
        terminal_wrapper.setup({})

        terminal_wrapper.open()

        mock_snacks_provider.open:was_called(1)
        local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
        local env_arg = mock_snacks_provider.open:get_call(1).refs[2]
        local config_arg = mock_snacks_provider.open:get_call(1).refs[3]

        assert.are.equal("claude", cmd_arg)
        assert.is_table(env_arg)
        assert.are.equal("true", env_arg.ENABLE_IDE_INTEGRATION)
        assert.is_table(config_arg)
        assert.are.equal("right", config_arg.split_side)
        assert.are.equal(0.30, config_arg.split_width_percentage)
      end
    )

    it("should call Snacks.terminal.open with terminal_cmd from main config", function()
      vim.g.claudecode_user_config = { terminal_cmd = "my_claude_cli" }
      mock_claudecode_config_module.apply = spy.new(function()
        return { terminal_cmd = "my_claude_cli" }
      end)
      package.loaded["claude_agents.config"] = mock_claudecode_config_module
      package.loaded["claude_agents.terminal"] = nil
      terminal_wrapper = require("claude_agents.terminal")
      terminal_wrapper.setup({}, "my_claude_cli")

      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("my_claude_cli", cmd_arg)
    end)

    it("should call provider open twice when terminal exists", function()
      terminal_wrapper.open()
      local first_instance = last_created_mock_term_instance
      assert.is_not_nil(first_instance)

      -- Provider manages its own state, so we expect open to be called again
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(2) -- Called twice: once to create, once for existing check
    end)

    it("should apply opts_override to snacks_opts when opening a new terminal", function()
      terminal_wrapper.open({ split_side = "left", split_width_percentage = 0.6 })
      mock_snacks_provider.open:was_called(1)
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]
      assert.are.equal("left", config_arg.split_side)
      assert.are.equal(0.6, config_arg.split_width_percentage)
    end)

    it("should call provider open and handle nil return gracefully", function()
      mock_snacks_provider.open = spy.new(function()
        -- Simulate provider handling its own failure notification
        vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
        return nil
      end)
      vim.notify:reset()
      terminal_wrapper.open()
      vim.notify:was_called_with("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
      mock_snacks_provider.open:reset()
      mock_snacks_provider.open = spy.new(function()
        vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
        return nil
      end)
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
    end)

    it("should call provider open and handle invalid instance gracefully", function()
      local invalid_instance = { valid = spy.new(function()
        return false
      end) }
      mock_snacks_provider.open = spy.new(function()
        -- Simulate provider handling its own failure notification
        vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
        return invalid_instance
      end)
      vim.notify:reset()
      terminal_wrapper.open()
      vim.notify:was_called_with("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
      mock_snacks_provider.open:reset()
      mock_snacks_provider.open = spy.new(function()
        vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
        return invalid_instance
      end)
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
    end)
  end)

  describe("terminal.close", function()
    it("should call managed_terminal:close() if valid terminal exists", function()
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)

      terminal_wrapper.close()
      mock_snacks_provider.close:was_called(1)
    end)

    it("should call provider close even if no managed terminal", function()
      terminal_wrapper.close()
      mock_snacks_provider.close:was_called(1)
      mock_snacks_provider.open:was_not_called()
    end)

    it("should not call close if managed terminal is invalid", function()
      terminal_wrapper.open()
      local current_managed_term = last_created_mock_term_instance
      assert.is_not_nil(current_managed_term)
      current_managed_term._is_valid = false

      current_managed_term.close:reset()
      terminal_wrapper.close()
      current_managed_term.close:was_not_called()
    end)
  end)

  describe("terminal.toggle", function()
    it("should call Snacks.terminal.toggle with correct command and options", function()
      vim.g.claudecode_user_config = { terminal_cmd = "toggle_claude" }
      mock_claudecode_config_module.apply = spy.new(function()
        return { terminal_cmd = "toggle_claude" }
      end)
      package.loaded["claude_agents.config"] = mock_claudecode_config_module
      package.loaded["claude_agents.terminal"] = nil
      terminal_wrapper = require("claude_agents.terminal")
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 0.4 }, "toggle_claude")

      terminal_wrapper.toggle({ split_width_percentage = 0.45 })

      mock_snacks_provider.simple_toggle:was_called(1)
      local cmd_arg = mock_snacks_provider.simple_toggle:get_call(1).refs[1]
      local config_arg = mock_snacks_provider.simple_toggle:get_call(1).refs[3]
      assert.are.equal("toggle_claude", cmd_arg)
      assert.are.equal("left", config_arg.split_side)
      assert.are.equal(0.45, config_arg.split_width_percentage)
    end)

    it("should call provider toggle and manage state", function()
      local mock_toggled_instance = create_mock_terminal_instance("toggled_cmd", {})
      mock_snacks_provider.simple_toggle = spy.new(function()
        return mock_toggled_instance
      end)

      terminal_wrapper.toggle({})
      mock_snacks_provider.simple_toggle:was_called(1)

      -- After toggle, subsequent open should work with provider state
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
    end)

    it("should set managed_snacks_terminal to nil if toggle returns nil", function()
      mock_snacks_terminal.toggle = spy.new(function()
        return nil
      end)
      terminal_wrapper.toggle({})
      mock_snacks_provider.open:reset()
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
    end)
  end)

  describe("provider callback handling", function()
    it("should handle terminal closure through provider", function()
      terminal_wrapper.open()
      local opened_instance = last_created_mock_term_instance
      assert.is_not_nil(opened_instance)

      -- Simulate terminal closure via provider's close method
      terminal_wrapper.close()
      mock_snacks_provider.close:was_called(1)
    end)

    it("should create new terminal after closure", function()
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)

      terminal_wrapper.close()
      mock_snacks_provider.close:was_called(1)

      mock_snacks_provider.open:reset()
      terminal_wrapper.open()
      mock_snacks_provider.open:was_called(1)
    end)
  end)

  describe("bash_changes", function()
    ---The text of the settings file a launch command points the CLI at.
    local function settings_text(cmd)
      local path = cmd:match("%-%-settings '([^']+)'")
      assert.is_string(path, "no --settings in " .. cmd)
      local f = assert(io.open(path, "r"))
      local text = f:read("*a")
      f:close()
      return text
    end

    it("asks the CLI to record what Bash commands change, by default", function()
      require("claude_agents").state.config = {}
      terminal_wrapper.open({}, "--resume")

      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.is_truthy(cmd_arg:find("^claude %-%-resume %-%-settings "))
      assert.is_truthy(settings_text(cmd_arg):find('"bashEditDiffEnabled":true', 1, true))
    end)

    it("adds nothing with bash_changes = false", function()
      require("claude_agents").state.config = { bash_changes = false }
      terminal_wrapper.open({}, "--resume")

      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("claude --resume", cmd_arg)
    end)
  end)

  describe("command arguments support", function()
    it("should append cmd_args to base command when provided to open", function()
      terminal_wrapper.open({}, "--resume")

      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("claude --resume", cmd_arg)
    end)

    it("should append cmd_args to base command when provided to toggle", function()
      terminal_wrapper.toggle({}, "--resume --verbose")

      mock_snacks_provider.simple_toggle:was_called(1)
      local cmd_arg = mock_snacks_provider.simple_toggle:get_call(1).refs[1]
      assert.are.equal("claude --resume --verbose", cmd_arg)
    end)

    it("should work with custom terminal_cmd and arguments", function()
      terminal_wrapper.setup({}, "my_claude_binary")
      terminal_wrapper.open({}, "--flag")

      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("my_claude_binary --flag", cmd_arg)
    end)

    it("should fallback gracefully when cmd_args is nil", function()
      terminal_wrapper.open({}, nil)

      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("claude", cmd_arg)
    end)

    it("should fallback gracefully when cmd_args is empty string", function()
      terminal_wrapper.toggle({}, "")

      mock_snacks_provider.simple_toggle:was_called(1)
      local cmd_arg = mock_snacks_provider.simple_toggle:get_call(1).refs[1]
      assert.are.equal("claude", cmd_arg)
    end)

    it("should work with both opts_override and cmd_args", function()
      terminal_wrapper.open({ split_side = "left" }, "--resume")

      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      local config_arg = mock_snacks_provider.open:get_call(1).refs[3]

      assert.are.equal("claude --resume", cmd_arg)
      assert.are.equal("left", config_arg.split_side)
    end)

    it("should handle special characters in arguments", function()
      terminal_wrapper.open({}, "--message='hello world'")

      mock_snacks_provider.open:was_called(1)
      local cmd_arg = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("claude --message='hello world'", cmd_arg)
    end)

    it("should maintain backward compatibility when no cmd_args provided", function()
      terminal_wrapper.open()

      mock_snacks_provider.open:was_called(1)
      local open_cmd = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.equal("claude", open_cmd)

      -- Close the existing terminal and reset spies to test toggle in isolation
      terminal_wrapper.close()
      mock_snacks_provider.open:reset()
      mock_snacks_terminal.toggle:reset()

      terminal_wrapper.toggle()

      mock_snacks_provider.simple_toggle:was_called(1)
      local toggle_cmd = mock_snacks_provider.simple_toggle:get_call(1).refs[1]
      assert.are.equal("claude", toggle_cmd)
    end)
  end)

  describe("custom table provider functionality", function()
    describe("valid custom provider", function()
      it("should call setup method during terminal wrapper setup", function()
        local setup_spy = spy.new(function() end)
        local custom_provider = {
          setup = setup_spy,
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return true
          end),
        }

        terminal_wrapper.setup({ provider = custom_provider })

        setup_spy:was_called(1)
        setup_spy:was_called_with(spy.matching.is_type("table"))
      end)

      it("should check is_available during open operation", function()
        local is_available_spy = spy.new(function()
          return true
        end)
        local open_spy = spy.new(function() end)
        local custom_provider = {
          setup = spy.new(function() end),
          open = open_spy,
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = is_available_spy,
        }

        terminal_wrapper.setup({ provider = custom_provider })
        terminal_wrapper.open()

        is_available_spy:was_called()
        open_spy:was_called()
      end)

      it("should auto-generate toggle function if missing", function()
        local simple_toggle_spy = spy.new(function() end)
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = simple_toggle_spy,
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return true
          end),
          -- Note: toggle function is intentionally missing
        }

        terminal_wrapper.setup({ provider = custom_provider })

        -- Verify that toggle function was auto-generated and calls simple_toggle
        assert.is_function(custom_provider.toggle)
        local test_env = {}
        local test_config = {}
        custom_provider.toggle("test_cmd", test_env, test_config)
        simple_toggle_spy:was_called(1)
        -- Check that the first argument (command string) is correct
        local call_args = simple_toggle_spy:get_call(1).refs
        assert.are.equal("test_cmd", call_args[1])
        assert.are.equal(3, #call_args) -- Should have 3 arguments
      end)

      it("should auto-generate _get_terminal_for_test function if missing", function()
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return true
          end),
          -- Note: _get_terminal_for_test function is intentionally missing
        }

        terminal_wrapper.setup({ provider = custom_provider })

        -- Verify that _get_terminal_for_test function was auto-generated
        assert.is_function(custom_provider._get_terminal_for_test)
        assert.is_nil(custom_provider._get_terminal_for_test())
      end)

      it("should pass correct parameters to custom provider functions", function()
        local open_spy = spy.new(function() end)
        local simple_toggle_spy = spy.new(function() end)
        local focus_toggle_spy = spy.new(function() end)

        local custom_provider = {
          setup = spy.new(function() end),
          open = open_spy,
          close = spy.new(function() end),
          simple_toggle = simple_toggle_spy,
          focus_toggle = focus_toggle_spy,
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return true
          end),
        }

        terminal_wrapper.setup({ provider = custom_provider })

        -- Test open with parameters
        terminal_wrapper.open({ split_side = "left" }, "test_args")
        open_spy:was_called()
        local open_call = open_spy:get_call(1)
        assert.is_string(open_call.refs[1]) -- cmd_string
        assert.is_table(open_call.refs[2]) -- env_table
        assert.is_table(open_call.refs[3]) -- effective_config

        -- Test simple_toggle with parameters
        terminal_wrapper.simple_toggle({ split_width_percentage = 0.4 }, "toggle_args")
        simple_toggle_spy:was_called()
        local toggle_call = simple_toggle_spy:get_call(1)
        assert.is_string(toggle_call.refs[1]) -- cmd_string
        assert.is_table(toggle_call.refs[2]) -- env_table
        assert.is_table(toggle_call.refs[3]) -- effective_config
      end)
    end)

    describe("fallback behavior", function()
      it("should fallback to native provider when is_available returns false", function()
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return false
          end), -- Returns false
        }

        terminal_wrapper.setup({ provider = custom_provider })
        terminal_wrapper.open()

        -- Should use native provider instead
        mock_native_provider.open:was_called()
        custom_provider.open:was_not_called()
      end)

      it("should fallback to native provider when is_available throws error", function()
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            error("Availability check failed")
          end),
        }

        terminal_wrapper.setup({ provider = custom_provider })
        terminal_wrapper.open()

        -- Should use native provider instead
        mock_native_provider.open:was_called()
        custom_provider.open:was_not_called()
      end)
    end)

    describe("invalid provider rejection", function()
      it("should reject non-table providers", function()
        -- Make snacks provider unavailable to force fallback to native
        mock_snacks_provider.is_available = spy.new(function()
          return false
        end)
        mock_native_provider.open:reset() -- Reset the spy before the test

        terminal_wrapper.setup({ provider = "invalid_string" })

        -- Check that vim.notify was called with the expected warning about invalid value
        local notify_calls = vim.notify.calls
        local found_warning = false
        for _, call in ipairs(notify_calls) do
          local message = call.refs[1]
          if message and message:match("Invalid value for provider.*invalid_string") then
            found_warning = true
            break
          end
        end
        assert.is_true(found_warning, "Expected warning about invalid provider value")

        terminal_wrapper.open()

        -- Should fallback to native provider (since snacks is unavailable and invalid string was rejected)
        mock_native_provider.open:was_called()
      end)

      it("should reject providers missing required functions", function()
        local incomplete_provider = {
          setup = function() end,
          open = function() end,
          -- Missing other required functions
        }

        terminal_wrapper.setup({ provider = incomplete_provider })
        terminal_wrapper.open()

        -- Should fallback to native provider
        mock_native_provider.open:was_called()
      end)

      it("should reject providers with non-function required fields", function()
        local invalid_provider = {
          setup = function() end,
          open = "not_a_function", -- Invalid type
          close = function() end,
          simple_toggle = function() end,
          focus_toggle = function() end,
          get_active_bufnr = function()
            return 123
          end,
          is_available = function()
            return true
          end,
        }

        terminal_wrapper.setup({ provider = invalid_provider })
        terminal_wrapper.open()

        -- Should fallback to native provider
        mock_native_provider.open:was_called()
      end)
    end)

    describe("wrapper function invocations", function()
      it("should properly invoke all wrapper functions with custom provider", function()
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = spy.new(function() end),
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 456
          end),
          is_available = spy.new(function()
            return true
          end),
        }

        terminal_wrapper.setup({ provider = custom_provider })

        -- Test all wrapper functions
        terminal_wrapper.open()
        custom_provider.open:was_called()

        terminal_wrapper.close()
        custom_provider.close:was_called()

        terminal_wrapper.simple_toggle()
        custom_provider.simple_toggle:was_called()

        terminal_wrapper.focus_toggle()
        custom_provider.focus_toggle:was_called()

        local bufnr = terminal_wrapper.get_active_terminal_bufnr()
        custom_provider.get_active_bufnr:was_called()
        assert.are.equal(456, bufnr)
      end)

      it("should handle toggle function (legacy) correctly", function()
        local simple_toggle_spy = spy.new(function() end)
        local custom_provider = {
          setup = spy.new(function() end),
          open = spy.new(function() end),
          close = spy.new(function() end),
          simple_toggle = simple_toggle_spy,
          focus_toggle = spy.new(function() end),
          get_active_bufnr = spy.new(function()
            return 123
          end),
          is_available = spy.new(function()
            return true
          end),
        }

        terminal_wrapper.setup({ provider = custom_provider })

        -- Legacy toggle should call simple_toggle
        terminal_wrapper.toggle()
        simple_toggle_spy:was_called()
      end)
    end)
  end)

  describe("custom provider validation", function()
    it("should reject provider missing required functions", function()
      local invalid_provider = { setup = function() end } -- missing other functions
      terminal_wrapper.setup({ provider = invalid_provider })
      terminal_wrapper.open()

      -- Verify fallback to native provider
      mock_native_provider.open:was_called()
      -- Check that the warning was logged (vim.notify gets called with logger output)
      local notify_calls = vim.notify.calls
      local found_warning = false
      for _, call in ipairs(notify_calls) do
        local message = call.refs[1]
        if message and message:match("Invalid custom table provider.*missing required function") then
          found_warning = true
          break
        end
      end
      assert.is_true(found_warning, "Expected warning about missing required function")
    end)

    it("should handle provider availability check failures", function()
      local provider_with_error = {
        setup = function() end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return 123
        end,
        is_available = function()
          error("test error")
        end,
      }

      vim.notify:reset()
      terminal_wrapper.setup({ provider = provider_with_error })
      terminal_wrapper.open()

      -- Verify graceful fallback to native provider
      mock_native_provider.open:was_called()

      -- Check that the warning was logged about availability error
      local notify_calls = vim.notify.calls
      local found_warning = false
      for _, call in ipairs(notify_calls) do
        local message = call.refs[1]
        if message and message:match("error checking availability") then
          found_warning = true
          break
        end
      end
      assert.is_true(found_warning, "Expected warning about availability check error")
    end)

    it("should validate provider function types", function()
      local invalid_provider = {
        setup = function() end,
        open = "not_a_function", -- Wrong type
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return 123
        end,
        is_available = function()
          return true
        end,
      }

      vim.notify:reset()
      terminal_wrapper.setup({ provider = invalid_provider })
      terminal_wrapper.open()

      -- Should fallback to native provider
      mock_native_provider.open:was_called()

      -- Check for function type validation error
      local notify_calls = vim.notify.calls
      local found_error = false
      for _, call in ipairs(notify_calls) do
        local message = call.refs[1]
        if message and message:match("must be callable.*got.*string") then
          found_error = true
          break
        end
      end
      assert.is_true(found_error, "Expected error about function type validation")
    end)

    it("should verify fallback on availability check failure", function()
      local provider_unavailable = {
        setup = function() end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return 123
        end,
        is_available = function()
          return false
        end, -- Provider says it's not available
      }

      vim.notify:reset()
      terminal_wrapper.setup({ provider = provider_unavailable })
      terminal_wrapper.open()

      -- Should use native provider
      mock_native_provider.open:was_called()

      -- Check for availability warning
      local notify_calls = vim.notify.calls
      local found_warning = false
      for _, call in ipairs(notify_calls) do
        local message = call.refs[1]
        if message and message:match("provider reports not available") then
          found_warning = true
          break
        end
      end
      assert.is_true(found_warning, "Expected warning about provider not available")
    end)

    it("should test auto-generated optional functions with working provider", function()
      local simple_toggle_called = false
      local provider_minimal = {
        setup = function() end,
        open = function() end,
        close = function() end,
        simple_toggle = function()
          simple_toggle_called = true
        end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return 123
        end,
        is_available = function()
          return true
        end,
        -- Missing toggle and _get_terminal_for_test functions
      }

      terminal_wrapper.setup({ provider = provider_minimal })

      -- Test auto-generated toggle function
      assert.is_function(provider_minimal.toggle)
      provider_minimal.toggle("test_cmd", { TEST = "env" }, { split_side = "left" })
      assert.is_true(simple_toggle_called)

      -- Test auto-generated _get_terminal_for_test function
      assert.is_function(provider_minimal._get_terminal_for_test)
      assert.is_nil(provider_minimal._get_terminal_for_test())
    end)

    it("should handle edge case where provider returns nil for required function", function()
      local provider_with_nil_function = {
        setup = function() end,
        open = function() end,
        close = nil, -- Explicitly nil instead of missing
        simple_toggle = function() end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return 123
        end,
        is_available = function()
          return true
        end,
      }

      vim.notify:reset()
      terminal_wrapper.setup({ provider = provider_with_nil_function })
      terminal_wrapper.open()

      -- Should fallback to native provider
      mock_native_provider.open:was_called()

      -- Check for missing function error
      local notify_calls = vim.notify.calls
      local found_error = false
      for _, call in ipairs(notify_calls) do
        local message = call.refs[1]
        if message and message:match("missing required function.*close") then
          found_error = true
          break
        end
      end
      assert.is_true(found_error, "Expected error about missing close function")
    end)
  end)

  describe("launch profiles and the one --settings", function()
    require("tests.busted_setup") -- for _G.json_decode
    local merged
    local files

    ---The value every `--settings` in a launched command carries.
    local function settings_flags(cmd)
      local utils = require("claude_agents.utils")
      local _, sources = require("claude_agents.launch_settings").extract(utils.shell_split(cmd))
      return sources
    end

    local real_decode

    before_each(function()
      merged, files = {}, {}
      real_decode = vim.json.decode
      vim.json.decode = _G.json_decode
      package.loaded["claude_agents.live_cursor"] = {
        build_launch_hooks = function()
          return {
            settings = { hooks = { SessionStart = { { hooks = { { type = "command", command = "plugin-hook" } } } } } },
            env = { CLAUDECODE_NVIM_SERVER = "/tmp/nvim.sock" },
          }
        end,
        write_settings_file = function(settings)
          merged[#merged + 1] = settings
          return "/tmp/merged-" .. #merged .. ".json"
        end,
      }
      package.loaded["claude_agents.launch_settings"] = nil
      package.loaded["claude_agents.profiles"] = nil
      local profiles = require("claude_agents.profiles")
      profiles._io = {
        read = function(path)
          return files[path]
        end,
        write = function(path, data)
          files[path] = data
          return true
        end,
        stat = function(path)
          return files[path] and tostring(#files[path]) or nil
        end,
      }
      profiles.setup({})
    end)

    after_each(function()
      vim.json.decode = real_decode
      package.loaded["claude_agents.live_cursor"] = nil
      package.loaded["claude_agents.launch_settings"] = nil
      package.loaded["claude_agents.profiles"] = nil
    end)

    it("keeps the user's own --settings, merged with the plugin's hooks into one flag", function()
      -- The CLI reads one --settings: the plugin's flag used to replace the
      -- user's on every launch the hooks were injected into.
      terminal_wrapper.setup({}, [[claude --settings '{"model":"sonnet"}']])
      terminal_wrapper.open()
      local cmd = mock_snacks_provider.open:get_call(1).refs[1]
      assert.are.same({ "/tmp/merged-1.json" }, settings_flags(cmd))
      assert.are.equal("sonnet", merged[1].model)
      assert.are.equal("plugin-hook", merged[1].hooks.SessionStart[1].hooks[1].command)
      assert.are.equal("/tmp/nvim.sock", mock_snacks_provider.open:get_call(1).refs[2].CLAUDECODE_NVIM_SERVER)
    end)

    it("runs a launch under the profile it is given", function()
      terminal_wrapper.open({}, nil, { profile = "subscription" })
      local env = mock_snacks_provider.open:get_call(1).refs[2]
      assert.are.equal("", env.ANTHROPIC_API_KEY)
      assert.are.equal("", env.ANTHROPIC_AUTH_TOKEN)
      assert.are.equal("", merged[1].apiKeyHelper)
      assert.are.equal("plugin-hook", merged[1].hooks.SessionStart[1].hooks[1].command)
    end)

    it("hands an API launch the keychain helper", function()
      terminal_wrapper.open({}, nil, { profile = "API key" })
      local helper = merged[1].apiKeyHelper
      assert.is_truthy(helper:find("api_key.lua", 1, true))
      assert.is_truthy(helper:find(" get default", 1, true))
    end)

    it("resumes a conversation under the profile it last ran under", function()
      local id = "0f9a1c3e-1111-4222-8333-444455556666"
      require("claude_agents.profiles").remember(id, "API key")
      terminal_wrapper.open({}, "--resume " .. id)
      assert.is_truthy(merged[1].apiKeyHelper:find("api_key.lua", 1, true))
    end)

    it("touches nothing for a plain launch with no default profile", function()
      terminal_wrapper.open()
      local env = mock_snacks_provider.open:get_call(1).refs[2]
      assert.is_nil(env.ANTHROPIC_API_KEY)
      assert.is_nil(merged[1].apiKeyHelper)
    end)

    it("stamps a terminal a toggle started, as open always did", function()
      -- `:ClaudeCode` is a toggle, and only `open` used to stamp: closing such a
      -- Claude never forgot its conversation.
      local buf = vim.api.nvim_create_buf(false, true)
      local started = false
      mock_snacks_provider.get_active_bufnr = spy.new(function()
        return started and buf or nil
      end)
      mock_snacks_provider.simple_toggle = spy.new(function()
        started = true
      end)
      terminal_wrapper.setup({})
      terminal_wrapper.simple_toggle({}, nil)
      assert.are.equal(vim.api.nvim_get_current_tabpage(), vim.b[buf].claudecode_tab)

      -- Hiding and showing the same terminal stamps nothing more.
      vim.b[buf].claudecode_tab = nil
      terminal_wrapper.simple_toggle({}, nil)
      assert.is_nil(vim.b[buf].claudecode_tab)
    end)

    describe("restarting under another profile", function()
      local autocmds, deferred, stopped, killed
      -- The vim mock is one table for the whole run: put back what is replaced.
      local saved

      after_each(function()
        vim.api.nvim_create_autocmd = saved.create_autocmd
        vim.defer_fn, vim.schedule = saved.defer_fn, saved.schedule
        vim.fn.jobwait, vim.fn.jobpid, vim.fn.jobstop = saved.jobwait, saved.jobpid, saved.jobstop
        vim.uv, vim.loop.kill = saved.uv, saved.kill
      end)

      before_each(function()
        saved = {
          create_autocmd = vim.api.nvim_create_autocmd,
          defer_fn = vim.defer_fn,
          schedule = vim.schedule,
          jobwait = vim.fn.jobwait,
          jobpid = vim.fn.jobpid,
          jobstop = vim.fn.jobstop,
          uv = vim.uv,
          kill = vim.loop.kill,
        }
        autocmds, deferred, stopped, killed = {}, {}, nil, nil
        vim.api.nvim_create_autocmd = function(event, opts)
          autocmds[#autocmds + 1] = { event = event, opts = opts }
          return #autocmds
        end
        vim.defer_fn = function(fn, ms)
          deferred[#deferred + 1] = { fn = fn, ms = ms }
        end
        vim.schedule = function(fn)
          fn()
        end
        vim.fn.jobwait = function()
          return { -1 } -- still running
        end
        vim.fn.jobpid = function()
          return 4242
        end
        vim.fn.jobstop = function(job)
          stopped = job
        end
        vim.uv = nil
        vim.loop.kill = function(pid, signal)
          killed = { pid, signal }
        end
      end)

      local function terminal_buffer()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.b[buf].terminal_job_id = 7
        return buf
      end

      it("waits for the old CLI to exit before going on", function()
        -- Two CLIs on one conversation interleave their transcript writes.
        local done = 0
        terminal_wrapper._stop_and_wait(terminal_buffer(), function()
          done = done + 1
        end)
        assert.are.equal(7, stopped)
        assert.are.equal(0, done)
        assert.are.equal("TermClose", autocmds[1].event)
        autocmds[1].opts.callback()
        assert.are.equal(1, done)
        -- The grace timer going off afterwards changes nothing.
        deferred[1].fn()
        assert.are.equal(1, done)
        assert.is_nil(killed)
      end)

      it("kills a CLI that will not exit, then goes on", function()
        local done = 0
        terminal_wrapper._stop_and_wait(terminal_buffer(), function()
          done = done + 1
        end)
        deferred[1].fn() -- the grace period runs out
        assert.are.same({ 4242, "sigkill" }, killed)
        assert.are.equal(0, done)
        deferred[2].fn()
        assert.are.equal(1, done)
      end)

      it("goes straight on when the process has already exited", function()
        vim.fn.jobwait = function()
          return { 0 }
        end
        local done = 0
        terminal_wrapper._stop_and_wait(terminal_buffer(), function()
          done = done + 1
        end)
        assert.are.equal(1, done)
        assert.is_nil(stopped)
      end)

      it("resumes the tab's conversation under the new profile, and is not taken for a close", function()
        local buf = terminal_buffer()
        local tab = vim.api.nvim_get_current_tabpage()
        mock_snacks_provider.get_active_bufnr = spy.new(function()
          return vim.api.nvim_buf_is_valid(buf) and buf or nil
        end)
        terminal_wrapper.setup({})
        local restarting_while_stopping
        terminal_wrapper._stop_and_wait = function(_, done)
          restarting_while_stopping = terminal_wrapper.is_restarting(tab)
          done()
        end
        terminal_wrapper.restart("API key", "0f9a1c3e-1111-4222-8333-444455556666")
        assert.is_true(restarting_while_stopping)
        assert.is_false(terminal_wrapper.is_restarting(tab))
        local cmd = mock_snacks_provider.open:get_call(1).refs[1]
        assert.is_truthy(cmd:find("--resume 0f9a1c3e-1111-4222-8333-444455556666", 1, true))
        assert.is_truthy(merged[1].apiKeyHelper:find("api_key.lua", 1, true))
      end)
    end)

    it("acts on the selected agent when typed in the agents view's tab", function()
      -- That tab has no Claude of its own; opening one there would split the view.
      local asked = {}
      package.loaded["claude_agents.agents_view"] = {
        is_view_tab = function()
          return true
        end,
        resume_selected_as = function(name)
          asked[#asked + 1] = "resume " .. name
        end,
        resume_as_menu = function()
          asked[#asked + 1] = "menu"
        end,
      }
      terminal_wrapper.setup({})
      terminal_wrapper.launch_profile("API key")
      terminal_wrapper.choose_profile()
      package.loaded["claude_agents.agents_view"] = nil
      assert.are.same({ "resume API key", "menu" }, asked)
      mock_snacks_provider.open:was_called(0)
    end)

    it("makes the profile of a started terminal the tab's", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local started = false
      mock_snacks_provider.get_active_bufnr = spy.new(function()
        return started and buf or nil
      end)
      mock_snacks_provider.open = spy.new(function()
        started = true
      end)
      terminal_wrapper.setup({})
      terminal_wrapper.open({}, nil, { profile = "API key" })
      assert.are.equal("API key", require("claude_agents.profiles").of_tab())
    end)
  end)
end)
