require("tests.busted_setup")

-- The launch's second MCP server (`open_files`): the same port, on
-- `handshake.TOOLS_PATH`, offered only the tools the model may call.
describe("server: the tool server connection", function()
  local TOKEN = "0123456789abcdef0123456789abcdef"

  local function request(path, token)
    local lines = {
      "GET " .. path .. " HTTP/1.1",
      "Host: 127.0.0.1:8080",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
    }
    if token then
      lines[#lines + 1] = "X-Claude-Code-Ide-Authorization: " .. token
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    return table.concat(lines, "\r\n")
  end

  local handshake

  before_each(function()
    package.loaded["claude_agents.server.handshake"] = nil
    handshake = require("claude_agents.server.handshake")
  end)

  describe("role_of_path", function()
    it("names the tool path, with or without a query or trailing slash", function()
      expect(handshake.role_of_path("/tools")).to_be("tools")
      expect(handshake.role_of_path("/tools/")).to_be("tools")
      expect(handshake.role_of_path("/tools?v=1")).to_be("tools")
    end)

    it("leaves every other path to the IDE connection", function()
      expect(handshake.role_of_path("/")).to_be_nil()
      expect(handshake.role_of_path("/toolsx")).to_be_nil()
      expect(handshake.role_of_path("/x/tools")).to_be_nil()
      expect(handshake.role_of_path(nil)).to_be_nil()
    end)
  end)

  describe("process_handshake", function()
    it("reports the role of a connection that brought the token", function()
      local ok, _, _, tokenless, role = handshake.process_handshake(request("/tools", TOKEN), TOKEN)
      expect(ok).to_be_true()
      expect(tokenless).to_be_nil()
      expect(role).to_be("tools")
    end)

    it("never lets the tool path in through the tokenless door", function()
      local asked = false
      local ok = handshake.process_handshake(request("/tools"), TOKEN, function()
        asked = true
        return true
      end)
      expect(ok).to_be_false()
      expect(asked).to_be_false()
    end)

    it("still opens the tokenless door on the IDE path", function()
      local ok, _, _, tokenless, role = handshake.process_handshake(request("/"), TOKEN, function()
        return true
      end)
      expect(ok).to_be_true()
      expect(tokenless).to_be_true()
      expect(role).to_be_nil()
    end)
  end)

  describe("handlers", function()
    local server_module

    before_each(function()
      package.loaded["claude_agents.server.init"] = nil
      package.loaded["claude_agents.tools.init"] = nil
      package.loaded["claude_agents.tools.open_files"] = nil
      package.loaded["claude_agents.open_files"] = nil
      server_module = require("claude_agents.server.init")
      require("claude_agents.tools.init").register_all()
    end)

    local function names(list)
      local out = {}
      for _, tool in ipairs(list.tools) do
        out[#out + 1] = tool.name
      end
      table.sort(out)
      return out
    end

    it("offers the tool server open_files alone, and the IDE connection none of it", function()
      local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
      inst.register_handlers()
      local handlers = inst.state.handlers

      assert.same({ "open_files" }, names(handlers["tools/list"]({ role = "tools" }, {})))
      local ide = {}
      for _, name in ipairs(names(handlers["tools/list"]({}, {}))) do
        ide[name] = true
      end
      assert.is_nil(ide.open_files)
      assert.is_true(ide.openFile)
    end)

    it("offers a tab's Claude splits and an agent none", function()
      local function layouts(kind)
        local inst = server_module.new_instance(1, { instance_id = kind, kind = kind })
        inst.register_handlers()
        local tool = inst.state.handlers["tools/list"]({ role = "tools" }, {}).tools[1]
        return tool.inputSchema.properties.layout.enum
      end
      assert.same({ "tab", "float", "split", "vsplit" }, layouts("tab"))
      assert.same({ "tab", "float" }, layouts("agent"))
    end)

    it("tells the tool server's client how to annotate, and the IDE connection nothing", function()
      local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
      inst.register_handlers()
      local handlers = inst.state.handlers

      local empty_dict = vim.empty_dict
      vim.empty_dict = empty_dict or function()
        return {}
      end
      local answer = handlers["initialize"]({ role = "tools" }, {})
      local ide_answer = handlers["initialize"]({}, {})
      vim.empty_dict = empty_dict
      expect(answer.instructions:find("open_files", 1, true) ~= nil).to_be_true()
      expect(answer.instructions:find("no separate annotation tool", 1, true) ~= nil).to_be_true()
      expect(ide_answer.instructions).to_be_nil()

      -- A tool search for what users say finds it by its description.
      local tool = handlers["tools/list"]({ role = "tools" }, {}).tools[1]
      expect(tool.description:find("annotate", 1, true) ~= nil).to_be_true()
    end)

    it("answers each connection only from its own tools", function()
      local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
      inst.register_handlers()
      local handlers = inst.state.handlers

      local _, err = handlers["tools/call"]({ role = "tools" }, { name = "openFile", arguments = {} })
      expect(err.code).to_be(-32601)
      _, err = handlers["tools/call"]({}, { name = "open_files", arguments = {} })
      expect(err.code).to_be(-32601)
    end)

    it("turns a refusal into text the model reads, not a protocol error", function()
      local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
      inst.register_handlers()
      local result, err = inst.state.handlers["tools/call"]({ role = "tools" }, { name = "open_files", arguments = {} })
      expect(err).to_be_nil()
      expect(result.isError).to_be_true()
      expect(result.content[1].text:find("files", 1, true) ~= nil).to_be_true()
    end)
  end)

  describe("broadcast", function()
    it("skips the tool server", function()
      local client_module = require("claude_agents.server.client")
      local tcp = require("claude_agents.server.tcp")
      local original = client_module.send_message
      local sent = {}
      client_module.send_message = function(client, message)
        sent[#sent + 1] = client.id
      end

      local server = { clients = { a = { id = "a" }, b = { id = "b", role = "tools" } } }
      tcp.broadcast(server, "{}", function(client)
        return client.role ~= "tools"
      end)
      client_module.send_message = original

      assert.same({ "a" }, sent)
    end)
  end)
end)

describe("open_files.mcp_config", function()
  local open_files

  before_each(function()
    package.loaded["claude_agents.open_files"] = nil
    open_files = require("claude_agents.open_files")
  end)

  after_each(function()
    package.loaded["claude_agents"] = nil
  end)

  it("points the CLI at this instance's port, on the tool path, with its token", function()
    local config = open_files.mcp_config({ port = 41234, auth_token = "tok" })
    assert.same({
      mcpServers = {
        nvim = {
          type = "ws",
          url = "ws://127.0.0.1:41234/tools",
          headers = { ["x-claude-code-ide-authorization"] = "tok" },
        },
      },
    }, config)
  end)

  it("takes its name from the config, and adds nothing when switched off or without a server", function()
    package.loaded["claude_agents"] = { state = { config = { open_files = { server_name = "editor" } } } }
    local config = open_files.mcp_config({ port = 1, auth_token = "tok" })
    expect(config.mcpServers.editor).to_be_table()

    expect(open_files.mcp_config({ port = nil, auth_token = "tok" })).to_be_nil()
    package.loaded["claude_agents"] = { state = { config = { open_files = { enabled = false } } } }
    expect(open_files.mcp_config({ port = 1, auth_token = "tok" })).to_be_nil()
  end)

  it("mentions notes in the server's instructions only while they are on", function()
    expect(open_files.instructions():find("notes", 1, true) ~= nil).to_be_true()

    package.loaded["claude_agents"] = { state = { config = { open_files = { notes = { enabled = false } } } } }
    local text = open_files.instructions()
    expect(text:find("open_files", 1, true) ~= nil).to_be_true()
    expect(text:find("notes", 1, true)).to_be_nil()

    package.loaded["claude_agents"] = { state = { config = { open_files = { enabled = false } } } }
    expect(open_files.instructions()).to_be_nil()
  end)
end)
