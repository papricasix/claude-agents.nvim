require("tests.busted_setup")

describe("opencode.review", function()
  local review
  local opened, finished, dismissed, replies, files, written

  local PATCH = "--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-hello\n+goodbye\n"

  local function asked(id, file_list)
    return {
      id = id or "per_1",
      sessionID = "ses_root",
      action = "edit",
      metadata = { files = file_list or { { file = "a.txt", patch = PATCH, status = "modified" } } },
    }
  end
  local ENTRY = { root = "ses_root", tab = 1, cwd = "/proj", kind = "tab", instance = { id = "tab:1" } }

  before_each(function()
    opened, finished, dismissed, replies, written = {}, {}, {}, {}, {}
    files = { ["/proj/a.txt"] = "hello\n", ["/proj/b.txt"] = "one\n" }
    package.loaded["claude_agents.opencode"] = nil
    require("claude_agents.opencode").setup({})
    package.loaded["claude_agents.opencode.review"] = nil
    review = require("claude_agents.opencode.review")
    review._io = {
      read = function(path)
        return files[path]
      end,
      write = function(path, data)
        written[path] = data
        return true
      end,
    }
    review._api = {
      reply_permission = function(session_id, request_id, decision, message, cb)
        replies[#replies + 1] =
          { session_id = session_id, request_id = request_id, decision = decision, message = message }
        if cb then
          cb(nil)
        end
      end,
    }
    review._diff = function()
      return {
        open_review = function(params, on_result)
          opened[#opened + 1] = { params = params, answer = on_result }
          return true
        end,
        finish_review = function(tab_name)
          finished[#finished + 1] = tab_name
        end,
        dismiss_review = function(tab_name)
          dismissed[#dismissed + 1] = tab_name
        end,
      }
    end
  end)

  it("shows the proposal OpenCode's patch makes of the file on disk", function()
    review.asked(asked(), ENTRY)
    expect(#opened).to_be(1)
    expect(opened[1].params.old_file_path).to_be("/proj/a.txt")
    expect(opened[1].params.new_file_contents).to_be("goodbye\n")
    assert_contains(opened[1].params.tab_name, "[OpenCode]")
  end)

  it("lets the edit through when it is accepted as proposed", function()
    review.asked(asked(), ENTRY)
    opened[1].answer({ saved = true, content = "goodbye\n" })
    expect(replies[1].decision).to_be("once")
    expect(next(written)).to_be_nil()
    expect(finished[1]).to_be(opened[1].params.tab_name)
  end)

  it("rejects the edit when the diff is closed", function()
    review.asked(asked(), ENTRY)
    opened[1].answer({ saved = false })
    expect(replies[1].decision).to_be("reject")
    expect(replies[1].message).to_be(review.REJECTED)
  end)

  it("writes the user's own version and tells the model, when the proposal was changed", function()
    review.asked(asked(), ENTRY)
    opened[1].answer({ saved = true, content = "farewell\n" })
    expect(written["/proj/a.txt"]).to_be("farewell\n")
    expect(replies[1].decision).to_be("reject")
    assert_contains(replies[1].message, "changes of their own")
    assert_contains(replies[1].message, "/proj/a.txt")
  end)

  it("answers a request over several files only once every file is answered", function()
    review.asked(
      asked("per_2", {
        { file = "a.txt", patch = PATCH },
        { file = "b.txt", patch = "--- b.txt\n+++ b.txt\n@@ -1,1 +1,1 @@\n-one\n+two\n" },
      }),
      ENTRY
    )
    expect(#opened).to_be(2)
    opened[1].answer({ saved = true, content = "goodbye\n" })
    expect(#replies).to_be(0)
    opened[2].answer({ saved = true, content = "two\n" })
    expect(replies[1].decision).to_be("once")
  end)

  it("rejects at the first file closed, and takes the others down", function()
    review.asked(
      asked("per_3", {
        { file = "a.txt", patch = PATCH },
        { file = "b.txt", patch = "--- b.txt\n+++ b.txt\n@@ -1,1 +1,1 @@\n-one\n+two\n" },
      }),
      ENTRY
    )
    opened[2].answer({ saved = false })
    expect(replies[1].decision).to_be("reject")
    expect(dismissed[1]).to_be(opened[1].params.tab_name)
  end)

  it("takes the diffs down unanswered when OpenCode's own prompt was answered first", function()
    review.asked(asked(), ENTRY)
    review.replied({ sessionID = "ses_root", requestID = "per_1", reply = "once" })
    expect(dismissed[1]).to_be(opened[1].params.tab_name)
    expect(#replies).to_be(0)
  end)

  it("leaves a proposal it cannot rebuild to OpenCode's own prompt", function()
    files["/proj/a.txt"] = "something else\n"
    review.asked(asked(), ENTRY)
    expect(#opened).to_be(0)
  end)

  it("opens nothing with review off, or for anything but an edit", function()
    require("claude_agents.opencode").setup({ opencode = { review_edits = false } })
    review.asked(asked(), ENTRY)
    require("claude_agents.opencode").setup({})
    local shell = asked("per_9")
    shell.action = "shell"
    review.asked(shell, ENTRY)
    expect(#opened).to_be(0)
  end)

  it("drops what a session asked when it ends", function()
    review.asked(asked(), ENTRY)
    review.forget_session("ses_root")
    expect(dismissed[1]).to_be(opened[1].params.tab_name)
    expect(next(review._reviews())).to_be_nil()
  end)
end)

describe("diff answer hint", function()
  it("names who wants the change, the file, and the two answers", function()
    package.loaded["claude_agents.diff"] = nil
    local diff = require("claude_agents.diff")
    expect(diff._answer_hint("✻ [OpenCode] a.txt (abc123) ⧉", "/p/a.txt", false)).to_be(
      "OpenCode wants to change a.txt  ·  :w accept  ·  :q reject"
    )
    expect(diff._answer_hint("✻ [Claude Code] x.py ⧉", "/p/x.py", true)).to_be(
      "Claude wants to create x.py  ·  :w accept  ·  :q reject"
    )
  end)
end)
