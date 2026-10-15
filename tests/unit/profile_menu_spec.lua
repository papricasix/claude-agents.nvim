-- luacheck: globals expect
require("tests.busted_setup")

describe("profile_menu", function()
  local menu
  local profiles
  local checks_asked

  ---Stand in for snacks.win, so the float can be driven without one.
  local function stub_snacks()
    local win = { win = 4242 }
    win.close = function()
      if win.opts and win.opts.on_close then
        win.opts.on_close()
      end
    end
    package.loaded["snacks.win"] = setmetatable({}, {
      __call = function(_, cfg)
        win.opts = cfg
        return win
      end,
    })
    return win
  end

  local function press(buf, lhs)
    local entry = vim._buf_keymaps[buf] and vim._buf_keymaps[buf].n and vim._buf_keymaps[buf].n[lhs]
    assert(entry, "no mapping for " .. lhs)
    entry.rhs()
  end

  ---The line naming a profile.
  local function line_of(lines, name)
    for _, line in ipairs(lines) do
      if line:find(name, 1, true) then
        return line
      end
    end
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["snacks.win"] = nil
    package.loaded["claude_agents.profiles"] = nil
    package.loaded["claude_agents.profile_menu"] = nil
    profiles = require("claude_agents.profiles")
    profiles.setup({})
    checks_asked = {}
    -- Key checks answer only when told to.
    profiles._system = function(argv, callback)
      checks_asked[#checks_asked + 1] = { argv = argv, answer = callback }
    end
    menu = require("claude_agents.profile_menu")
  end)

  after_each(function()
    package.loaded["snacks.win"] = nil
  end)

  describe("render", function()
    it("offers every profile under its key, with what an API one costs", function()
      local lines = menu.render(profiles.list(), {})
      local sub = line_of(lines, "subscription")
      local api = line_of(lines, "API key")
      expect(sub:find("s  subscription", 1, true) ~= nil).to_be_true()
      expect(api:find("a  API key", 1, true) ~= nil).to_be_true()
      expect(api:find("$", 1, true) ~= nil).to_be_true()
      expect(sub:find("$", 1, true)).to_be(nil)
    end)

    it("marks the current profile and adds the caller's word on it", function()
      local lines = menu.render(profiles.list(), { current = "API key", notes = { ["API key"] = "last run" } })
      local api = line_of(lines, "API key")
      expect(api:find("❯", 1, true)).to_be(1)
      expect(api:find("last run", 1, true) ~= nil).to_be_true()
      expect(line_of(lines, "subscription"):find("❯", 1, true)).to_be(nil)
    end)

    it("says whether an API profile's key is there", function()
      expect(line_of(menu.render(profiles.list(), {}), "API key"):find("checking key", 1, true) ~= nil).to_be_true()
      profiles.check(profiles.get("API key"), function() end)
      checks_asked[1].answer({ code = 2, stdout = "missing\n" })
      vim.wait(100, function()
        return profiles.check_state("API key") ~= nil
      end)
      local api = line_of(menu.render(profiles.list(), {}), "API key")
      expect(api:find("no key stored", 1, true) ~= nil).to_be_true()
    end)

    it("reports which line offers which profile", function()
      local _, _, by_line = menu.render(profiles.list(), {})
      expect(by_line[2]).to_be("subscription")
      expect(by_line[3]).to_be("API key")
    end)
  end)

  describe("picking", function()
    it("leaves h, j, k and l to move the cursor", function()
      local win = stub_snacks()
      menu.open({ title = "x", on_pick = function() end })
      for _, lhs in ipairs({ "h", "j", "k", "l" }) do
        expect(vim._buf_keymaps[win.opts.buf].n[lhs]).to_be(nil)
      end
    end)

    it("answers with the profile whose key was pressed, once, and closes", function()
      local win = stub_snacks()
      local picked = {}
      expect(menu.open({
        title = "Start agent as",
        on_pick = function(name)
          picked[#picked + 1] = name
        end,
      })).to_be_true()
      expect(win.opts.title:find("Start agent as", 1, true) ~= nil).to_be_true()
      press(win.opts.buf, "a")
      press(win.opts.buf, "s")
      vim.wait(100, function()
        return #picked > 0
      end)
      expect(#picked).to_be(1)
      expect(picked[1]).to_be("API key")
      expect(menu.is_open()).to_be(false)
    end)

    it("starts the cursor on the current profile and takes the row under it on <CR>", function()
      local picked
      menu.open({
        title = "Resume as",
        current = "API key",
        on_pick = function(name)
          picked = name
        end,
      })
      local win = vim.api.nvim_get_current_win()
      expect(vim.api.nvim_win_get_cursor(win)[1]).to_be(3)
      press(vim.api.nvim_win_get_buf(win), "<CR>")
      vim.wait(100, function()
        return picked ~= nil
      end)
      expect(picked).to_be("API key")
    end)

    it("asks after each API profile's key as it opens, and repaints when it is known", function()
      local win = stub_snacks()
      menu.open({ title = "x", on_pick = function() end })
      expect(#checks_asked).to_be(1)
      expect(checks_asked[1].argv[#checks_asked[1].argv]).to_be("default")
      checks_asked[1].answer({ code = 2, stdout = "missing\n" })
      vim.wait(100, function()
        return profiles.check_state("API key") ~= nil
      end)
      local lines = vim.api.nvim_buf_get_lines(win.opts.buf, 0, -1, false)
      expect(line_of(lines, "API key"):find("no key stored", 1, true) ~= nil).to_be_true()
    end)

    it("toggles: asking again while it is open closes it", function()
      expect(menu.open({ title = "x", on_pick = function() end })).to_be_true()
      expect(menu.open({ title = "x", on_pick = function() end })).to_be(false)
      expect(menu.is_open()).to_be(false)
    end)
  end)
end)
