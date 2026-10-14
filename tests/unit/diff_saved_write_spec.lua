require("tests.busted_setup")

-- An accepted diff and the file it was for, across Claude's write. Claude sends
-- close_tab before it writes the file (read from CLI 2.1.299: the diff helper
-- fires close_tab without awaiting it, and the Edit tool writes afterwards), so
-- close_tab must not put the file's buffer back while it still holds the old
-- text: that frame is what the window showed between `:w` and the reload.
describe("Accepted diff waiting for Claude's write", function()
  local diff
  local path
  local clock
  local tab_name = "✻ [Claude Code] cart.py (a1b2c3) ⧉"

  local FILE_BUF, PROPOSAL_BUF, WIN = 1, 2, 1000

  -- Modules and API functions the spec replaces, put back after each test so
  -- nothing leaks into the next spec file in this busted process.
  local saved_modules = {}
  local real_cmd, real_buf_call
  local MODULES = { "claudecode.diff", "claudecode.logger", "claudecode.terminal" }

  local function write_file(text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local function lines_on_disk(file)
    local f = io.open(file, "rb")
    if not f then
      return {}
    end
    local text = f:read("*a")
    f:close()
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
    return lines
  end

  ---The text a window shows.
  local function shown(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  end

  ---The unified provider's shape: the proposal took over the window that showed
  ---the file, and the file's buffer is what comes back when the diff goes.
  local function open_unified_diff()
    vim._mock.add_buffer(FILE_BUF, path, { "total = 1" }, { modified = false })
    vim._mock.add_buffer(PROPOSAL_BUF, tab_name .. " (proposed)", { "total = 2" }, { eol = true })
    vim._mock.add_window(WIN, PROPOSAL_BUF, { 1, 0 })
    vim._win_tab[WIN] = 1
    vim._tab_windows[1] = { WIN }
    local answer = {}
    diff._register_diff_state(tab_name, {
      old_file_path = path,
      new_file_path = path,
      new_buffer = PROPOSAL_BUF,
      new_window = nil,
      target_window = WIN,
      target_window_created_by_plugin = false,
      pre_diff_buffer = FILE_BUF,
      original_cursor_pos = { 1, 0 },
      original_tab_number = 1,
      created_new_tab = false,
      autocmd_ids = {},
      status = "pending",
      resolution_callback = function(result)
        answer.result = result
      end,
      is_new_file = false,
      provider = "unified",
    })
    return answer
  end

  ---What Claude writes: the text FILE_SAVED carried.
  local function claude_writes(answer)
    write_file(answer.result.content[2].text)
  end

  before_each(function()
    for _, name in ipairs(MODULES) do
      saved_modules[name] = package.loaded[name]
    end

    vim._mock.reset()
    vim._tabs = { [1] = true }
    vim._current_tabpage = 1
    vim._current_window = WIN
    vim._next_winid = 1001

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }
    -- No Claude terminal on screen, so the teardown moves focus nowhere.
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
    }
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
    diff.setup({ diff_opts = { layout = "vertical", open_in_new_tab = false }, terminal = {} })

    clock = 0
    diff._io.now = function()
      return clock
    end

    path = os.tmpname()
    write_file("total = 1\n")

    -- `:edit` re-reads the buffer it runs for from disk, as Neovim's does. The
    -- mock's nvim_buf_call changes no context, so the buffer is tracked here.
    local context_buf
    real_buf_call = vim.api.nvim_buf_call
    vim.api.nvim_buf_call = function(buf, fn)
      local outer = context_buf
      context_buf = buf
      local ok, result = pcall(real_buf_call, buf, fn)
      context_buf = outer
      if not ok then
        error(result)
      end
      return result
    end
    real_cmd = vim.cmd
    vim.cmd = function(command)
      if command == "edit" then
        local buf = context_buf or vim._windows[vim._current_window].buf
        vim._buffers[buf].lines = lines_on_disk(vim._buffers[buf].name)
        return
      end
      return real_cmd(command)
    end
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test teardown")
    vim.cmd = real_cmd
    vim.api.nvim_buf_call = real_buf_call
    os.remove(path)
    for _, name in ipairs(MODULES) do
      package.loaded[name] = saved_modules[name]
    end
  end)

  it("keeps the accepted text on screen when close_tab comes before the write", function()
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.equal("FILE_SAVED", answer.result.content[1].text)

    -- Claude's order: close_tab, then the write. Until the write the file's
    -- buffer holds "total = 1", so it must not be what the window shows.
    assert.is_true(diff.close_diff_by_tab_name(tab_name))
    assert.same({ "total = 2" }, shown(WIN))
    diff._poll_saved_writes()
    assert.same({ "total = 2" }, shown(WIN))
    assert.is_table(diff._get_active_diffs()[tab_name])

    claude_writes(answer)
    diff._poll_saved_writes()

    -- Taken down and reloaded in the same call, so no frame in between.
    assert.equal(FILE_BUF, vim.api.nvim_win_get_buf(WIN))
    assert.same({ "total = 2" }, shown(WIN))
    assert.is_false(vim.api.nvim_buf_is_valid(PROPOSAL_BUF))
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)

  it("takes the view down at once when the write landed before close_tab", function()
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    claude_writes(answer)

    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    assert.equal(FILE_BUF, vim.api.nvim_win_get_buf(WIN))
    assert.same({ "total = 2" }, shown(WIN))
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)

  it("recognises the write of a CRLF file, whose proposal held LF text", function()
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    write_file((answer.result.content[2].text:gsub("\n", "\r\n")))
    diff._poll_saved_writes()

    assert.is_nil(diff._get_active_diffs()[tab_name])
    assert.equal(FILE_BUF, vim.api.nvim_win_get_buf(WIN))
  end)

  it("takes a change to the file that has held still for a poll as the write", function()
    -- Text it cannot recognise (an encoding Claude converted to, say): only the
    -- file's size, mtime and inode say it was written.
    local signature = "before"
    diff._io.signature = function()
      return signature
    end
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    write_file("\239\187\191" .. answer.result.content[2].text)
    signature = "after"
    diff._poll_saved_writes()
    -- Changed, but possibly mid-write: not yet.
    assert.is_table(diff._get_active_diffs()[tab_name])

    diff._poll_saved_writes()
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)

  it("stops waiting after the timeout and shows what is on disk", function()
    open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    clock = diff._write_timeout_ms - 1
    diff._poll_saved_writes()
    assert.is_table(diff._get_active_diffs()[tab_name])

    -- Claude never wrote: the file is shown as it is.
    clock = diff._write_timeout_ms
    diff._poll_saved_writes()
    assert.is_nil(diff._get_active_diffs()[tab_name])
    assert.equal(FILE_BUF, vim.api.nvim_win_get_buf(WIN))
    assert.same({ "total = 1" }, shown(WIN))
  end)

  it("leaves the file's buffer alone when it holds the user's unsaved edits", function()
    local answer = open_unified_diff()
    vim._buffers[FILE_BUF].lines = { "total = 1 -- mine" }
    vim.bo[FILE_BUF].modified = true
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    claude_writes(answer)
    diff._poll_saved_writes()

    assert.equal(FILE_BUF, vim.api.nvim_win_get_buf(WIN))
    assert.same({ "total = 1 -- mine" }, shown(WIN))
  end)

  it("treats a second close for a waiting diff as the same one", function()
    -- closeAllDiffTabs can name a diff close_tab already did.
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))
    assert.equal(1, diff.close_all_diffs("closeAllDiffTabs"))
    assert.same({ "total = 2" }, shown(WIN))

    claude_writes(answer)
    diff._poll_saved_writes()
    assert.is_nil(diff._get_active_diffs()[tab_name])
    assert.same({ "total = 2" }, shown(WIN))
    -- Nothing left waiting to act a second time.
    diff._poll_saved_writes()
    assert.same({ "total = 2" }, shown(WIN))
  end)

  it("takes a waiting diff down before a new one picks a window, and reloads once written", function()
    local answer = open_unified_diff()
    diff._resolve_diff_as_saved(tab_name, PROPOSAL_BUF)
    assert.is_true(diff.close_diff_by_tab_name(tab_name))

    -- The new diff's setup records what it finds; the provider is irrelevant.
    local found
    diff._resolve_provider = function()
      return "native"
    end
    diff._setup_blocking_diff = function()
      found = { waiting = diff._get_active_diffs()[tab_name], buf = vim.api.nvim_win_get_buf(WIN) }
    end
    local co = coroutine.create(function()
      diff.open_diff_blocking(path, path, "total = 3\n", "✻ [Claude Code] cart.py (d4e5f6) ⧉", "client")
    end)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))

    -- The window it would pick no longer holds the waiting diff's proposal.
    assert.is_nil(found.waiting)
    assert.equal(FILE_BUF, found.buf)

    -- Not written yet, so not reloaded yet; once written, it is.
    assert.same({ "total = 1" }, shown(WIN))
    claude_writes(answer)
    diff._poll_saved_writes()
    assert.same({ "total = 2" }, shown(WIN))
  end)

  it("keeps the native side-by-side diff up until the write, then closes it onto the new text", function()
    vim._mock.add_buffer(FILE_BUF, "/home/user/project/other.lua", { "x" }, { modified = false })
    vim._mock.add_window(WIN, FILE_BUF, { 1, 0 })
    vim._win_tab[WIN] = 1
    vim._tab_windows[1] = { WIN }
    vim.cmd("edit " .. path)

    local answer = {}
    diff._setup_blocking_diff({
      old_file_path = path,
      new_file_path = path,
      new_file_contents = "total = 2\n",
      tab_name = tab_name,
    }, function(result)
      answer.result = result
    end)
    local state = diff._get_active_diffs()[tab_name]
    local file_buf = vim.api.nvim_win_get_buf(state.target_window)
    diff._resolve_diff_as_saved(tab_name, state.new_buffer)

    assert.is_true(diff.close_diff_by_tab_name(tab_name))
    -- The proposal stays beside the file until Claude has written it.
    assert.is_true(vim.api.nvim_win_is_valid(state.new_window))

    claude_writes(answer)
    diff._poll_saved_writes()

    assert.is_false(vim.api.nvim_win_is_valid(state.new_window))
    assert.equal(file_buf, vim.api.nvim_win_get_buf(state.target_window))
    assert.same({ "total = 2" }, shown(state.target_window))
  end)
end)
