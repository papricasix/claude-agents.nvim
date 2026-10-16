require("tests.busted_setup")

describe("server: a client let in without the token", function()
  local server_module

  before_each(function()
    package.loaded["claude_agents.server.init"] = nil
    server_module = require("claude_agents.server.init")
  end)

  it("is allowed only while armed, and only one at a time", function()
    local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
    expect(inst.tokenless_allowed({})).to_be_false()
    inst.arm_tokenless(true)
    expect(inst.tokenless_allowed({})).to_be_true()
    -- A client with the token does not count; a tokenless one does.
    expect(inst.tokenless_allowed({ a = { state = "connected" } })).to_be_true()
    expect(inst.tokenless_allowed({ a = { state = "connected", tokenless = true } })).to_be_false()
    -- One that is going no longer holds the place.
    expect(inst.tokenless_allowed({ a = { state = "closing", tokenless = true } })).to_be_true()
    inst.arm_tokenless(false)
    expect(inst.tokenless_allowed({})).to_be_false()
  end)

  it("is offered no tools and may call none", function()
    local inst = server_module.new_instance(1, { instance_id = "tab:1", kind = "tab" })
    inst.register_handlers()
    local handlers = inst.state.handlers
    local listed = handlers["tools/list"]({ tokenless = true }, {})
    expect(#listed.tools).to_be(0)
    local result, err = handlers["tools/call"]({ tokenless = true }, { name = "openFile", arguments = {} })
    expect(result).to_be_nil()
    expect(err.code).to_be(-32601)
  end)
end)
