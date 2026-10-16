require("tests.busted_setup")

describe("opencode.rules", function()
  local rules

  -- The effective rulesets OpenCode 2.0.30 reports for its shipped agents.
  local BASE = {
    { action = "*", resource = "*", effect = "allow" },
    { action = "read", resource = "*.env", effect = "ask" },
    { action = "read", resource = "*.env.*", effect = "ask" },
    { action = "read", resource = "*.env.example", effect = "allow" },
  }
  local function with(extra)
    local out = vim.deepcopy(BASE)
    for _, rule in ipairs(extra) do
      out[#out + 1] = rule
    end
    return out
  end
  local BUILD = with({ { action = "question", resource = "*", effect = "allow" } })
  local PLAN = with({
    { action = "question", resource = "*", effect = "allow" },
    { action = "edit", resource = "*", effect = "deny" },
    { action = "edit", resource = "/home/u/.opencode/plan/*", effect = "allow" },
  })
  local EXPLORE = with({
    { action = "*", resource = "*", effect = "deny" },
    { action = "read", resource = "*", effect = "allow" },
    { action = "shell", resource = "*", effect = "allow" },
  })

  ---What OpenCode decides for an edit: the agent's rules, then the session's.
  local function decide(agent_rules, session_rules, path)
    local all = vim.deepcopy(agent_rules)
    for _, rule in ipairs(session_rules) do
      all[#all + 1] = rule
    end
    return rules.evaluate(all, path)
  end

  before_each(function()
    package.loaded["claude_agents.opencode.rules"] = nil
    rules = require("claude_agents.opencode.rules")
  end)

  it("matches whole values with * and ?", function()
    assert.is_true(rules.wildcard("*", "src/a.lua"))
    assert.is_true(rules.wildcard("src/*.lua", "src/deep/a.lua"))
    assert.is_true(rules.wildcard("a?c", "abc"))
    assert.is_false(rules.wildcard("a?c", "abbc"))
    assert.is_false(rules.wildcard("src/*", "lib/src/a"))
    assert.is_true(rules.wildcard("a.b(c)", "a.b(c)"))
  end)

  it("makes the build agent ask before every edit", function()
    local session = rules.compose({}, nil, BUILD)
    expect(decide(BUILD, session, "src/a.lua")).to_be("ask")
  end)

  it("keeps the plan agent's refusals, and its plan files unasked", function()
    local session = rules.compose({}, nil, PLAN)
    expect(decide(PLAN, session, "src/a.lua")).to_be("deny")
    expect(decide(PLAN, session, "/home/u/.opencode/plan/p.md")).to_be("allow")
  end)

  it("keeps a read-only agent read-only, without touching its other actions", function()
    local session = rules.compose({}, nil, EXPLORE)
    expect(decide(EXPLORE, session, "src/a.lua")).to_be("deny")
    for _, rule in ipairs(session) do
      expect(rule.action).to_be("edit")
    end
  end)

  it("keeps a user's own path rules deciding their paths", function()
    local agent = with({
      { action = "edit", resource = "secrets/*", effect = "deny" },
      { action = "edit", resource = "docs/*", effect = "allow" },
    })
    local session = rules.compose({}, nil, agent)
    expect(decide(agent, session, "secrets/key")).to_be("deny")
    expect(decide(agent, session, "docs/a.md")).to_be("allow")
    expect(decide(agent, session, "src/a.lua")).to_be("ask")
  end)

  it("replaces exactly what it added last time, keeping the session's own rules ahead", function()
    local own = { { action = "shell", resource = "rm *", effect = "deny" } }
    local first, added = rules.compose(own, nil, BUILD)
    local second, again = rules.compose(first, added, PLAN)
    expect(second[1].action).to_be("shell")
    expect(#second).to_be(1 + #again)
    expect(decide(PLAN, second, "src/a.lua")).to_be("deny")
  end)

  it("leaves rules it did not add when they no longer end the list", function()
    local foreign =
      { { action = "edit", resource = "*", effect = "ask" }, { action = "x", resource = "*", effect = "allow" } }
    local composed = rules.compose(foreign, { { action = "edit", resource = "*", effect = "ask" } }, BUILD)
    expect(#composed).to_be(3)
  end)

  it("strips its rules when review is turned off", function()
    local own = { { action = "shell", resource = "rm *", effect = "deny" } }
    local composed, added = rules.compose(own, nil, PLAN)
    local stripped = rules.strip(composed, added)
    expect(#stripped).to_be(1)
    expect(stripped[1].action).to_be("shell")
  end)
end)
