require("tests.busted_setup")

describe("opencode.tools", function()
  local tools

  -- The patch OpenCode 2.0.30 sent with an edit's permission request.
  local PATCH =
    "Index: a.txt\n===================================================================\n--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-hello\n+goodbye\n"

  before_each(function()
    package.loaded["claude_agents.opencode.tools"] = nil
    tools = require("claude_agents.opencode.tools")
  end)

  it("names OpenCode's tools the way Claude does", function()
    expect(tools.name("read")).to_be("Read")
    expect(tools.name("shell")).to_be("Bash")
    expect(tools.name("subagent")).to_be("Task")
    expect(tools.name("question")).to_be("AskUserQuestion")
    expect(tools.name("context7_lookup")).to_be("context7_lookup")
  end)

  it("renames input fields and makes paths absolute against the session's directory", function()
    local input = tools.input("edit", { path = "src/a.lua", oldString = "x", newString = "y" }, "/proj")
    expect(input.file_path).to_be("/proj/src/a.lua")
    expect(input.old_string).to_be("x")
    expect(input.new_string).to_be("y")
    expect(tools.input("read", { filePath = "/abs/b.lua" }, "/proj").file_path).to_be("/abs/b.lua")
    expect(tools.input("subagent", { agent = "explore" }, "/proj").subagent_type).to_be("explore")
  end)

  it("parses a unified patch into Claude's hunks, per file", function()
    local files, order = tools.parse_patch(PATCH)
    expect(order[1]).to_be("a.txt")
    local hunk = files["a.txt"][1]
    expect(hunk.oldStart).to_be(1)
    expect(hunk.newLines).to_be(1)
    expect(hunk.lines[1]).to_be("-hello")
    expect(hunk.lines[2]).to_be("+goodbye")
  end)

  it("ignores the no-newline marker and parses several files", function()
    local patch = table.concat({
      "--- a/x",
      "+++ b/x",
      "@@ -1,2 +1,2 @@",
      " keep",
      "-old",
      "+new",
      "\\ No newline at end of file",
      "--- /dev/null",
      "+++ b/y",
      "@@ -0,0 +1 @@",
      "+fresh",
    }, "\n")
    local files, order = tools.parse_patch(patch)
    expect(#order).to_be(2)
    expect(#files["x"][1].lines).to_be(3)
    expect(files["y"][1].oldLines).to_be(0)
    expect(files["y"][1].newLines).to_be(1)
  end)

  it("applies hunks to rebuild the proposal", function()
    local files = tools.parse_patch(PATCH)
    expect(tools.apply_hunks("hello\n", files["a.txt"])).to_be("goodbye\n")
  end)

  it("applies a hunk in the middle and keeps the rest", function()
    local hunks = {
      { oldStart = 2, oldLines = 1, newStart = 2, newLines = 2, lines = { "-b", "+B", "+B2" } },
    }
    expect(tools.apply_hunks("a\nb\nc\n", hunks)).to_be("a\nB\nB2\nc\n")
  end)

  it("creates a file from an insertion into nothing", function()
    local hunks = { { oldStart = 0, oldLines = 0, newStart = 1, newLines = 2, lines = { "+one", "+two" } } }
    expect(tools.apply_hunks("", hunks)).to_be("one\ntwo\n")
  end)

  it("refuses a patch whose context no longer matches", function()
    local files = tools.parse_patch(PATCH)
    local result, err = tools.apply_hunks("changed\n", files["a.txt"])
    expect(result).to_be_nil()
    assert_contains(err, "line 1")
  end)

  it("counts added and removed lines", function()
    local files = tools.parse_patch(PATCH)
    local added, removed = tools.count(files["a.txt"])
    expect(added).to_be(1)
    expect(removed).to_be(1)
  end)
end)
