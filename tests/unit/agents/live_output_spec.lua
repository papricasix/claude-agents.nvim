-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.live_output", function()
  local live
  local clock

  local function setup(own)
    live.setup({ agents = { enabled = true, live_output = own } })
  end

  ---A tap's hello, arriving now.
  local function hello(id, fields)
    local msg = { ev = "hello", id = id, name = "cargo", args = { "test" }, session = "s1", stream = "both" }
    for key, value in pairs(fields or {}) do
      msg[key] = value
    end
    return live.ingest(msg)
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claude_agents.agents.live_output"] = nil
    live = require("claude_agents.agents.live_output")
    clock = 1000
    live._now = function()
      return clock
    end
    live._defer = function(fn)
      fn()
    end
    setup(nil)
  end)

  describe("what it taps", function()
    it("runs only with the agents view switched on, and can be switched off", function()
      live.setup({ agents = { enabled = false } })
      expect(live.is_enabled()).to_be(false)
      setup(false)
      expect(live.is_enabled()).to_be(false)
      setup({ enabled = false })
      expect(live.is_enabled()).to_be(false)
      setup(nil)
      expect(live.is_enabled()).to_be(true)
    end)

    it("takes the built-in commands unless given its own, and only names a shell can carry", function()
      expect(live.commands()[1]).to_be("cargo")
      setup({ commands = { "cargo", "cargo", "my-tool", "rm -rf", "g++", "./gradlew" } })
      expect(table.concat(live.commands(), ",")).to_be("cargo,my-tool")
    end)

    it("knows a command line that runs the program as a word of its own", function()
      expect(live.names("cargo test 2>&1 | grep FAIL", "cargo")).to_be(true)
      expect(live.names("cd crate && cargo build", "cargo")).to_be(true)
      expect(live.names("cargo-nextest run", "cargo")).to_be(false)
      expect(live.names("ls ~/.cargo/bin", "cargo")).to_be(false)
      expect(live.names("npx tsc --noEmit", "tsc")).to_be(true)
      expect(live.names(nil, "cargo")).to_be(false)
    end)
  end)

  describe("the shell files", function()
    it("defines one function per command, leaving the user's own function or alias alone", function()
      local text = live.functions_script("/usr/bin/nvim", "/p/scripts/live_output_tap.lua", { "cargo", "npm" })
      expect(text:find("__claudecode_tap() {", 1, true) ~= nil).to_be(true)
      expect(
        text:find(
          'typeset -f cargo >/dev/null 2>&1 || alias cargo >/dev/null 2>&1 || function cargo { __claudecode_tap cargo "$@"; }',
          1,
          true
        ) ~= nil
      ).to_be(true)
      expect(text:find("function npm {", 1, true) ~= nil).to_be(true)
    end)

    it("taps only a piped stream, and one stream when 2>&1 shares the pipe", function()
      local text = live.functions_script("/usr/bin/nvim", "/tap.lua", { "cargo" })
      expect(text:find("[ -p /dev/stdout ]", 1, true) ~= nil).to_be(true)
      expect(text:find("[ /dev/stdout -ef /dev/stderr ]", 1, true) ~= nil).to_be(true)
      expect(text:find("both 250 20 40", 1, true) ~= nil).to_be(true)
      expect(text:find("out 250 20 40", 1, true) ~= nil).to_be(true)
      expect(text:find("err 250 20 40", 1, true) ~= nil).to_be(true)
      -- A tap that cannot start must not take the command's output with it.
      expect(text:find("2>/dev/null || exec cat)", 1, true) ~= nil).to_be(true)
      expect(text:find("[ ! -x '/usr/bin/nvim' ]", 1, true) ~= nil).to_be(true)
    end)

    it("ends in a zero status, since the CLI runs the command only after it", function()
      local text = live.functions_script("/usr/bin/nvim", "/tap.lua", { "cargo" })
      expect(text:sub(-2)).to_be(":\n")
    end)

    it("quotes paths for sh, a quote in one included", function()
      local text = live.functions_script("/it's/nvim", "/tap.lua", {})
      expect(text:find("'/it'\\''s/nvim'", 1, true) ~= nil).to_be(true)
    end)

    it("sources the user's env file first, and ours only under bash or zsh, last line always succeeding", function()
      local text = live.env_script("/run/tap.sh", "/home/u/.claude-env")
      local lines = vim.split(text:gsub("\n$", ""), "\n")
      expect(lines[2]).to_be("[ ! -r '/home/u/.claude-env' ] || . '/home/u/.claude-env'")
      expect(lines[#lines]).to_be(
        "{ [ -z \"${ZSH_VERSION:-}\" ] && { [ -z \"${BASH_VERSION:-}\" ] || shopt -oq posix; }; } || [ ! -r '/run/tap.sh' ] || . '/run/tap.sh'"
      )
      expect(live.env_script("/run/tap.sh", nil):find(".claude-env", 1, true)).to_be(nil)
    end)

    it("points a launch at its env file, the user's own chained", function()
      local written = {}
      live._write = function(path, text)
        written[path] = text
        return true
      end
      local env = { CLAUDE_ENV_FILE = "/home/u/env.sh" }
      expect(live.launch_env(env)).to_be(true)
      expect(env.CLAUDE_ENV_FILE ~= "/home/u/env.sh").to_be(true)
      expect(written[env.CLAUDE_ENV_FILE]:find("/home/u/env.sh", 1, true) ~= nil).to_be(true)

      setup(false)
      local off = {}
      expect(live.launch_env(off)).to_be(false)
      expect(off.CLAUDE_ENV_FILE).to_be(nil)
    end)
  end)

  describe("matching a tap to its call", function()
    it("takes the newest call of its conversation naming the program, noted before it arrived", function()
      live.note_call("s1", "toolu_old", "cargo build")
      clock = 1001
      live.note_call("s1", "toolu_new", "cargo test 2>&1 | grep FAIL")
      live.note_call("s2", "toolu_other", "cargo test")
      live.note_call("s1", "toolu_ls", "ls")
      clock = 1002
      hello("t1")
      expect(live.get("s1", "toolu_new") ~= nil).to_be(true)
      expect(live.get("s1", "toolu_old")).to_be(nil)
      expect(live.get("s2", "toolu_other")).to_be(nil)
    end)

    it("waits for a call whose hook arrives after the tap", function()
      hello("t1")
      expect(live.get("s1", "toolu_late")).to_be(nil)
      clock = 1000.2
      live.note_call("s1", "toolu_late", "cargo test | tail")
      local got = live.get("s1", "toolu_late")
      expect(got ~= nil).to_be(true)
      expect(got.label).to_be("cargo test")
    end)

    it("does not take a call that had already returned", function()
      live.note_call("s1", "toolu_done", "cargo build")
      live.end_call("toolu_done")
      clock = 1001
      hello("t1")
      expect(live.get("s1", "toolu_done")).to_be(nil)
    end)

    it("keeps a call sent to the background open", function()
      live.note({
        hook_event_name = "PreToolUse",
        tool_name = "Bash",
        tool_use_id = "toolu_bg",
        session_id = "s1",
        tool_input = { command = "cargo build 2>&1 | tail -5", run_in_background = true },
      })
      live.note({
        hook_event_name = "PostToolUse",
        tool_name = "Bash",
        tool_use_id = "toolu_bg",
        session_id = "s1",
        tool_response = { backgroundTaskId = "b123" },
      })
      clock = 1005
      hello("t1")
      expect(live.get("s1", "toolu_bg") ~= nil).to_be(true)
    end)

    it("is given the call from a transcript when no hook noted it, however long ago it started", function()
      hello("t1")
      clock = 1600
      local got = live.get("s1", "toolu_tx", { command = "cargo test 2>&1 | grep -E 'FAIL'", at = 999 })
      expect(got ~= nil).to_be(true)
    end)

    it("ignores hook events for other tools", function()
      live.note({ hook_event_name = "PreToolUse", tool_name = "Read", tool_use_id = "toolu_r", session_id = "s1" })
      expect(live._state.calls.toolu_r).to_be(nil)
    end)
  end)

  describe("what a tap reports", function()
    before_each(function()
      live.note_call("s1", "toolu_1", "cargo test 2>&1 | grep FAIL")
      clock = 1001
      hello("t1")
    end)

    it("hands the views its last lines and counts, and says when it has ended", function()
      live.ingest({ ev = "frame", id = "t1", lines = { "   Compiling a", "   Compiling b" }, total = 2, bytes = 30 })
      local got = live.get("s1", "toolu_1")
      expect(got.running).to_be(true)
      expect(got.total).to_be(2)
      expect(got.lines[2]).to_be("   Compiling b")

      live.ingest({ ev = "bye", id = "t1", lines = { "test result: FAILED" }, total = 900, bytes = 9000 })
      got = live.get("s1", "toolu_1")
      expect(got.running).to_be(false)
      expect(got.total).to_be(900)
    end)

    it("tells listeners which calls moved", function()
      local seen
      live.on_change("spec", function(changed)
        seen = changed
      end)
      live.ingest({ ev = "frame", id = "t1", lines = { "x" }, total = 1 })
      expect(seen.toolu_1).to_be(true)
    end)

    it("refuses a frame from a tap that never said hello", function()
      expect(live.ingest({ ev = "frame", id = "nobody", lines = { "x" } })).to_be(false)
      expect(live.ingest("not a table")).to_be(false)
    end)

    it("ticks the last line with something in it, without escape codes, while running", function()
      live.ingest({ ev = "frame", id = "t1", lines = { "\27[32m   Compiling serde\27[0m", "   " }, total = 2 })
      expect(live.ticker("s1", "toolu_1")).to_be("Compiling serde")
      live.ingest({ ev = "bye", id = "t1", lines = { "done" }, total = 3 })
      expect(live.ticker("s1", "toolu_1")).to_be(nil)
    end)

    it("ticks nothing when the ticker is switched off", function()
      setup({ ticker = false })
      live.ingest({ ev = "frame", id = "t1", lines = { "Compiling" }, total = 1 })
      expect(live.ticker("s1", "toolu_1")).to_be(nil)
    end)

    it("shows the latest of several tapped commands in one call", function()
      live.ingest({ ev = "bye", id = "t1", lines = { "built" }, total = 1 })
      hello("t2", { args = { "test", "--workspace" } })
      live.ingest({ ev = "frame", id = "t2", lines = { "running 3 tests" }, total = 1 })
      local got = live.get("s1", "toolu_1")
      expect(got.label).to_be("cargo test --workspace")
      expect(got.taps).to_be(2)
      expect(got.running).to_be(true)
    end)
  end)
end)
