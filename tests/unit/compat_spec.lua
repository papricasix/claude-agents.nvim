-- luacheck: globals expect
require("tests.busted_setup")

describe("claude_agents.compat", function()
  -- Loaded once: a reloaded module would install a second loader whose
  -- warned-once state the first one, earlier in the list, never sees.
  local compat = require("claude_agents.compat")
  local notes
  local real_notify, real_schedule

  before_each(function()
    notes = {}
    real_notify, real_schedule = vim.notify, vim.schedule
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    vim.schedule = function(fn)
      fn()
    end
    package.preload["claude_agents.fake"] = function()
      return { name = "fake" }
    end
    package.loaded["claude_agents.fake"] = nil
    package.loaded["claudecode.fake"] = nil
    compat._reset()
    compat.install()
  end)

  after_each(function()
    vim.notify, vim.schedule = real_notify, real_schedule
    package.preload["claude_agents.fake"] = nil
    package.loaded["claude_agents.fake"] = nil
    package.loaded["claudecode.fake"] = nil
  end)

  it("maps the old module names onto the new ones", function()
    expect(compat.new_name("claudecode")).to_be("claude_agents")
    expect(compat.new_name("claudecode.status")).to_be("claude_agents.status")
    expect(compat.new_name("claudecode.agents.float")).to_be("claude_agents.agents.float")
    -- Only the module itself and its children: not a module that merely starts
    -- with the same letters.
    expect(compat.new_name("claudecode_extra")).to_be(nil)
    expect(compat.new_name("claude_agents.status")).to_be(nil)
  end)

  it("hands out the same table under the old name as under the new one", function()
    local old = require("claudecode.fake")
    expect(old).to_be(require("claude_agents.fake"))
    expect(old.name).to_be("fake")
  end)

  it("warns once, naming the module to require instead", function()
    require("claudecode.fake")
    package.loaded["claudecode.fake"] = nil
    require("claudecode.fake")
    expect(#notes).to_be(1)
    expect(notes[1].level).to_be(vim.log.levels.WARN)
    expect(notes[1].msg:find('"claude_agents"', 1, true) ~= nil).to_be_true()
  end)

  it("answers a package.loaded lookup by the old name with the loaded module", function()
    -- A save hook checks package.loaded to act only when the module is in
    -- use; that lookup never reaches a loader.
    expect(package.loaded["claudecode.fake"]).to_be(nil)
    local mod = require("claude_agents.fake")
    expect(package.loaded["claudecode.fake"]).to_be(mod)
    expect(#notes).to_be(1)
    -- Answered, not stored: the old key stays absent from the table itself.
    expect(rawget(package.loaded, "claudecode.fake")).to_be(nil)
  end)

  it("leaves package.loaded lookups of other names alone", function()
    expect(package.loaded["claudecode_unrelated"]).to_be(nil)
    expect(package.loaded["string"]).to_be(string)
    expect(#notes).to_be(0)
  end)

  it("installs its loader only once", function()
    local loaders = package.loaders
    local before = #loaders
    compat.install()
    compat.install()
    expect(#loaders).to_be(before)
  end)
end)
