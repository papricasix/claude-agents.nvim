require("tests.busted_setup")

-- Selection tracking reports nothing from an agent's terminal. An OpenCode
-- terminal used to be told apart only by "opencode" in its buffer name, so one
-- started through a wrapper or alias (`opencode.cmd`) reported its own scrollback
-- as the editor selection.
describe("Selection in an agent terminal", function()
  local selection
  local sent
  local current_buf

  local FILE_BUF, TERMINAL_BUF = 3, 9

  local MODULES = {
    "claude_agents",
    "claude_agents.logger",
    "claude_agents.selection",
    "claude_agents.terminal",
  }
  local saved_modules = {}
  local real_get_current_buf, real_get_mode

  before_each(function()
    for _, name in ipairs(MODULES) do
      saved_modules[name] = package.loaded[name]
    end
    vim._mock.reset()

    package.loaded["claude_agents.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }
    package.loaded["claude_agents.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
    }
    package.loaded["claude_agents.selection"] = nil
    selection = require("claude_agents.selection")

    sent = {}
    selection.send_selection_update = function(sel)
      sent[#sent + 1] = sel
    end
    selection.state.tracking_enabled = true
    selection.state.latest_selection = nil

    real_get_current_buf = vim.api.nvim_get_current_buf
    real_get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_current_buf = function()
      return current_buf
    end
    vim.api.nvim_get_mode = function()
      return { mode = "n" }
    end

    vim._mock.add_buffer(FILE_BUF, "/home/user/project/cart.py", { "total = 2" })
  end)

  after_each(function()
    vim.api.nvim_get_current_buf = real_get_current_buf
    vim.api.nvim_get_mode = real_get_mode
    selection.state.tracking_enabled = false
    selection.state.latest_selection = nil
    for _, name in ipairs(MODULES) do
      package.loaded[name] = saved_modules[name]
    end
  end)

  it("skips a terminal stamped as OpenCode's whose name does not say so", function()
    vim._mock.add_buffer(TERMINAL_BUF, "term://~/project//4242:oc-wrapper", { "" })
    vim.b[TERMINAL_BUF].claudecode_backend = "opencode"
    current_buf = TERMINAL_BUF

    selection.update_selection()

    assert.equal(0, #sent)
  end)

  it("still skips a terminal named after the agent CLI", function()
    for _, name in ipairs({ "term://~/project//4242:claude", "term://~/project//4242:opencode" }) do
      vim._mock.add_buffer(TERMINAL_BUF, name, { "" })
      current_buf = TERMINAL_BUF

      selection.update_selection()

      assert.equal(0, #sent)
    end
  end)

  it("reports an ordinary file", function()
    current_buf = FILE_BUF

    selection.update_selection()

    assert.equal(1, #sent)
    assert.equal("/home/user/project/cart.py", sent[1].filePath)
  end)
end)
