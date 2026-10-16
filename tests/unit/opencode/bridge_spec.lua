require("tests.busted_setup")

describe("opencode.bridge", function()
  local bridge
  local dispatched
  local reviews
  local interrupts

  local function event(etype, data)
    return { type = etype, data = data }
  end

  before_each(function()
    dispatched, reviews, interrupts = {}, {}, {}
    package.loaded["claude_agents.opencode.bridge"] = nil
    package.loaded["claude_agents.opencode.review"] = {
      asked = function(data, entry)
        reviews[#reviews + 1] = { "asked", data, entry }
      end,
      replied = function(data)
        reviews[#reviews + 1] = { "replied", data }
      end,
      child_created = function(id, agent)
        reviews[#reviews + 1] = { "child", id, agent }
      end,
      agent_selected = function(id, agent)
        reviews[#reviews + 1] = { "agent", id, agent }
      end,
      forget_session = function() end,
      resync = function() end,
    }
    package.loaded["claude_agents.opencode.sessions"] = {
      note_used = function() end,
      note_agent = function() end,
    }
    package.loaded["claude_agents.status"] = {
      note_interrupt = function(tab)
        interrupts[#interrupts + 1] = tab
      end,
    }
    bridge = require("claude_agents.opencode.bridge")
    bridge._events = {
      CONNECTED = "stream.connected",
      subscribe = function()
        return function() end
      end,
    }
    bridge._dispatch = function(hook, tab, agent_key)
      dispatched[#dispatched + 1] = { hook = hook, tab = tab, agent_key = agent_key }
    end
    bridge.track("ses_root", { tab = 3, agent_key = "1:ses_root", cwd = "/proj", kind = "agent" })
  end)

  after_each(function()
    package.loaded["claude_agents.opencode.review"] = nil
    package.loaded["claude_agents.opencode.sessions"] = nil
    package.loaded["claude_agents.status"] = nil
  end)

  local function last()
    return dispatched[#dispatched].hook
  end

  it("announces a launch the way a SessionStart hook does", function()
    expect(dispatched[1].hook.hook_event_name).to_be("SessionStart")
    expect(dispatched[1].hook.session_id).to_be("ses_root")
    expect(dispatched[1].tab).to_be(3)
    expect(dispatched[1].agent_key).to_be("1:ses_root")
    expect(dispatched[1].hook.opencode).to_be_true()
  end)

  it("turns a prompt and a tool call into UserPromptSubmit and PreToolUse in Claude's words", function()
    bridge.handle(event("session.execution.started", { sessionID = "ses_root" }))
    expect(last().hook_event_name).to_be("UserPromptSubmit")
    -- The name comes first, on its own event; the call carries only the input.
    bridge.handle(event("session.tool.input.started", { sessionID = "ses_root", id = "t1", name = "edit" }))
    bridge.handle(event("session.tool.called", {
      sessionID = "ses_root",
      id = "t1",
      input = { path = "a.txt", oldString = "a", newString = "b" },
    }))
    local hook = last()
    expect(hook.hook_event_name).to_be("PreToolUse")
    expect(hook.tool_name).to_be("Edit")
    expect(hook.tool_use_id).to_be("t1")
    expect(hook.tool_input.file_path).to_be("/proj/a.txt")
    expect(hook.tool_input.new_string).to_be("b")
    expect(hook.transcript_path).to_be("opencode://ses_root.jsonl")
  end)

  it("reports a finished edit with its patch as Claude's tool_response", function()
    bridge.handle(event("session.tool.input.started", { sessionID = "ses_root", id = "t1", name = "edit" }))
    bridge.handle(event("session.tool.called", { sessionID = "ses_root", id = "t1", input = { path = "a.txt" } }))
    bridge.handle(event("session.tool.success", {
      sessionID = "ses_root",
      id = "t1",
      metadata = { files = { { file = "a.txt", patch = "--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-hello\n+goodbye\n" } } },
    }))
    local hook = last()
    expect(hook.hook_event_name).to_be("PostToolUse")
    expect(hook.tool_response.filePath).to_be("/proj/a.txt")
    expect(hook.tool_response.structuredPatch[1].lines[2]).to_be("+goodbye")
  end)

  it("raises a permission request named by its call, and hands it to review", function()
    bridge.handle(event("session.tool.input.started", { sessionID = "ses_root", id = "t1", name = "edit" }))
    bridge.handle(event("permission.asked", {
      id = "per_1",
      sessionID = "ses_root",
      action = "edit",
      source = { type = "tool", messageID = "m", id = "t1" },
    }))
    local hook = last()
    expect(hook.hook_event_name).to_be("PermissionRequest")
    expect(hook.tool_use_id).to_be("t1")
    expect(hook.tool_name).to_be("Edit")
    expect(reviews[1][1]).to_be("asked")
    bridge.handle(event("permission.replied", { sessionID = "ses_root", requestID = "per_1", reply = "once" }))
    expect(reviews[2][1]).to_be("replied")
  end)

  it("raises a question as an AskUserQuestion prompt", function()
    bridge.handle(event("form.created", {
      form = { id = "frm", sessionID = "ses_root", metadata = { kind = "question", tool = { id = "t9" } }, fields = {} },
    }))
    local hook = last()
    expect(hook.hook_event_name).to_be("PermissionRequest")
    expect(hook.tool_name).to_be("AskUserQuestion")
    expect(hook.tool_use_id).to_be("t9")
  end)

  it("follows a subagent's session as a thread of its root", function()
    bridge.handle(event("session.created", { sessionID = "ses_child", parentID = "ses_root", agent = "explore" }))
    expect(reviews[1][1]).to_be("child")
    bridge.handle(event("session.tool.input.started", { sessionID = "ses_child", id = "t2", name = "read" }))
    bridge.handle(event("session.tool.called", { sessionID = "ses_child", id = "t2", input = { path = "b.txt" } }))
    local hook = last()
    expect(hook.session_id).to_be("ses_root")
    expect(hook.agent_id).to_be("ses_child")
    expect(hook.tool_name).to_be("Read")
    bridge.handle(event("session.execution.succeeded", { sessionID = "ses_child" }))
    expect(last().hook_event_name).to_be("SubagentStop")
    -- Untracking the root takes the child with it.
    bridge.untrack("ses_root")
    expect(bridge.get("ses_child")).to_be_nil()
  end)

  it("ends a turn with Stop, an API failure with StopFailure", function()
    bridge.handle(event("session.execution.succeeded", { sessionID = "ses_root" }))
    expect(last().hook_event_name).to_be("Stop")
    bridge.handle(event("session.execution.failed", { sessionID = "ses_root" }))
    expect(last().hook_event_name).to_be("StopFailure")
  end)

  it("reports an interrupt to the tab's status", function()
    bridge.track("ses_tab", { tab = 7, cwd = "/proj", kind = "tab" })
    bridge.handle(event("session.execution.interrupted", { sessionID = "ses_tab", reason = "user" }))
    expect(interrupts[1]).to_be(7)
  end)

  it("ignores sessions it does not follow", function()
    local before = #dispatched
    bridge.handle(event("session.execution.started", { sessionID = "ses_other" }))
    bridge.handle(event("session.created", { sessionID = "ses_x", parentID = "ses_other" }))
    expect(#dispatched).to_be(before)
    expect(bridge.get("ses_x")).to_be_nil()
  end)

  it("passes an agent switch to review, which rebuilds the rules", function()
    bridge.handle(event("session.agent.selected", { sessionID = "ses_root", agent = "plan" }))
    expect(reviews[1][1]).to_be("agent")
    expect(reviews[1][3]).to_be("plan")
  end)
end)
