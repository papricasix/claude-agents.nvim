-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.live_panel", function()
  local panel, live

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    for _, name in ipairs({
      "claude_agents.agents.live_panel",
      "claude_agents.agents.live_output",
      "claude_agents.agents.ansi",
    }) do
      package.loaded[name] = nil
    end
    live = require("claude_agents.agents.live_output")
    live._defer = function(fn)
      fn()
    end
    live.setup({ agents = { enabled = true } })
    panel = require("claude_agents.agents.live_panel")
  end)

  local function out(fields)
    local o = { label = "cargo test", lines = { "a", "b" }, total = 1204, bytes = 1, running = true, taps = 1 }
    for key, value in pairs(fields or {}) do
      o[key] = value
    end
    return o
  end

  it("names the command and how much it printed, then its last lines and a blank", function()
    local lines = panel.build(out())
    expect(lines[1]:find("── cargo test · before the pipe · 1,204 lines ", 1, true)).to_be(1)
    expect(lines[2]).to_be("a")
    expect(lines[3]).to_be("b")
    expect(lines[4]).to_be("")
    expect(#lines).to_be(4)
    expect(panel.build(out({ total = 1 }))[1]:find("· 1 line ", 1, true) ~= nil).to_be(true)
  end)

  it("takes no lines until there is output", function()
    expect(#panel.build(nil)).to_be(0)
    expect(#panel.build(out({ lines = {} }))).to_be(0)
  end)

  it("draws escape codes as colour, not as text", function()
    local lines, marks = panel.build(out({ lines = { "\27[31merror\27[0m: oops" } }))
    expect(lines[2]).to_be("error: oops")
    local coloured = false
    for _, mark in ipairs(marks) do
      if mark.row == 1 and mark.col == 0 and mark.end_col == 5 then
        coloured = true
      end
    end
    expect(coloured).to_be(true)
  end)

  it("gives a transcript the same panel as quiet virtual lines", function()
    local virt = panel.virt_lines(out(), "  ")
    expect(#virt).to_be(3)
    expect(virt[1][1][1]:find("  ── cargo test", 1, true)).to_be(1)
    expect(virt[3][1][1]).to_be("  b")
    expect(panel.virt_lines(nil)).to_be(nil)
  end)

  it("keeps a buffer's panel current and says how many rows it took", function()
    -- The mock replaces the whole buffer whatever the range; a panel writes a
    -- few rows in the middle of one.
    local real_set_lines = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(b, first, last, _, replacement)
      local current = vim._buffers[b] and vim._buffers[b].lines or {}
      if last < 0 then
        last = #current + 1 + last
      end
      local spliced = {}
      for i = 1, first do
        spliced[#spliced + 1] = current[i]
      end
      for _, line in ipairs(replacement or {}) do
        spliced[#spliced + 1] = line
      end
      for i = last + 1, #current do
        spliced[#spliced + 1] = current[i]
      end
      vim._buffers[b] = vim._buffers[b] or { options = {} }
      vim._buffers[b].lines = spliced
    end
    finally(function()
      vim.api.nvim_buf_set_lines = real_set_lines
    end)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$ cargo test | grep x", "", "── output ──" })
    local deltas = {}
    live.note_call("s1", "toolu_1", "cargo test | grep x")
    local handle = panel.attach(buf, {
      row = 2,
      session_id = "s1",
      tool_id = "toolu_1",
      on_resize = function(delta)
        deltas[#deltas + 1] = delta
      end,
    })
    expect(handle.rows).to_be(0)
    expect(#vim.api.nvim_buf_get_lines(buf, 0, -1, false)).to_be(3)

    live.ingest({ ev = "hello", id = "t1", name = "cargo", args = { "test" }, session = "s1" })
    live.ingest({ ev = "frame", id = "t1", lines = { "Compiling a" }, total = 1 })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect(lines[3]:find("── cargo test · before the pipe", 1, true)).to_be(1)
    expect(lines[4]).to_be("Compiling a")
    expect(lines[6]).to_be("── output ──")
    expect(deltas[1]).to_be(3)

    live.ingest({ ev = "frame", id = "t1", lines = { "Compiling a", "Compiling b" }, total = 2 })
    expect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[5]).to_be("Compiling b")
    expect(deltas[2]).to_be(1)
    expect(handle.rows).to_be(4)
  end)
end)
