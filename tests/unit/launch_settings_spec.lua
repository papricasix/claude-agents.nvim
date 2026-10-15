-- luacheck: globals expect
require("tests.busted_setup")

describe("launch_settings", function()
  local launch_settings
  local utils
  local written
  local errors

  ---A writer that keeps what it was handed, and names a path for it.
  local function writer(settings)
    written[#written + 1] = settings
    return "/tmp/merged-" .. #written .. ".json"
  end

  ---The value every `--settings` in a command carries, in order.
  local function settings_flags(cmd)
    local _, sources = launch_settings.extract(utils.shell_split(cmd))
    return sources
  end

  local HOOKS = {
    hooks = {
      SessionStart = { { hooks = { { type = "command", command = "plugin-hook" } } } },
      PreToolUse = { { matcher = "*", hooks = { { type = "command", command = "plugin-hook" } } } },
    },
  }

  local real_decode, real_error

  before_each(function()
    real_decode = vim.json.decode
    vim.json.decode = _G.json_decode
    package.loaded["claude_agents.launch_settings"] = nil
    launch_settings = require("claude_agents.launch_settings")
    utils = require("claude_agents.utils")
    written = {}
    errors = {}
    local logger = require("claude_agents.logger")
    real_error = logger.error
    logger.error = function(_, msg)
      errors[#errors + 1] = msg
    end
  end)

  after_each(function()
    vim.json.decode = real_decode
    require("claude_agents.logger").error = real_error
  end)

  describe("extract", function()
    it("takes both spellings of the flag out, in order, and keeps everything else", function()
      local rest, sources = launch_settings.extract({
        "claude",
        "--settings",
        "/a.json",
        "--model",
        "opus",
        '--settings={"x":1}',
      })
      assert.same({ "claude", "--model", "opus" }, rest)
      assert.same({ "/a.json", '{"x":1}' }, sources)
    end)

    it("leaves a command without the flag alone", function()
      local rest, sources = launch_settings.extract({ "claude", "--resume", "abc" })
      assert.same({ "claude", "--resume", "abc" }, rest)
      assert.same({}, sources)
    end)
  end)

  describe("load", function()
    it("reads inline JSON", function()
      local settings = launch_settings.load('{"apiKeyHelper":"x"}')
      expect(settings.apiKeyHelper).to_be("x")
    end)

    it("reads a file, relative to the directory Claude runs in", function()
      local dir = os.tmpname()
      os.remove(dir)
      os.execute("mkdir -p '" .. dir .. "'")
      local f = assert(io.open(dir .. "/mine.json", "w"))
      f:write('{"env":{"FOO":"bar"}}')
      f:close()
      local settings = launch_settings.load("mine.json", dir)
      expect(settings.env.FOO).to_be("bar")
      os.remove(dir .. "/mine.json")
      os.remove(dir)
    end)

    it("says what is wrong with a file that is missing or not an object", function()
      local settings, err = launch_settings.load("/no/such/file.json")
      expect(settings).to_be(nil)
      expect(err:find("cannot read", 1, true) ~= nil).to_be_true()
      local path = os.tmpname()
      local f = assert(io.open(path, "w"))
      f:write("[1, 2]")
      f:close()
      local _, bad = launch_settings.load(path)
      os.remove(path)
      expect(bad:find("not a JSON object", 1, true) ~= nil).to_be_true()
    end)
  end)

  describe("merge", function()
    it("keeps the user's settings and adds the plugin's hooks beside theirs", function()
      local user = {
        model = "opus",
        hooks = { SessionStart = { { hooks = { { type = "command", command = "user-hook" } } } } },
      }
      local merged = launch_settings.merge(user, HOOKS, nil)
      expect(merged.model).to_be("opus")
      expect(#merged.hooks.SessionStart).to_be(2)
      expect(merged.hooks.SessionStart[1].hooks[1].command).to_be("user-hook")
      expect(merged.hooks.SessionStart[2].hooks[1].command).to_be("plugin-hook")
      expect(#merged.hooks.PreToolUse).to_be(1)
      -- The user's table is not changed under them.
      expect(#user.hooks.SessionStart).to_be(1)
    end)

    it("lets the profile decide which account pays", function()
      local user = { apiKeyHelper = "their-helper", env = { ANTHROPIC_API_KEY = "sk-theirs", KEEP = "1" } }
      local merged = launch_settings.merge(user, nil, {
        apiKeyHelper = "",
        env = { ANTHROPIC_API_KEY = "" },
      })
      expect(merged.apiKeyHelper).to_be("")
      expect(merged.env.ANTHROPIC_API_KEY).to_be("")
      expect(merged.env.KEEP).to_be("1")
    end)
  end)

  describe("apply", function()
    it("leaves the command alone when there is nothing to add", function()
      local cmd = "claude --settings '/mine.json'"
      expect(launch_settings.apply(cmd, { write = writer })).to_be(cmd)
      expect(#written).to_be(0)
    end)

    it("hands the CLI exactly one --settings, the user's merged with the plugin's", function()
      -- Two flags would leave only the last: measured against CLI 2.1.300, the
      -- second replaces the first entirely.
      local cmd = launch_settings.apply([[claude --model opus --settings '{"model":"sonnet"}']], {
        hooks = HOOKS,
        write = writer,
      })
      assert.same({ "/tmp/merged-1.json" }, settings_flags(cmd))
      expect(written[1].model).to_be("sonnet")
      expect(written[1].hooks.SessionStart[1].hooks[1].command).to_be("plugin-hook")
      -- The rest of the command is intact.
      local argv = utils.shell_split(cmd)
      expect(argv[1]).to_be("claude")
      expect(argv[2]).to_be("--model")
      expect(argv[3]).to_be("opus")
    end)

    it("keeps the user's own quoting when they passed no --settings", function()
      local cmd = launch_settings.apply("claude --model 'opus[1m]'", { hooks = HOOKS, write = writer })
      expect(cmd:sub(1, #"claude --model 'opus[1m]'")).to_be("claude --model 'opus[1m]'")
      assert.same({ "/tmp/merged-1.json" }, settings_flags(cmd))
    end)

    it("reads only the last of several user flags, as the CLI would", function()
      launch_settings.apply([[claude --settings '{"a":1}' --settings '{"b":2}']], { hooks = HOOKS, write = writer })
      expect(written[1].a).to_be(nil)
      expect(written[1].b).to_be(2)
    end)

    it("says so when the user's settings cannot be read, and launches without them", function()
      local cmd = launch_settings.apply("claude --settings /no/such.json", { hooks = HOOKS, write = writer })
      expect(#errors).to_be(1)
      expect(errors[1]:find("could not be read", 1, true) ~= nil).to_be_true()
      assert.same({ "/tmp/merged-1.json" }, settings_flags(cmd))
    end)

    it("adds a profile's settings even when no hooks are wanted", function()
      local cmd = launch_settings.apply("claude", { profile = { apiKeyHelper = "helper" }, write = writer })
      assert.same({ "/tmp/merged-1.json" }, settings_flags(cmd))
      expect(written[1].apiKeyHelper).to_be("helper")
    end)

    it("hands back the command unchanged when the merged file cannot be written", function()
      local cmd = "claude --settings /mine.json"
      expect(launch_settings.apply(cmd, {
        hooks = HOOKS,
        write = function()
          return nil
        end,
      })).to_be(cmd)
    end)
  end)
end)
