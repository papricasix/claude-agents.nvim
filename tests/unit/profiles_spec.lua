-- luacheck: globals expect
require("tests.busted_setup")

describe("profiles", function()
  local profiles
  local utils
  local files
  local real_decode

  ---An in-memory filesystem standing in for the store's.
  local function fake_io()
    files = {}
    return {
      read = function(path)
        return files[path]
      end,
      write = function(path, data)
        files[path] = data
        return true
      end,
      stat = function(path)
        return files[path] and ("%d:%s"):format(#files[path], files[path]) or nil
      end,
    }
  end

  local function setup(profiles_config)
    profiles.setup({ profiles = profiles_config })
  end

  before_each(function()
    real_decode = vim.json.decode
    vim.json.decode = _G.json_decode
    package.loaded["claude_agents.profiles"] = nil
    profiles = require("claude_agents.profiles")
    utils = require("claude_agents.utils")
    profiles._io = fake_io()
    setup(nil)
  end)

  after_each(function()
    vim.json.decode = real_decode
  end)

  describe("configuration", function()
    it("offers the two built-ins when the config names none", function()
      local list = profiles.list()
      expect(#list).to_be(2)
      expect(list[1].name).to_be("subscription")
      expect(list[1].auth).to_be("subscription")
      expect(list[2].name).to_be("API key")
      expect(list[2].auth).to_be("api")
      expect(list[2].keychain).to_be("default")
    end)

    it("finds a profile by name, by name in any case, or by its key", function()
      expect(profiles.get("API key").name).to_be("API key")
      expect(profiles.get("api KEY").name).to_be("API key")
      expect(profiles.get("a").name).to_be("API key")
      expect(profiles.get("nothing")).to_be(nil)
      expect(profiles.get(nil)).to_be(nil)
    end)

    it("gives an api profile with no key source the default keychain entry", function()
      setup({ list = { { name = "work", auth = "api" } } })
      expect(profiles.get("work").keychain).to_be("default")
    end)

    it("leaves plain launches alone unless a default is named", function()
      expect(profiles.default()).to_be(nil)
      setup({ default = "subscription" })
      expect(profiles.default().name).to_be("subscription")
    end)

    it("marks what costs per token", function()
      expect(profiles.mark("API key")).to_be("$")
      expect(profiles.mark("subscription")).to_be("")
      setup({ list = { { name = "team", auth = "api", mark = "€" } } })
      expect(profiles.mark("team")).to_be("€")
      expect(profiles.mark("nothing")).to_be("")
    end)
  end)

  describe("which conversation a command names", function()
    it("reads every form of --resume and --session-id", function()
      local id = "0f9a1c3e-1111-4222-8333-444455556666"
      expect(profiles.session_of_argv({ "claude", "--resume", id })).to_be(id)
      expect(profiles.session_of_argv({ "claude", "--resume=" .. id })).to_be(id)
      expect(profiles.session_of_argv({ "claude", "-r", id })).to_be(id)
      expect(profiles.session_of_argv({ "claude", "--session-id", id })).to_be(id)
      expect(profiles.session_of_argv({ "claude", "--resume" })).to_be(nil)
      expect(profiles.session_of_argv({ "claude", "--model", "opus" })).to_be(nil)
    end)
  end)

  describe("resolve", function()
    local id = "0f9a1c3e-1111-4222-8333-444455556666"

    it("takes the profile asked for over anything else", function()
      profiles.remember(id, "API key")
      setup({ default = "API key" })
      expect(profiles.resolve("subscription", { "claude", "--resume", id }).name).to_be("subscription")
    end)

    it("resumes a conversation under the profile it last ran under", function()
      profiles.remember(id, "API key")
      expect(profiles.resolve(nil, { "claude", "--resume", id }).name).to_be("API key")
    end)

    it("falls back to the default, and to nothing at all", function()
      expect(profiles.resolve(nil, { "claude" })).to_be(nil)
      setup({ default = "subscription" })
      expect(profiles.resolve(nil, { "claude" }).name).to_be("subscription")
    end)

    it("forgets a profile that no longer exists rather than resuming under it", function()
      profiles.remember(id, "API key")
      setup({ list = { { name = "subscription", auth = "subscription" } } })
      expect(profiles.of(id)).to_be(nil)
      expect(profiles.resolve(nil, { "claude", "--resume", id })).to_be(nil)
    end)
  end)

  describe("launch parts", function()
    it("adds nothing for a plain launch", function()
      expect(profiles.launch_parts(nil, { "claude" })).to_be(nil)
    end)

    it("puts a subscription launch on the claude.ai login", function()
      local parts = profiles.launch_parts(profiles.get("subscription"), { "claude" })
      -- Blank, not absent: Neovim's job env cannot unset a variable, and the CLI
      -- tests these for truth (measured: "" launches on the subscription).
      expect(parts.env.ANTHROPIC_API_KEY).to_be("")
      expect(parts.env.ANTHROPIC_AUTH_TOKEN).to_be("")
      expect(parts.env.CLAUDE_CODE_OAUTH_TOKEN).to_be(nil)
      -- Switches off a helper the user's own settings may set.
      expect(parts.settings.apiKeyHelper).to_be("")
      expect(parts.settings.env.ANTHROPIC_API_KEY).to_be("")
    end)

    it("hands an api launch the keychain helper, and nothing that would outrank it", function()
      local parts = profiles.launch_parts(profiles.get("API key"), { "claude" })
      local helper = parts.settings.apiKeyHelper
      expect(helper:find("api_key.lua", 1, true) ~= nil).to_be_true()
      expect(helper:find("--headless -u NONE -l", 1, true) ~= nil).to_be_true()
      expect(helper:sub(-#" get default")).to_be(" get default")
      expect(parts.env.ANTHROPIC_API_KEY).to_be("")
      expect(parts.env.CLAUDE_CODE_OAUTH_TOKEN).to_be("")
    end)

    it("runs a profile's own key command verbatim", function()
      setup({ list = { { name = "1p", auth = "api", api_key_cmd = "op read op://x/y" } } })
      expect(profiles.launch_parts(profiles.get("1p"), { "claude" }).settings.apiKeyHelper).to_be("op read op://x/y")
    end)

    it("passes its model unless the command already picks one", function()
      setup({ list = { { name = "opus", auth = "subscription", model = "opus[1m]", args = "--permission-mode plan" } } })
      local parts = profiles.launch_parts(profiles.get("opus"), { "claude" })
      expect(parts.args).to_be("--model 'opus[1m]' --permission-mode plan")
      local explicit = profiles.launch_parts(profiles.get("opus"), { "claude", "--model", "haiku" })
      expect(explicit.args).to_be("--permission-mode plan")
      -- The quoting is the launch's own, which no shell ever sees.
      expect(utils.shell_split(parts.args)[2]).to_be("opus[1m]")
    end)

    it("adds the profile's environment and workspace", function()
      setup({
        list = { { name = "org", auth = "api", env = { ANTHROPIC_BASE_URL = "https://x" }, workspace = "wrkspc_1" } },
      })
      local parts = profiles.launch_parts(profiles.get("org"), { "claude" })
      expect(parts.env.ANTHROPIC_BASE_URL).to_be("https://x")
      expect(parts.workspace).to_be("wrkspc_1")
    end)
  end)

  describe("custom headers", function()
    it("adds the workspace header and keeps every other one", function()
      expect(profiles.custom_headers(nil, "wrkspc_1")).to_be("anthropic-workspace-id: wrkspc_1")
      expect(profiles.custom_headers("X-Team: a\nanthropic-workspace-id: old", "wrkspc_2")).to_be(
        "X-Team: a\nanthropic-workspace-id: wrkspc_2"
      )
    end)
  end)

  describe("the store", function()
    it("remembers which profile a conversation ran under, across a reload", function()
      profiles.remember("id-1", "API key")
      expect(profiles.of("id-1")).to_be("API key")
      package.loaded["claude_agents.profiles"] = nil
      local io_table = profiles._io
      profiles = require("claude_agents.profiles")
      profiles._io = io_table
      expect(profiles.of("id-1")).to_be("API key")
    end)

    it("carries a profile to the conversation that took over, and forgets a deleted one", function()
      profiles.remember("old", "API key")
      profiles.carry("old", "new")
      expect(profiles.of("new")).to_be("API key")
      profiles.forget("old")
      expect(profiles.of("old")).to_be(nil)
      expect(profiles.of("new")).to_be("API key")
    end)

    it("does not write over what another Neovim wrote meanwhile", function()
      profiles.remember("mine", "API key")
      -- Another Neovim adds a conversation of its own.
      local path = profiles.store_path()
      local data = _G.json_decode(files[path])
      data.sessions.theirs = { profile = "subscription", at = 1 }
      files[path] = vim.json.encode(data)
      profiles.remember("mine-too", "subscription")
      expect(profiles.of("theirs")).to_be("subscription")
      expect(profiles.of("mine")).to_be("API key")
    end)

    it("takes in another Neovim's writes on refresh", function()
      profiles.remember("mine", "API key")
      local path = profiles.store_path()
      local data = _G.json_decode(files[path])
      data.sessions.theirs = { profile = "subscription", at = 1 }
      files[path] = vim.json.encode(data)
      expect(profiles.refresh()).to_be_true()
      expect(profiles.of("theirs")).to_be("subscription")
      expect(profiles.refresh()).to_be(false)
    end)
  end)

  describe("a tab's own Claude", function()
    it("becomes the profile the command was built with once its terminal exists", function()
      profiles.set_pending_tab_launch(1, "API key", "conv-1")
      expect(profiles.of_tab(1)).to_be(nil)
      local buf = vim.api.nvim_create_buf(false, true)
      profiles.note_tab_terminal(1, buf)
      expect(profiles.of_tab(1)).to_be("API key")
      expect(profiles.of("conv-1")).to_be("API key")
      expect(vim.b[buf].claudecode_profile).to_be("API key")
    end)

    it("files the conversation it reports under the tab's profile, and forgets it when it ends", function()
      profiles.set_pending_tab_launch(1, "API key", nil)
      profiles.note_tab_terminal(1, nil)
      profiles.note_tab_session(1, "after-clear")
      expect(profiles.of("after-clear")).to_be("API key")
      profiles.forget_tab(1)
      expect(profiles.of_tab(1)).to_be(nil)
    end)

    it("files nothing for a plain launch", function()
      profiles.set_pending_tab_launch(1, nil, "conv-2")
      profiles.note_tab_terminal(1, nil)
      profiles.note_tab_session(1, "conv-3")
      expect(profiles.of("conv-2")).to_be(nil)
      expect(profiles.of("conv-3")).to_be(nil)
    end)
  end)

  describe("key checks", function()
    it("reads what the helper says without the key", function()
      local found = profiles._parse_check({ code = 0, stdout = "found 108 ok\n" })
      expect(found.state).to_be("found")
      expect(found.length).to_be(108)
      expect(found.shape).to_be("ok")
      expect(profiles._parse_check({ code = 2, stdout = "missing\n" }).state).to_be("missing")
      local failed = profiles._parse_check({ code = 1, stdout = "", stderr = "locked\n" })
      expect(failed.state).to_be("error")
      expect(failed.detail).to_be("locked")
    end)

    it("asks the helper, and refuses a launch only once a key is known to be missing", function()
      local answer
      profiles._system = function(argv, callback)
        expect(argv[#argv - 1]).to_be("check")
        expect(argv[#argv]).to_be("default")
        callback(answer)
      end
      local notified = {}
      local real_notify = vim.notify
      vim.notify = function(msg)
        notified[#notified + 1] = msg
      end

      local profile = profiles.get("API key")
      expect(profiles.refuse_if_missing(profile)).to_be(false) -- not asked yet
      answer = { code = 2, stdout = "missing\n" }
      profiles.check(profile, function() end)
      vim.wait(100, function()
        return profiles.check_state("API key") ~= nil
      end)
      expect(profiles.refuse_if_missing(profile)).to_be_true()
      expect(notified[1]:find("Store it once", 1, true) ~= nil).to_be_true()
      vim.notify = real_notify
    end)

    it("does not ask about a subscription profile", function()
      local asked = false
      profiles._system = function()
        asked = true
      end
      local answered
      profiles.check(profiles.get("subscription"), function(check)
        answered = check
      end)
      expect(asked).to_be(false)
      expect(answered).to_be(nil)
    end)
  end)
end)
