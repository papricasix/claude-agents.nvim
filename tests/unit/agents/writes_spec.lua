-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.writes", function()
  local writes

  before_each(function()
    package.loaded["claude_agents.agents.writes"] = nil
    writes = require("claude_agents.agents.writes")
    writes.reset()
  end)

  it("answers whether a file was written inside a window, both ends included", function()
    writes.note("/proj/a.lua", 1002.5)
    expect(writes.during("/proj/a.lua", 1000, 1005)).to_be_true()
    expect(writes.during("/proj/a.lua", 1002.5, 1002.5)).to_be_true()
    expect(writes.during("/proj/a.lua", 1003, 1005)).to_be_false()
    expect(writes.during("/proj/b.lua", 1000, 1005)).to_be_false()
  end)

  it("keys files the way the panes do, so a separator does not hide a write", function()
    writes.note("/proj/dir/a.lua/", 10)
    expect(writes.during("/proj/dir/a.lua", 0, 20)).to_be_true()
  end)

  it("keeps a bounded number of writes per file, dropping the oldest", function()
    for i = 1, 40 do
      writes.note("/proj/a.lua", i)
    end
    expect(writes.during("/proj/a.lua", 1, 1)).to_be_false()
    expect(writes.during("/proj/a.lua", 40, 40)).to_be_true()
  end)

  it("ignores a write with no file", function()
    writes.note("", 1)
    writes.note(nil, 1)
    expect(writes.during("", 0, 2)).to_be_false()
  end)
end)
