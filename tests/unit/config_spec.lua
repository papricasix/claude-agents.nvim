-- luacheck: globals expect
require("tests.busted_setup")

describe("Configuration", function()
  local config

  local function setup()
    package.loaded["claude_agents.config"] = nil
    package.loaded["claude_agents.terminal"] = nil

    config = require("claude_agents.config")
  end

  local function teardown()
    -- Nothing to clean up for now
  end

  setup()

  it("should have default configuration", function()
    expect(config.defaults).to_be_table()
    expect(config.defaults).to_have_key("port_range")
    expect(config.defaults).to_have_key("auto_start")
    expect(config.defaults).to_have_key("log_level")
    expect(config.defaults).to_have_key("track_selection")
    expect(config.defaults).to_have_key("models")
    expect(config.defaults).to_have_key("diff_opts")
    expect(config.defaults.diff_opts).to_have_key("keep_terminal_focus")
    expect(config.defaults.diff_opts.keep_terminal_focus).to_be_false()
  end)

  it("should apply and validate user configuration", function()
    local user_config = {
      terminal_cmd = "toggleterm",
      log_level = "debug",
      track_selection = false,
      models = {
        { name = "Test Model", value = "test-model" },
      },
    }

    local final_config = config.apply(user_config)
    expect(final_config).to_be_table()
    expect(final_config.terminal_cmd).to_be("toggleterm")
    expect(final_config.log_level).to_be("debug")
    expect(final_config.track_selection).to_be_false()
    expect(final_config.env).to_be_table() -- Should inherit default empty table
  end)

  it("should reject invalid port range", function()
    local invalid_config = {
      port_range = { min = -1, max = 65536 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
    }

    local success, _ = pcall(function() -- Use _ for unused error variable
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("offers open_files in a new tab by default, and checks what is set", function()
    expect(config.defaults.open_files.enabled).to_be_true()
    expect(config.defaults.open_files.layout).to_be("tab")
    expect(config.defaults.open_files.focus).to_be_true()
    expect(config.apply({ open_files = { layout = "float" } }).open_files.layout).to_be("float")

    local function rejects(open_files)
      local ok = pcall(config.apply, { open_files = open_files })
      return not ok
    end
    expect(rejects({ layout = "diagonal" })).to_be_true()
    expect(rejects({ focus = "yes" })).to_be_true()
    expect(rejects({ server_name = "has space" })).to_be_true()
    expect(rejects({ layout = "vsplit", server_name = "editor-1" })).to_be_false()
  end)

  it("shows notes by default, marks their lines with a bar, and checks what is set", function()
    local notes = config.defaults.open_files.notes
    expect(notes.enabled).to_be_true()
    expect(notes.range_mark).to_be("bar")
    expect(notes.max_lines).to_be(8)
    expect(notes.keymaps.next).to_be("]n")
    local applied = config.apply({ open_files = { notes = { range_mark = false, keymaps = { prev = false } } } })
    expect(applied.open_files.notes.range_mark).to_be_false()
    expect(applied.open_files.notes.keymaps.next).to_be("]n")
    expect(applied.open_files.layout).to_be("tab")

    local function rejects(notes_opts)
      return not pcall(config.apply, { open_files = { notes = notes_opts } })
    end
    expect(rejects("on")).to_be_true()
    expect(rejects({ range_mark = "underline" })).to_be_true()
    expect(rejects({ max_lines = 0 })).to_be_true()
    expect(rejects({ max_width = 2.5 })).to_be_true()
    expect(rejects({ keymaps = "]n" })).to_be_true()
    expect(rejects({ keymaps = { next = "" } })).to_be_true()
    expect(rejects({ range_mark = "number", max_lines = 3, keymaps = false })).to_be_false()
  end)

  it("should reject invalid log level", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "invalid_level",
      track_selection = false,
    }

    local success, _ = pcall(function() -- Use _ for unused error variable
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should reject invalid models configuration", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
      visual_demotion_delay_ms = 50,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      models = {}, -- Empty models array should be rejected
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should reject models with invalid structure", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
      visual_demotion_delay_ms = 50,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      models = {
        { name = "Test Model" }, -- Missing value field
      },
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should merge user config with defaults", function()
    local user_config = {
      auto_start = true,
      log_level = "debug",
    }

    local merged_config = config.apply(user_config)

    expect(merged_config.auto_start).to_be_true()
    expect(merged_config.log_level).to_be("debug")
    expect(merged_config.port_range.min).to_be(config.defaults.port_range.min)
    expect(merged_config.track_selection).to_be(config.defaults.track_selection)
    expect(merged_config.models).to_be_table()
  end)

  it("should accept valid keep_terminal_focus configuration", function()
    local user_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
    }

    local final_config = config.apply(user_config)
    expect(final_config.diff_opts.keep_terminal_focus).to_be_true()
  end)

  it("should reject invalid keep_terminal_focus configuration", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = "invalid", -- Should be boolean
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should accept function for external_terminal_cmd", function()
    local valid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = function(cmd, env)
            return "terminal " .. cmd
          end,
        },
      },
    }

    local success, _ = pcall(function()
      config.validate(valid_config)
    end)

    expect(success).to_be_true()
  end)

  it("should accept string for external_terminal_cmd", function()
    local valid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = "alacritty -e %s",
        },
      },
    }

    local success, _ = pcall(function()
      config.validate(valid_config)
    end)

    expect(success).to_be_true()
  end)

  it("should reject invalid type for external_terminal_cmd", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = 123, -- Invalid: number
        },
      },
    }

    local success, err = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
    expect(tostring(err)).to_match("must be a string or function")
  end)

  describe("how far back the agents list reaches", function()
    local function with_limit(limit)
      local cfg = {
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = { auto_close_on_accept = true, show_diff_stats = true, vertical_split = true },
        env = {},
        models = { { name = "Test Model", value = "test" } },
        terminal = { provider = "native" },
        agents = { enabled = true, sessions = { limit = limit } },
      }
      return function()
        config.validate(cfg)
      end
    end

    it("defaults to a fortnight, under a cap that always applies", function()
      expect(config.defaults.agents.sessions.limit).to_be("2w")
      expect(config.defaults.agents.sessions.max).to_be(200)
    end)

    it("takes a span, a count, or everything", function()
      for _, limit in ipairs({ "1d", "14d", "2w", "1m", "all", 30 }) do
        expect(pcall(with_limit(limit))).to_be_true()
      end
    end)

    it("refuses a span it cannot read", function()
      local ok, err = pcall(with_limit("last tuesday"))
      expect(ok).to_be_false()
      expect(tostring(err)).to_match("span")
    end)
  end)

  describe("launch profiles", function()
    local function valid(profiles)
      return pcall(config.validate_profiles, profiles)
    end

    it("accepts no profiles block, and the built-ins it stands for", function()
      expect(valid(nil)).to_be_true()
      expect(valid({})).to_be_true()
      expect(valid({ default = "API key" })).to_be_true()
      expect(pcall(config.apply, { profiles = { default = "subscription" } })).to_be_true()
    end)

    it("accepts a full profile list", function()
      expect(valid({
        default = "work",
        list = {
          { name = "sub", key = "s", auth = "subscription", model = "opus", args = "--verbose" },
          { name = "work", key = "w", auth = "api", keychain = "team.prod-1", workspace = "wrkspc_1", mark = "€" },
          { name = "1p", auth = "api", api_key_cmd = "op read op://x", env = { ANTHROPIC_BASE_URL = "https://x" } },
        },
      })).to_be_true()
    end)

    it("rejects a default that names no profile", function()
      local ok, err = valid({ default = "nope" })
      expect(ok).to_be_false()
      expect(tostring(err):find("names no profile", 1, true) ~= nil).to_be_true()
    end)

    it("keeps the menu's own keys off profiles", function()
      for _, key in ipairs({ "h", "j", "k", "l", "q" }) do
        local ok, err = valid({ list = { { name = "a", key = key, auth = "subscription" } } })
        expect(ok).to_be_false()
        expect(tostring(err):find("menu's own", 1, true) ~= nil).to_be_true()
      end
    end)

    it("rejects a keychain entry that would not be safe on a command line", function()
      expect(valid({ list = { { name = "a", auth = "api", keychain = "my key" } } })).to_be_false()
      expect(valid({ list = { { name = "a", auth = "api", keychain = "x;rm" } } })).to_be_false()
    end)

    it("rejects what does not fit together", function()
      expect(valid({ list = { { name = "a", auth = "both" } } })).to_be_false()
      expect(valid({ list = { { name = "a", auth = "api", keychain = "k", api_key_cmd = "c" } } })).to_be_false()
      expect(valid({ list = { { name = "a", auth = "subscription", keychain = "k" } } })).to_be_false()
      expect(valid({ list = { { name = "a", auth = "api" }, { name = "a", auth = "api" } } })).to_be_false()
      expect(valid({ list = { { name = "a", key = "x", auth = "api" }, { name = "b", key = "x", auth = "api" } } })).to_be_false()
      expect(valid({ list = { { name = "a", auth = "api", env = { X = 1 } } } })).to_be_false()
      expect(valid({ list = { { auth = "api" } } })).to_be_false()
    end)

    it("takes the agents view's two profile keys", function()
      local ok = pcall(config.apply, { agents = { keymaps = { new_as = "gA", resume_as = false } } })
      expect(ok).to_be_true()
      expect(pcall(config.apply, { agents = { keymaps = { new_as = 3 } } })).to_be_false()
    end)
  end)

  teardown()
end)
