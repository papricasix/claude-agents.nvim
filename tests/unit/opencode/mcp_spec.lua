-- luacheck: globals expect
require("tests.busted_setup")

-- `open_files` for OpenCode: the HTTP endpoint the service's MCP client calls,
-- the registration that puts it in a directory's server set, and the rules
-- that keep a session to its own Neovim's copy.
describe("opencode open_files endpoint", function()
  local mcp, calls, responses, tracked, opened
  local TOKEN = "0123456789abcdef0123456789abcdef"

  local function post(body, headers)
    local h = { ["x-claude-code-ide-authorization"] = TOKEN }
    for k, v in pairs(headers or {}) do
      h[k] = v
    end
    return mcp.handle_http({ method = "POST", path = "/mcp", headers = h, body = vim.json.encode(body) })
  end

  local function status_of(response)
    return tonumber(response:match("^HTTP/1%.1 (%d+)"))
  end

  local function json_of(response)
    return vim.json.decode(response:match("\r\n\r\n(.*)$"))
  end

  local saved_json

  before_each(function()
    -- The mock's decoder is a stub; this spec reads real bodies.
    saved_json = { encode = vim.json.encode, decode = vim.json.decode }
    vim.json.encode = _G.json_encode
    vim.json.decode = function(text)
      return _G.json_decode(text)
    end
    calls, responses, tracked, opened = {}, {}, {}, {}
    for _, name in ipairs({
      "claude_agents.opencode.mcp",
      "claude_agents.open_files",
      "claude_agents.tools.open_files",
      "claude_agents.tools.init",
    }) do
      package.loaded[name] = nil
    end
    package.loaded["claude_agents.opencode.bridge"] = {
      get = function(id)
        return tracked[id]
      end,
      roots = function()
        local out = {}
        for id, entry in pairs(tracked) do
          if entry.root == id then
            out[#out + 1] = id
          end
        end
        return out
      end,
    }
    package.loaded["claude_agents.opencode"] = {
      canonical = function(dir)
        return dir
      end,
    }
    mcp = require("claude_agents.opencode.mcp")
    mcp._state.port = 4242
    mcp._state.token = TOKEN
    mcp._state.server = {
      is_closing = function()
        return false
      end,
      close = function() end,
    }
    mcp._api = {
      call = function(method, path, opts, cb)
        calls[#calls + 1] = { method = method, path = path, opts = opts }
        local answer = responses[method .. " " .. path]
        if answer == nil then
          cb(nil, {})
        else
          cb(nil, answer)
        end
      end,
    }
    local of = require("claude_agents.open_files")
    of.asker = function(rc)
      return { rc = rc }
    end
    of.open = function(req, asker)
      opened[#opened + 1] = { req = req, asker = asker }
      return { message = "Opened it." }
    end
  end)

  after_each(function()
    vim.json.encode, vim.json.decode = saved_json.encode, saved_json.decode
    package.loaded["claude_agents.opencode.bridge"] = nil
    package.loaded["claude_agents.opencode"] = nil
    package.loaded["claude_agents.opencode.mcp"] = nil
  end)

  describe("HTTP", function()
    it("serves /mcp alone, never to a browser, only with the token", function()
      expect(status_of(mcp.handle_http({ method = "POST", path = "/other", headers = {}, body = "" }))).to_be(404)
      expect(status_of(post({ jsonrpc = "2.0", id = 1, method = "ping" }, { origin = "http://evil" }))).to_be(403)
      expect(
        status_of(post({ jsonrpc = "2.0", id = 1, method = "ping" }, { ["x-claude-code-ide-authorization"] = "nope" }))
      ).to_be(401)
      expect(status_of(mcp.handle_http({ method = "POST", path = "/mcp", headers = {}, body = "{}" }))).to_be(401)
    end)

    it("opens no event stream and ends no session: 405 for anything but POST", function()
      local response = mcp.handle_http({
        method = "GET",
        path = "/mcp",
        headers = { ["x-claude-code-ide-authorization"] = TOKEN },
        body = "",
      })
      expect(status_of(response)).to_be(405)
      expect(response:find("Allow: POST", 1, true) ~= nil).to_be_true()
    end)

    it("answers a request with JSON and a notification with 202", function()
      local response =
        post({ jsonrpc = "2.0", id = 0, method = "initialize", params = { protocolVersion = "2025-11-25" } })
      expect(status_of(response)).to_be(200)
      local reply = json_of(response)
      expect(reply.id).to_be(0)
      expect(reply.result.protocolVersion).to_be("2025-11-25")
      expect(reply.result.capabilities.tools).to_be_table()

      expect(status_of(post({ jsonrpc = "2.0", method = "notifications/initialized" }))).to_be(202)
    end)

    it("refuses a body that is not a JSON-RPC message", function()
      local response = mcp.handle_http({
        method = "POST",
        path = "/mcp",
        headers = { ["x-claude-code-ide-authorization"] = TOKEN },
        body = '"hello"',
      })
      expect(status_of(response)).to_be(400)
    end)

    it("lists open_files", function()
      local reply = json_of(post({ jsonrpc = "2.0", id = 1, method = "tools/list" }))
      expect(reply.result.tools[1].name).to_be("open_files")
    end)
  end)

  describe("tools/call", function()
    local function call(meta)
      return json_of(post({
        jsonrpc = "2.0",
        id = 2,
        method = "tools/call",
        params = { name = "open_files", arguments = { files = { { path = "a.lua" } } }, _meta = meta },
      }))
    end

    it("opens files for the tab or agent the calling session belongs to", function()
      tracked["ses_root"] = { root = "ses_root", tab = 3, kind = "tab", cwd = "/p" }
      tracked["ses_child"] = { root = "ses_root", tab = 3, kind = "agent", cwd = "/p", parent = "ses_root" }
      local reply = call({ ["ai.opencode/sessionID"] = "ses_child" })
      expect(reply.result.isError).to_be_nil()
      expect(reply.result.content[1].text).to_be("Opened it.")
      local rc = opened[1].asker.rc
      expect(rc.tab).to_be(3)
      expect(rc.kind).to_be("agent")
      -- An agent is known by its root conversation.
      expect(rc.session_id).to_be("ses_root")
      expect(opened[1].req.files[1].path).to_be("a.lua")
    end)

    it("refuses a session this Neovim did not launch, or a call naming none", function()
      local reply = call({ ["ai.opencode/sessionID"] = "ses_elsewhere" })
      expect(reply.result.isError).to_be_true()
      expect(#opened).to_be(0)
      reply = call(nil)
      expect(reply.result.isError).to_be_true()
    end)
  end)

  describe("registration", function()
    it("adds a remote server outside code mode, with its token, to one directory", function()
      mcp.register("/p")
      local put = calls[1]
      expect(put.method).to_be("PUT")
      expect(put.path).to_be("/api/experimental/mcp/" .. mcp.server_name())
      expect(put.opts.query["location[directory]"]).to_be("/p")
      local config = put.opts.body.config
      expect(config.type).to_be("remote")
      expect(config.url).to_be("http://127.0.0.1:4242/mcp")
      expect(config.headers["x-claude-code-ide-authorization"]).to_be(TOKEN)
      expect(config.codemode).to_be(false)
      expect(config.oauth).to_be(false)
      expect(mcp._registered()["/p"]).to_be_true()
    end)

    it("leaves a connected server alone and replaces a failed one", function()
      responses["GET /api/mcp"] = { { name = mcp.server_name(), status = { status = "connected" } } }
      mcp.ensure_registered("/p")
      expect(#calls).to_be(1)

      calls = {}
      responses["GET /api/mcp"] = { { name = mcp.server_name(), status = { status = "failed" } } }
      mcp.ensure_registered("/p")
      expect(calls[2] and calls[2].method).to_be("PUT")
    end)

    it("takes the server off a directory once no session of this Neovim runs there", function()
      mcp.register("/p")
      tracked["ses_a"] = { root = "ses_a", cwd = "/p" }
      calls = {}
      mcp.released("/p")
      expect(#calls).to_be(0)
      tracked["ses_a"] = nil
      mcp.released("/p")
      expect(calls[1].method).to_be("DELETE")
      expect(mcp._registered()["/p"]).to_be_nil()
    end)

    it("names every Neovim's tool with one pattern and its own exactly", function()
      local own, any = mcp.actions()
      local rules = require("claude_agents.opencode.rules")
      expect(rules.wildcard(any, own)).to_be_true()
      expect(rules.wildcard(any, "nvim-1234abcd_open_files")).to_be_true()
      expect(rules.wildcard(any, "nvim-lsp_open_files")).to_be_false()
      expect(rules.wildcard(any, "github_open_files")).to_be_false()
    end)
  end)
end)

describe("opencode rules for open_files", function()
  local rules = require("claude_agents.opencode.rules")
  local OWN, ANY = "nvim-aaaaaaaa_open_files", "nvim-????????_open_files"

  it("hides every Neovim's tool, then gives this one's back as the agent decides", function()
    local added = rules.for_tool({ { action = "*", resource = "*", effect = "allow" } }, OWN, ANY)
    expect(added[1].action).to_be(ANY)
    expect(added[1].effect).to_be("deny")
    expect(added[2].action).to_be(OWN)
    expect(added[2].effect).to_be("allow")
  end)

  it("keeps an agent's refusal (explore's `* * deny`)", function()
    local added = rules.for_tool({
      { action = "*", resource = "*", effect = "allow" },
      { action = "*", resource = "*", effect = "deny" },
    }, OWN, ANY)
    expect(added[2].effect).to_be("deny")
    expect(rules.decide({}, OWN)).to_be("ask")
  end)

  it("replaces exactly the tail it added before", function()
    local mine = rules.for_tool({}, OWN, ANY)
    local user = { action = "bash", resource = "rm *", effect = "deny" }
    local current = { user, mine[1], mine[2] }
    local again = rules.replace_tail(current, mine, { { action = "edit", resource = "*", effect = "ask" } })
    expect(#again).to_be(2)
    expect(again[1].action).to_be("bash")
    expect(again[2].action).to_be("edit")
    expect(#rules.strip(current, mine)).to_be(1)
  end)
end)
