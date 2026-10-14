require("tests.busted_setup")

-- A review diff's proposal is a scratch buffer named after the diff's tab. That
-- name reached the CLI as the editor context (`⧉ In ✻ [Claude C…) ⧉ (proposed)`)
-- and stayed there after the diff was accepted, since focus then returns to the
-- Claude terminal, which reports nothing.
describe("Selection in a review diff's proposal", function()
  local selection
  local diff
  local sent
  local current_buf

  local FILE = "/home/user/project/cart.py"
  local TAB = "✻ [Claude Code] cart.py (a1b2c3) ⧉"
  local PROPOSAL_BUF, TERMINAL_BUF = 7, 9

  local MODULES =
    { "claudecode", "claudecode.diff", "claudecode.logger", "claudecode.selection", "claudecode.terminal" }
  local saved_modules = {}
  local real_get_current_buf, real_get_mode
  local terminal_bufnr

  before_each(function()
    for _, name in ipairs(MODULES) do
      saved_modules[name] = package.loaded[name]
    end
    vim._mock.reset()

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }
    terminal_bufnr = nil
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_bufnr
      end,
    }
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.selection"] = nil
    diff = require("claudecode.diff")
    selection = require("claudecode.selection")

    sent = {}
    selection.send_selection_update = function(sel)
      sent[#sent + 1] = sel
    end
    selection.state.tracking_enabled = true

    real_get_current_buf = vim.api.nvim_get_current_buf
    real_get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_current_buf = function()
      return current_buf
    end
    vim.api.nvim_get_mode = function()
      return { mode = "n" }
    end

    -- What either provider leaves behind: the proposal, marked with its tab name.
    vim._mock.add_buffer(PROPOSAL_BUF, TAB .. " (proposed)", { "total = 2", "tax = 0" })
    vim.b[PROPOSAL_BUF].claudecode_diff_tab_name = TAB
    vim._mock.add_buffer(TERMINAL_BUF, "term://~/project//4242:claude", { "" })
    diff._register_diff_state(TAB, {
      old_file_path = FILE,
      new_file_path = FILE,
      new_buffer = PROPOSAL_BUF,
      autocmd_ids = {},
      status = "pending",
    })
    current_buf = PROPOSAL_BUF
  end)

  after_each(function()
    vim.api.nvim_get_current_buf = real_get_current_buf
    vim.api.nvim_get_mode = real_get_mode
    selection.state.tracking_enabled = false
    selection.state.latest_selection = nil
    diff._cleanup_all_active_diffs("test teardown")
    for _, name in ipairs(MODULES) do
      package.loaded[name] = saved_modules[name]
    end
  end)

  it("reports the file the proposal is for, not the proposal's name", function()
    selection.update_selection()

    assert.equal(1, #sent)
    assert.equal(FILE, sent[1].filePath)
    assert.equal("file://" .. FILE, sent[1].fileUrl)
  end)

  it("leaves the real file as the context once focus is back in the Claude terminal", function()
    selection.update_selection()
    diff._resolve_diff_as_saved(TAB, PROPOSAL_BUF)

    terminal_bufnr = TERMINAL_BUF
    current_buf = TERMINAL_BUF
    selection.update_selection()

    assert.equal(FILE, selection.get_latest_selection().filePath)
  end)

  it("sends a range selected in the proposal as an at-mention of the file", function()
    local mention
    package.loaded["claudecode"] = {
      get_instance = function()
        return { server = {} }
      end,
      send_at_mention = function(file_path, start_line, end_line)
        mention = { file_path = file_path, start_line = start_line, end_line = end_line }
        return true
      end,
    }

    assert.is_true(selection.send_at_mention_for_visual_selection(1, 2))
    assert.same({ file_path = FILE, start_line = 0, end_line = 1 }, mention)
  end)

  it("reports any other buffer by its own name, a stale proposal mark included", function()
    -- The mark outlived its diff on a buffer something kept: no file to name.
    vim._mock.add_buffer(8, "/home/user/project/notes.md", { "x" })
    vim.b[8].claudecode_diff_tab_name = "✻ [Claude Code] gone.py (ffffff) ⧉"
    current_buf = 8

    selection.update_selection()

    assert.equal("/home/user/project/notes.md", sent[1].filePath)
  end)
end)
