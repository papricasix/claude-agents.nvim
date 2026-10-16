require("tests.busted_setup")

describe("opencode.ids", function()
  local ids

  before_each(function()
    package.loaded["claude_agents.opencode.ids"] = nil
    ids = require("claude_agents.opencode.ids")
  end)

  it("builds the time part the way OpenCode does", function()
    -- `ses_eb9c87768ffe…` was created by OpenCode 2.0.30 37 ms before the
    -- creation time it recorded (1792179407036): the id is minted first.
    expect(ids.time_part(1792179407036 - 37, 1)).to_be("eb9c87768ffe")
    expect(ids.time_part(1792179407036 - 37, 2)).to_be("eb9c87768ffd")
  end)

  it("mints ids that sort newest first, as OpenCode's lists expect", function()
    local now = 1792179407000
    ids._now_ms = function()
      return now
    end
    ids._random_bytes = function(n)
      return string.rep("a", n)
    end
    local first = ids.new_session_id()
    now = now + 5
    local second = ids.new_session_id()
    assert.is_truthy(first:match("^ses_%x%x%x%x%x%x%x%x%x%x%x%x[%w]+$"))
    expect(#first).to_be(4 + 12 + 14)
    assert.is_true(second < first)
  end)

  it("counts within one millisecond", function()
    ids._now_ms = function()
      return 1792179407000
    end
    ids._random_bytes = function(n)
      return string.rep("b", n)
    end
    local a = ids.new_session_id()
    local b = ids.new_session_id()
    assert.are_not.equal(a, b)
    assert.is_true(b < a)
  end)
end)
