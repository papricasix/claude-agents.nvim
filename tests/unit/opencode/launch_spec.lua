-- luacheck: globals expect
require("tests.busted_setup")

describe("opencode launch and sessions", function()
  local launch, sessions, opencode
  local calls

  ---A fake service: records every call, answers from `responses`.
  local responses
  local fake_api

  local BUILD_RULES = {
    { action = "*", resource = "*", effect = "allow" },
    { action = "question", resource = "*", effect = "allow" },
  }

  before_each(function()
    calls = {}
    responses = {}
    for _, name in ipairs({
      "claude_agents.opencode",
      "claude_agents.opencode.launch",
      "claude_agents.opencode.sessions",
      "claude_agents.opencode.bridge",
      "claude_agents.profiles",
    }) do
      package.loaded[name] = nil
    end
    opencode = require("claude_agents.opencode")
    opencode.setup({ backend = "opencode" })
    fake_api = {
      call = function(method, path, opts, cb)
        calls[#calls + 1] = { method = method, path = path, opts = opts }
        local answer = responses[method .. " " .. path]
        if type(answer) == "function" then
          answer = answer(opts)
        end
        if answer == nil then
          cb("HTTP 404", nil)
        else
          cb(nil, answer)
        end
      end,
      call_sync = function(method, path, opts)
        local err, data
        fake_api.call(method, path, opts, function(e, d)
          err, data = e, d
        end)
        return err, data
      end,
    }
    fake_api.get_session = function(id, cb)
      fake_api.call("GET", "/api/session/" .. id, nil, cb)
    end
    fake_api.create_session = function(body, cb)
      fake_api.call("POST", "/api/session", { body = body }, cb)
    end
    fake_api.update_session = function(id, body, cb)
      fake_api.call("PATCH", "/api/session/" .. id, { body = body }, cb)
    end
    fake_api.set_model = function(id, model, cb)
      fake_api.call("POST", "/api/session/" .. id .. "/model", { body = { model = model } }, cb)
    end
    fake_api.set_agent = function(id, agent, cb)
      fake_api.call("POST", "/api/session/" .. id .. "/agent", { body = { agent = agent } }, cb)
    end
    fake_api.agent = function(agent_id, _, cb)
      fake_api.call("GET", "/api/agent/" .. agent_id, nil, cb)
    end
    fake_api.messages = function(id, _, cb)
      fake_api.call("GET", "/api/session/" .. id .. "/message", nil, cb)
    end
    fake_api.delete_session = function(id, cb)
      fake_api.call("DELETE", "/api/session/" .. id, nil, cb)
    end
    sessions = require("claude_agents.opencode.sessions")
    sessions._api = fake_api
    package.loaded["claude_agents.opencode.mcp"] = nil
    require("claude_agents.opencode.mcp")._api = fake_api
    launch = require("claude_agents.opencode.launch")
    launch._sessions = sessions
    responses["GET /api/config"] = { default_agent = "build" }
    responses["GET /api/agent/build"] = { id = "build", permissions = BUILD_RULES }
    responses["PATCH /api/session/ses_new"] = function(opts)
      return { permissions = opts.body.permissions, metadata = opts.body.metadata }
    end
    responses["POST /api/session"] = function(opts)
      return {
        id = opts.body.id,
        location = opts.body.location,
        metadata = opts.body.metadata,
        permissions = {},
      }
    end
  end)

  after_each(function()
    package.loaded["claude_agents.opencode.bridge"] = nil
  end)

  local function find(method, path)
    for _, call in ipairs(calls) do
      if call.method == method and call.path == path then
        return call
      end
    end
  end

  describe("sessions.ensure", function()
    it("creates a session the TUI has never seen, with the profile's model and the review rules", function()
      local err = sessions.ensure_sync("ses_new", {
        directory = "/proj",
        model = { providerID = "anthropic", id = "claude-haiku-4-5" },
      })
      expect(err).to_be_nil()
      local create = find("POST", "/api/session")
      expect(create.opts.body.id).to_be("ses_new")
      expect(create.opts.body.model.id).to_be("claude-haiku-4-5")
      expect(create.opts.body.location.directory).to_be("/proj")
      local patch = find("PATCH", "/api/session/ses_new")
      local added = patch.opts.body.permissions
      expect(added[1].action).to_be("edit")
      expect(added[1].effect).to_be("ask")
      -- Then `open_files`: every Neovim's hidden, this one's as the agent decides.
      local own, any = require("claude_agents.opencode.mcp").actions()
      expect(added[2].action).to_be(any)
      expect(added[2].effect).to_be("deny")
      expect(added[3].action).to_be(own)
      expect(added[3].effect).to_be("allow")
      -- What it added is on record, so it can take exactly that off again.
      expect(#patch.opts.body.metadata.claude_agents.rules).to_be(3)
      expect(sessions.created_here("ses_new")).to_be_true()
    end)

    it("switches an existing session to the profile's model, and asks nothing twice per launch", function()
      responses["GET /api/session/ses_old"] = { id = "ses_old", agent = "build", location = { directory = "/proj" } }
      responses["POST /api/session/ses_old/model"] = {}
      responses["PATCH /api/session/ses_old"] = {}
      sessions.ensure_sync("ses_old", { directory = "/proj", model = { providerID = "a", id = "b" } })
      expect(find("POST", "/api/session/ses_old/model")).not_to_be_nil()
      expect(find("POST", "/api/session")).to_be_nil()
      local count = #calls
      sessions.ensure_sync("ses_old", { directory = "/proj" })
      expect(#calls).to_be(count)
    end)

    it("changes no rules when it cannot read the agent's", function()
      responses["GET /api/agent/build"] = nil
      sessions.ensure_sync("ses_new", { directory = "/proj" })
      expect(find("PATCH", "/api/session/ses_new")).to_be_nil()
    end)

    it("deletes a session it created when its terminal closes with nothing said", function()
      sessions.ensure_sync("ses_new", { directory = "/proj" })
      responses["GET /api/session/ses_new/message"] = {}
      responses["DELETE /api/session/ses_new"] = {}
      sessions.closed("ses_new")
      expect(find("DELETE", "/api/session/ses_new")).not_to_be_nil()
    end)

    it("keeps one that was used, and one it did not create", function()
      sessions.ensure_sync("ses_new", { directory = "/proj" })
      sessions.note_used("ses_new")
      sessions.closed("ses_new")
      sessions.closed("ses_foreign")
      expect(find("DELETE", "/api/session/ses_new")).to_be_nil()
      expect(find("DELETE", "/api/session/ses_foreign")).to_be_nil()
    end)
  end)

  describe("launch.build", function()
    local getenv

    -- An agent launch merges over the variable it inherits, and the tests may
    -- well run inside such an agent.
    before_each(function()
      getenv = os.getenv
      os.getenv = function(name) -- luacheck: ignore 122
        if name == "OPENCODE_CLI_CONFIG_CONTENT" then
          return nil
        end
        return getenv(name)
      end
    end)

    after_each(function()
      os.getenv = getenv -- luacheck: ignore 122
    end)

    local function ctx(overrides)
      local base = {
        instance = { port = 4242, server = {} },
        for_tab = true,
        cwd = "/proj",
        user_env = { MY = "1" },
        no_proxy = function()
          return "localhost,127.0.0.1,::1"
        end,
      }
      for key, value in pairs(overrides or {}) do
        base[key] = value
      end
      return base
    end

    it("runs opencode on a named session, told the editor's port", function()
      local cmd, env = launch.build(nil, ctx())
      local session_id = cmd:match("%-%-session (ses_[%w]+)")
      assert.is_truthy(session_id)
      expect(cmd:sub(1, 8)).to_be("opencode")
      expect(env.OPENCODE_EDITOR_SSE_PORT).to_be("4242")
      expect(env.CLAUDE_CODE_SSE_PORT).to_be("4242")
      expect(env.MY).to_be("1")
      expect(env.NO_PROXY).to_be("localhost,127.0.0.1,::1")
      expect(env.ENABLE_IDE_INTEGRATION).to_be_nil()
      expect(launch.tab_session(vim.api.nvim_get_current_tabpage())).to_be(session_id)
    end)

    it("keeps the tab's conversation across the rebuilds a toggle does", function()
      local first = launch.build(nil, ctx())
      local second = launch.build(nil, ctx())
      expect(first:match("ses_[%w]+")).to_be(second:match("ses_[%w]+"))
    end)

    it("reads Claude's resume flag as OpenCode's --session", function()
      expect(launch.translate_args("--resume ses_abc --foo")).to_be("--session ses_abc --foo")
      local cmd = launch.build("--resume ses_abc", ctx())
      assert_contains(cmd, "--session ses_abc")
      assert_not_contains(cmd, "--resume")
    end)

    it("leaves a command that picks its conversation itself alone", function()
      local cmd = launch.build("--continue", ctx())
      assert_not_contains(cmd, "--session")
    end)

    describe("OpenCode's palette in an agent's terminal", function()
      local real_decode

      before_each(function()
        real_decode = vim.json.decode
        vim.json.decode = _G.json_decode
      end)

      after_each(function()
        vim.json.decode = real_decode
      end)

      it("moves off ctrl+p, which switches sessions there", function()
        local _, env = launch.build(nil, ctx({ for_tab = false }))
        assert_contains(env.OPENCODE_CLI_CONFIG_CONTENT, '"command.palette.show":"<leader>p"')
      end)

      it("stays where it is in a tab's terminal, where nothing takes ctrl+p", function()
        local _, env = launch.build(nil, ctx())
        expect(env.OPENCODE_CLI_CONFIG_CONTENT).to_be_nil()
      end)

      it("stays when ctrl+p switches no sessions", function()
        opencode.setup({
          backend = "opencode",
          agents = { keymaps = { next_session = "<C-j>", prev_session = "<C-k>" } },
        })
        local _, env = launch.build(nil, ctx({ for_tab = false }))
        assert_not_contains(env.OPENCODE_CLI_CONFIG_CONTENT, "keybinds")
      end)

      it("follows agent_keybinds: none with false, exactly the table otherwise", function()
        opencode.setup({ backend = "opencode", opencode = { agent_keybinds = false } })
        local _, none = launch.build(nil, ctx({ for_tab = false }))
        assert_not_contains(none.OPENCODE_CLI_CONFIG_CONTENT, "keybinds")
        opencode.setup({ backend = "opencode", opencode = { agent_keybinds = { ["command.palette.show"] = "ctrl+y" } } })
        local _, custom = launch.build(nil, ctx({ for_tab = false }))
        assert_contains(custom.OPENCODE_CLI_CONFIG_CONTENT, '"command.palette.show":"ctrl+y"')
      end)

      it("keeps whatever the variable already held", function()
        local _, env = launch.build(
          nil,
          ctx({
            for_tab = false,
            user_env = { OPENCODE_CLI_CONFIG_CONTENT = '{"theme":"nord","keybinds":{"app.exit":"ctrl+q"}}' },
          })
        )
        local merged = _G.json_decode(env.OPENCODE_CLI_CONFIG_CONTENT)
        expect(merged.theme).to_be("nord")
        expect(merged.keybinds["app.exit"]).to_be("ctrl+q")
        expect(merged.keybinds["command.palette.show"]).to_be("<leader>p")
      end)
    end)

    describe("OpenCode's session tabs in an agent's terminal", function()
      local real_decode

      before_each(function()
        real_decode = vim.json.decode
        vim.json.decode = _G.json_decode
      end)

      after_each(function()
        vim.json.decode = real_decode
      end)

      it("are off, since the Sessions pane lists the conversations", function()
        local _, env = launch.build(nil, ctx({ for_tab = false }))
        expect(_G.json_decode(env.OPENCODE_CLI_CONFIG_CONTENT).tabs.mode).to_be("off")
      end)

      it("are left to the user in a tab's terminal", function()
        local _, env = launch.build(nil, ctx())
        expect(env.OPENCODE_CLI_CONFIG_CONTENT).to_be_nil()
      end)

      it("are left to the user's cli.json with agent_tabs", function()
        opencode.setup({
          backend = "opencode",
          opencode = { agent_tabs = true, agent_keybinds = false },
        })
        local _, env = launch.build(nil, ctx({ for_tab = false }))
        expect(env.OPENCODE_CLI_CONFIG_CONTENT).to_be_nil()
      end)

      it("go off over the tab settings the variable already held, keeping the rest", function()
        local _, env = launch.build(
          nil,
          ctx({
            for_tab = false,
            user_env = { OPENCODE_CLI_CONFIG_CONTENT = '{"tabs":{"mode":"on","layout":"vertical"}}' },
          })
        )
        local merged = _G.json_decode(env.OPENCODE_CLI_CONFIG_CONTENT)
        expect(merged.tabs.mode).to_be("off")
        expect(merged.tabs.layout).to_be("vertical")
      end)
    end)

    it("lets the launch's TUI in through the tokenless door once it runs", function()
      local armed
      local tracked = {}
      package.loaded["claude_agents.opencode.bridge"] = {
        track = function(id, opts)
          tracked[#tracked + 1] = { id = id, opts = opts }
        end,
      }
      local instance = {
        port = 4242,
        server = {
          arm_tokenless = function(on)
            armed = on
          end,
        },
      }
      local cmd = launch.build(nil, ctx({ instance = instance }))
      expect(armed).to_be_nil()
      launch.tab_started(vim.api.nvim_get_current_tabpage(), nil)
      expect(armed).to_be_true()
      expect(tracked[1].id).to_be(cmd:match("ses_[%w]+"))
      expect(tracked[1].opts.kind).to_be("tab")
    end)

    it("records the directory OpenCode ran in once its process starts, not on every rebuild", function()
      local marked = {}
      package.loaded["claude_agents.opencode.bridge"] = { track = function() end }
      package.loaded["claude_agents.opencode.dirs"] = {
        mark = function(dir)
          marked[#marked + 1] = dir
        end,
      }
      launch.build(nil, ctx())
      launch.build(nil, ctx())
      expect(#marked).to_be(0)
      launch.tab_started(vim.api.nvim_get_current_tabpage(), nil)
      launch.tab_started(vim.api.nvim_get_current_tabpage(), nil)
      expect(#marked).to_be(1)
      expect(marked[1]).to_be("/proj")
      package.loaded["claude_agents.opencode.dirs"] = nil
    end)
  end)

  describe("status icons", function()
    it("draws a busy OpenCode conversation with OpenCode's own spinner", function()
      package.loaded["claude_agents.status"] = nil
      local status = require("claude_agents.status")
      status.setup({ status = { icons = { busy = "●" } } })
      local claude_icon = status.icon_for_state("busy", "12345678-1234-1234-1234-123456789abc")
      local oc_icon = status.icon_for_state("busy", "ses_abc")
      expect(claude_icon).to_be("●")
      local is_frame = false
      for _, frame in ipairs(status.OPENCODE_SPINNER) do
        is_frame = is_frame or frame == oc_icon
      end
      assert.is_true(is_frame)
      assert.is_true(status.is_animated("busy", "ses_abc"))
      assert.is_false(status.is_animated("busy", nil))
      -- Other states are drawn like Claude's, unless set for OpenCode.
      expect(status.icon_for_state("idle", "ses_abc")).to_be(status.icon_for_state("idle", nil))
      status.setup({ status = { opencode_icons = { busy = "◇" } } })
      expect(status.icon_for_state("busy", "ses_abc")).to_be("◇")
    end)
  end)
end)
