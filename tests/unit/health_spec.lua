-- luacheck: globals expect
require("tests.busted_setup")

describe("health", function()
  local health
  local reports

  -- State the stubs expose to the module under test
  local fake_state
  local instances
  local server_status
  local executables
  local lock_readable
  -- What the API key helper answers when the health check asks it.
  local key_check
  local real_system

  local function record(level)
    return function(msg)
      table.insert(reports, { level = level, msg = msg })
    end
  end

  local function has_report(level, pattern)
    for _, r in ipairs(reports) do
      if r.level == level and r.msg:find(pattern) then
        return true
      end
    end
    return false
  end

  before_each(function()
    reports = {}
    executables = { claude = true }
    lock_readable = true
    server_status = { running = true, port = 12345, client_count = 1 }
    instances = {
      ["tab:1"] = {
        id = "tab:1",
        kind = "tab",
        tab = 1,
        server = {
          get_status = function()
            return server_status
          end,
        },
      },
    }
    fake_state = {
      initialized = true,
      config = { terminal_cmd = nil, terminal = { provider = "native" }, diff_opts = {} },
    }

    vim.health = {
      start = record("start"),
      ok = record("ok"),
      warn = record("warn"),
      error = record("error"),
      info = record("info"),
    }
    vim.trim = vim.trim or function(s)
      return s:match("^%s*(.-)%s*$")
    end
    vim.v = vim.v or {}
    vim.v.shell_error = 0
    vim.fn.executable = function(exe)
      return executables[exe] and 1 or 0
    end
    vim.fn.exepath = function(exe)
      return "/usr/bin/" .. exe
    end
    vim.fn.system = function(_)
      return "1.0.0 (Claude Code)\n"
    end
    vim.fn.filereadable = function(_)
      return lock_readable and 1 or 0
    end

    package.loaded["claude_agents"] = {
      version = {
        string = function()
          return "0.2.0"
        end,
      },
      state = fake_state,
      instances = instances,
    }
    package.loaded["claude_agents.lockfile"] = { lock_dir = "/tmp/claude/ide" }

    local profiles = require("claude_agents.profiles")
    profiles._reset()
    key_check = { code = 0, stdout = "found 108 ok\n", stderr = "" }
    real_system = profiles._system
    profiles._system = function()
      return {
        wait = function()
          return key_check
        end,
      }
    end

    package.loaded["claude_agents.health"] = nil
    health = require("claude_agents.health")
  end)

  after_each(function()
    require("claude_agents.profiles")._system = real_system
    package.loaded["claude_agents"] = nil
    package.loaded["claude_agents.lockfile"] = nil
    package.loaded["claude_agents.health"] = nil
  end)

  describe("launch profiles", function()
    it("reports the built-in profiles and a stored API key", function()
      health.check()
      expect(has_report("start", "Launch profiles")).to_be_true()
      expect(has_report("ok", 'profile "subscription": your subscription')).to_be_true()
      expect(has_report("ok", 'profile "API key": API key found')).to_be_true()
      expect(has_report("error", ".")).to_be_false()
    end)

    it("says how to store a key that is missing", function()
      key_check = { code = 2, stdout = "missing\n", stderr = "" }
      health.check()
      expect(has_report("warn", 'profile "API key": no API key stored')).to_be_true()
    end)

    it("warns about a key that is not an Anthropic key's shape", function()
      key_check = { code = 0, stdout = "found 12 unexpected\n", stderr = "" }
      health.check()
      expect(has_report("warn", "does not look like an Anthropic API key")).to_be_true()
    end)

    it("reports a helper that failed as an error", function()
      key_check = { code = 1, stdout = "", stderr = "keychain locked" }
      health.check()
      expect(has_report("error", "reading the key failed: keychain locked")).to_be_true()
    end)
  end)

  it("reports all-ok for a healthy setup", function()
    health.check()

    expect(has_report("ok", "Neovim")).to_be_true()
    expect(has_report("ok", "is set up")).to_be_true()
    expect(has_report("ok", "Claude CLI found")).to_be_true()
    expect(has_report("ok", "WebSocket server on port 12345")).to_be_true()
    expect(has_report("ok", "lock file present")).to_be_true()
    expect(has_report("info", "1 client%(s%) connected")).to_be_true()
    expect(has_report("error", ".")).to_be_false()
  end)

  describe("Neovim version", function()
    local real_has

    before_each(function()
      real_has = vim.fn.has
    end)

    after_each(function()
      vim.fn.has = real_has
    end)

    local function parts(version)
      local out = {}
      for n in version:gmatch("%d+") do
        out[#out + 1] = tonumber(n)
      end
      return out
    end

    -- has("nvim-X") answers whether `version` is at least X, compared numerically
    local function running(version)
      local have = parts(version)
      vim.fn.has = function(feature)
        local wanted = feature:match("^nvim%-(.+)$")
        if not wanted then
          return 0
        end
        local want = parts(wanted)
        for i = 1, 3 do
          local w, h = want[i] or 0, have[i] or 0
          if w ~= h then
            return w < h and 1 or 0
          end
        end
        return 1
      end
    end

    it("warns on 0.10, where terminal links cannot work", function()
      running("0.10.4")

      health.check()

      expect(has_report("warn", "needs 0%.11")).to_be_true()
      expect(has_report("error", "Neovim")).to_be_false()
    end)

    it("errors below 0.10", function()
      running("0.9.5")

      health.check()

      expect(has_report("error", "Neovim >= 0%.10%.0 is required")).to_be_true()
    end)
  end)

  it("errors when setup() was not called and stops early", function()
    fake_state.initialized = false

    health.check()

    expect(has_report("error", "setup%(%) has not been called")).to_be_true()
    expect(has_report("ok", "Claude CLI found")).to_be_false()
  end)

  it("errors when the Claude CLI is missing", function()
    executables = {}

    health.check()

    expect(has_report("error", "Claude CLI not found")).to_be_true()
  end)

  it("resolves the executable from a custom terminal_cmd", function()
    fake_state.config.terminal_cmd = "/opt/claude/bin/claude --flag"
    executables["/opt/claude/bin/claude"] = true

    health.check()

    expect(has_report("ok", "Claude CLI found: /opt/claude/bin/claude")).to_be_true()
  end)

  it("warns when nothing is running", function()
    for key in pairs(instances) do
      instances[key] = nil
    end

    health.check()

    expect(has_report("warn", "No WebSocket server is running")).to_be_true()
    expect(has_report("ok", "lock file present")).to_be_false()
  end)

  it("errors when the lock file is missing", function()
    lock_readable = false

    health.check()

    expect(has_report("error", "lock file missing")).to_be_true()
  end)

  it("reports info when no client is connected", function()
    server_status.client_count = 0

    health.check()

    expect(has_report("info", "no Claude connected yet")).to_be_true()
  end)

  it("names an agent instance by its conversation", function()
    instances["agent:abc123"] = {
      id = "agent:abc123",
      kind = "agent",
      tab = 1,
      session_id = "abc123",
      server = {
        get_status = function()
          return { running = true, port = 23456, client_count = 0 }
        end,
      },
    }

    health.check()

    expect(has_report("ok", "agent abc123: WebSocket server on port 23456")).to_be_true()
  end)

  it("errors when snacks provider is configured but unavailable", function()
    fake_state.config.terminal = { provider = "snacks" }

    health.check()

    expect(has_report("error", "snacks.nvim is not installed")).to_be_true()
  end)

  it("warns when a float layout is configured without unified.nvim", function()
    fake_state.config.diff_opts = { layout = "float" }

    health.check()

    expect(has_report("warn", "unified.nvim is not installed")).to_be_true()
  end)

  describe("OpenCode", function()
    local switched_off
    local ran

    before_each(function()
      executables.opencode = true
      switched_off = false
      ran = {}
      vim.fn.system = function(argv)
        ran[#ran + 1] = type(argv) == "table" and table.concat(argv, " ") or tostring(argv)
        return "1.0.0\n"
      end
      package.loaded["claude_agents.opencode.service"] = {
        disabled_sync = function()
          return switched_off
        end,
        read_registration = function()
          return nil, "no OpenCode service is registered (/state/service.json)"
        end,
      }
    end)

    after_each(function()
      package.loaded["claude_agents.opencode.service"] = nil
    end)

    it("says how to switch a disabled service back on, and not that a launch starts it", function()
      switched_off = true
      health.check()
      expect(has_report("warn", "service is disabled")).to_be_true()
      expect(has_report("info", "first OpenCode launch starts it")).to_be_false()
    end)

    it("says nothing about disabling when the service is merely not running", function()
      health.check()
      expect(has_report("warn", "disabled")).to_be_false()
      expect(has_report("info", "service is not running")).to_be_true()
    end)

    it("never asks `opencode service status`, which does not say whether it is disabled", function()
      health.check()
      for _, cmd in ipairs(ran) do
        expect(cmd:find("service status", 1, true)).to_be_nil()
      end
    end)
  end)
end)
