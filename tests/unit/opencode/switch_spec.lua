-- luacheck: globals expect
require("tests.busted_setup")

-- Choosing OpenCode: the config that asks for it, the profiles that carry it,
-- and how a launch decides which CLI it runs.
describe("choosing OpenCode", function()
  local config, profiles, backend, opencode

  before_each(function()
    for _, name in ipairs({
      "claude_agents.config",
      "claude_agents.profiles",
      "claude_agents.backend",
      "claude_agents.opencode",
      "claude_agents.session_state",
    }) do
      package.loaded[name] = nil
    end
    config = require("claude_agents.config")
    profiles = require("claude_agents.profiles")
    backend = require("claude_agents.backend")
    opencode = require("claude_agents.opencode")
    profiles._io = {
      read = function() end,
      write = function()
        return true
      end,
      stat = function() end,
    }
  end)

  describe("config", function()
    local function valid(overrides)
      local cfg = vim.deepcopy(config.defaults)
      cfg.terminal = { split_side = "right", split_width_percentage = 0.3, provider = "auto" }
      for key, value in pairs(overrides) do
        cfg[key] = value
      end
      return pcall(config.validate, cfg)
    end

    it("defaults to Claude, with review on for OpenCode and no aliases", function()
      expect(config.defaults.backend).to_be("claude")
      expect(config.defaults.opencode.review_edits).to_be_true()
      expect(config.defaults.command_aliases).to_be_false()
    end)

    it("accepts the backends it knows and nothing else", function()
      assert.is_true(valid({ backend = "opencode" }))
      assert.is_false(valid({ backend = "gemini" }))
      assert.is_false(valid({ opencode = { cmd = "" } }))
      assert.is_false(valid({ opencode = { review_edits = "yes" } }))
      assert.is_false(valid({ command_aliases = 1 }))
      assert.is_true(valid({ opencode = { agent_keybinds = false } }))
      assert.is_true(valid({ opencode = { agent_keybinds = { ["command.palette.show"] = "ctrl+y" } } }))
      assert.is_false(valid({ opencode = { agent_keybinds = "ctrl+y" } }))
      assert.is_false(valid({ opencode = { agent_keybinds = { ["command.palette.show"] = 5 } } }))
    end)

    it("lets the agents view start OpenCode's service by default, or leave it to a launch", function()
      expect(config.defaults.opencode.start_service).to_be("view")
      expect(opencode.config().start_service).to_be("view")
      assert.is_true(valid({ opencode = { start_service = "launch" } }))
      assert.is_false(valid({ opencode = { start_service = "never" } }))
      assert.is_false(valid({ opencode = { start_service = true } }))
    end)

    it("names a Neovim chord in OpenCode's notation", function()
      expect(opencode.opencode_key("<C-p>")).to_be("ctrl+p")
      expect(opencode.opencode_key("<c-N>")).to_be("ctrl+n")
      expect(opencode.opencode_key("<M-p>")).to_be("alt+p")
      expect(opencode.opencode_key("gs")).to_be_nil()
      expect(opencode.opencode_key(false)).to_be_nil()
    end)

    it("checks OpenCode's status icons like Claude's", function()
      assert.is_true(valid({ status = { opencode_icons = { busy = { "a", "b" } } } }))
      assert.is_false(valid({ status = { opencode_icons = { busy = {} } } }))
      assert.is_false(valid({ status = { opencode_icons = { spinning = "x" } } }))
    end)

    it("holds an OpenCode profile to OpenCode's fields", function()
      assert.is_true(pcall(config.validate_profiles, {
        list = { { name = "oc", backend = "opencode", model = "anthropic/claude-haiku-4-5", agent = "plan" } },
      }))
      assert.is_false(pcall(config.validate_profiles, {
        list = { { name = "oc", backend = "opencode", auth = "api" } },
      }))
      assert.is_false(
        pcall(config.validate_profiles, { list = { { name = "oc", backend = "opencode", model = "haiku" } } })
      )
      -- A Claude profile still needs its auth, and has no agent.
      assert.is_false(pcall(config.validate_profiles, { list = { { name = "c" } } }))
      assert.is_false(
        pcall(config.validate_profiles, { list = { { name = "c", auth = "subscription", agent = "x" } } })
      )
    end)
  end)

  describe("profiles", function()
    it("offers OpenCode among the built-ins when it is the backend", function()
      profiles._executable = function()
        return false
      end
      local list = profiles.builtin_list({ backend = "opencode" })
      expect(list[#list].backend).to_be("opencode")
    end)

    it("offers it when it is installed, and keeps Claude's", function()
      profiles._executable = function(exe)
        return exe == "opencode" or exe == "claude"
      end
      local names = {}
      for _, entry in ipairs(profiles.builtin_list({})) do
        names[#names + 1] = entry.name
      end
      expect(table.concat(names, ",")).to_be("subscription,API key,OpenCode")
    end)

    it("leaves Claude's out when only OpenCode is there to run", function()
      profiles._executable = function(exe)
        return exe == "opencode"
      end
      local list = profiles.builtin_list({ backend = "opencode" })
      expect(#list).to_be(1)
    end)

    it("tells the backend of a profile", function()
      expect(profiles.backend({ name = "x", auth = "api" })).to_be("claude")
      expect(profiles.backend({ name = "y", backend = "opencode" })).to_be("opencode")
      expect(profiles.backend(nil)).to_be_nil()
    end)

    it("finds an OpenCode conversation on a command line", function()
      expect(profiles.session_of_argv({ "opencode", "--session", "ses_abc" })).to_be("ses_abc")
      expect(profiles.session_of_argv({ "opencode", "-s", "ses_abc" })).to_be("ses_abc")
      expect(profiles.session_of_argv({ "opencode", "--session", "not-an-id" })).to_be_nil()
    end)

    it("gives an OpenCode launch its model and agent, and blanks no Anthropic keys", function()
      local parts = profiles.launch_parts(
        { name = "oc", backend = "opencode", model = "anthropic/claude-haiku-4-5", agent = "plan", env = { A = "1" } },
        {}
      )
      expect(parts.model.providerID).to_be("anthropic")
      expect(parts.model.id).to_be("claude-haiku-4-5")
      expect(parts.agent).to_be("plan")
      expect(parts.env.A).to_be("1")
      expect(parts.env.ANTHROPIC_API_KEY).to_be_nil()
      expect(parts.settings).to_be_nil()
    end)
  end)

  describe("backend.resolve", function()
    before_each(function()
      profiles._executable = function()
        return true
      end
      profiles.setup({})
    end)

    it("runs Claude unless told otherwise", function()
      opencode.setup({})
      expect(backend.resolve({})).to_be("claude")
    end)

    it("follows the backend option", function()
      opencode.setup({ backend = "opencode" })
      expect(backend.resolve({})).to_be("opencode")
    end)

    it("lets a profile pick the other backend", function()
      opencode.setup({ backend = "opencode" })
      expect(backend.resolve({ profile = "subscription" })).to_be("claude")
      opencode.setup({})
      expect(backend.resolve({ profile = "OpenCode" })).to_be("opencode")
    end)

    it("continues a conversation in the CLI that holds it", function()
      opencode.setup({ backend = "opencode" })
      expect(backend.resolve({ cmd_args = "--resume 12345678-1234-1234-1234-123456789abc" })).to_be("claude")
      opencode.setup({})
      expect(backend.resolve({ session_id = "ses_abc" })).to_be("opencode")
    end)

    it("lets a default profile decide plain launches", function()
      opencode.setup({})
      profiles.setup({ profiles = { default = "OpenCode" } })
      expect(backend.resolve({})).to_be("opencode")
    end)
  end)

  describe("session persistence", function()
    local session_state

    before_each(function()
      session_state = require("claude_agents.session_state")
      session_state.reset()
      session_state.setup({ session_persistence = "external" })
      package.loaded["claude_agents.opencode.sessions"] = {
        resumable = function()
          return true
        end,
      }
    end)

    after_each(function()
      package.loaded["claude_agents.opencode.sessions"] = nil
    end)

    it("names a tab's OpenCode conversation with an OpenCode id, and keeps it across toggles", function()
      local tab = vim.api.nvim_get_current_tabpage()
      local id = session_state.opencode_session(tab, "/proj")
      assert.is_truthy(id and id:match("^ses_"))
      expect(session_state.opencode_session(tab, "/proj")).to_be(id)
    end)

    it("starts a Claude conversation when a tab that had OpenCode's launches Claude", function()
      local tab = vim.api.nvim_get_current_tabpage()
      local oc_id = session_state.opencode_session(tab, "/proj")
      local args = session_state.launch_args("claude", "/proj")
      assert_contains(args, "--session-id ")
      assert_not_contains(args, oc_id)
      expect(session_state.get(tab).fallback).to_be(oc_id)
    end)
  end)

  describe("command aliases", function()
    it("names each command without the ClaudeCode prefix", function()
      local main = require("claude_agents")
      expect(main.alias_name("ClaudeCode")).to_be("Agent")
      expect(main.alias_name("ClaudeCodeSend")).to_be("AgentSend")
      expect(main.alias_name("ClaudeCodeAgents")).to_be("Agents")
      expect(main.alias_name("ClaudeCodeAgentNew")).to_be("AgentNew")
      expect(main.alias_name("ClaudeCodeAgentsFlag")).to_be("AgentsFlag")
      expect(main.alias_name("ClaudeCodeAgentFollowUp")).to_be("AgentFollowUp")
      expect(main.alias_name("ClaudeCodeDiffAccept")).to_be("AgentDiffAccept")
      expect(main.alias_name("Other")).to_be_nil()
    end)
  end)
end)
