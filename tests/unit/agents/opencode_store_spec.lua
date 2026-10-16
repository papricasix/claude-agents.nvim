-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.opencode_store", function()
  local store, transcript
  local real_decode
  local sessions, messages, children

  local PATCH = "Index: a.txt\n--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-hello\n+goodbye\n"

  local function info(id, title)
    return {
      id = id,
      title = title,
      location = { directory = "/proj" },
      time = { created = 1792179000000, updated = 1792179060000 },
    }
  end

  ---The messages of one turn, as OpenCode 2.0.30 reports them.
  local function a_turn()
    return {
      { id = "msg_1", type = "user", text = "Change hello to goodbye", time = { created = 1792179001000 } },
      {
        id = "msg_2",
        type = "assistant",
        time = { created = 1792179002000, completed = 1792179009000 },
        finish = "stop",
        tokens = { input = 10, output = 20, cache = { read = 5, write = 1 } },
        content = {
          {
            type = "tool",
            id = "toolu_read",
            name = "read",
            state = {
              status = "completed",
              input = { path = "a.txt" },
              content = { { type = "text", text = "Read file a.txt, lines 1-1\n1: hello" } },
            },
            time = { created = 1792179003000, completed = 1792179003500 },
          },
          {
            type = "tool",
            id = "toolu_edit",
            name = "edit",
            state = {
              status = "completed",
              input = { path = "a.txt", oldString = "hello", newString = "goodbye" },
              content = { { type = "text", text = "Edited a.txt (1 replacement)" } },
              metadata = { files = { { file = "a.txt", patch = PATCH, status = "modified" } } },
            },
            time = { created = 1792179004000, completed = 1792179005000 },
          },
          {
            type = "tool",
            id = "toolu_sub",
            name = "subagent",
            state = {
              status = "completed",
              input = { agent = "explore", description = "Look around", prompt = "List files" },
              content = { { type = "text", text = "<subagent>done</subagent>" } },
              metadata = { sessionID = "ses_child", status = "completed" },
            },
            time = { created = 1792179006000, ran = 1792179006000, completed = 1792179008000 },
          },
          { type = "text", text = "Done." },
        },
      },
      { id = "msg_3", type = "idle", outcome = "interrupted", time = { created = 1792179010000 } },
    }
  end

  ---A turn whose `subagent` call is still running: OpenCode names the session it
  ---started only once the call ends.
  local function a_running_subagent()
    return {
      { id = "msg_1", type = "user", text = "go", time = { created = 1 } },
      {
        id = "msg_2",
        type = "assistant",
        time = { created = 2 },
        content = {
          {
            type = "tool",
            id = "toolu_sub",
            name = "subagent",
            state = {
              status = "running",
              input = { agent = "explore", description = "Look around", prompt = "List files" },
              metadata = {},
            },
            time = { created = 3, ran = 4 },
          },
        },
      },
    }
  end

  local fake_api = {
    call = function(method, path, opts, cb)
      if method == "GET" and path == "/api/session" then
        cb(nil, children[opts.query.parentID] or {})
        return
      end
      local id = path:match("^/api/session/(ses_[%w]+)$")
      if method == "GET" and id then
        if sessions[id] then
          cb(nil, sessions[id])
        else
          cb("HTTP 404", nil)
        end
        return
      end
      id = path:match("^/api/session/(ses_[%w]+)/message$")
      if method == "GET" and id then
        cb(nil, messages[id] or {}, { json = { cursor = {} } })
        return
      end
      cb("unexpected " .. method .. " " .. path, nil)
    end,
  }

  local function fold(path)
    local result
    transcript.summary(path, function(sum)
      result = sum
    end)
    return result
  end

  before_each(function()
    real_decode = vim.json.decode
    vim.json.decode = _G.json_decode
    package.loaded["claude_agents.agents.opencode_store"] = nil
    package.loaded["claude_agents.agents.transcript"] = nil
    store = require("claude_agents.agents.opencode_store")
    transcript = require("claude_agents.agents.transcript")
    store._api = function()
      return fake_api
    end
    store._events = function()
      return {
        CONNECTED = "stream.connected",
        subscribe = function()
          return function() end
        end,
      }
    end
    sessions = { ses_root = info("ses_root", "Goodbye edit"), ses_child = info("ses_child", "Look around") }
    messages = { ses_root = a_turn(), ses_child = {} }
    children = {}
  end)

  after_each(function()
    vim.json.decode = real_decode
    store._reset()
  end)

  it("names sessions like transcripts, subagents inside their root's directory", function()
    expect(store.path("ses_a")).to_be("opencode://ses_a.jsonl")
    expect(store.id_of("opencode://ses_a.jsonl")).to_be("ses_a")
    expect(store.id_of(store.child_path("ses_a", "ses_b"))).to_be("ses_b")
    expect(transcript.session_path("/proj", "ses_a")).to_be("opencode://ses_a.jsonl")
    expect(transcript.locate("ses_a")).to_be("opencode://ses_a.jsonl")
  end)

  it("folds a session's edit into the counts, files and activity the panes show", function()
    local sum = fold(store.path("ses_root"))
    expect(sum).not_to_be_nil()
    expect(sum.id).to_be("ses_root")
    local file = sum.files["/proj/a.txt"]
    expect(file.added).to_be(1)
    expect(file.removed).to_be(1)
    expect(sum.added).to_be(1)
    expect(sum.removed).to_be(1)
    expect(sum.cwd).to_be("/proj")
    expect(sum.first_prompt).to_be("Change hello to goodbye")
    expect(sum.title).to_be("Goodbye edit")
  end)

  it("records the turn's interrupt", function()
    local sum = fold(store.path("ses_root"))
    assert.is_truthy(sum.interrupted_ts)
  end)

  it("lists a subagent in its root's subagents directory, with a descriptor", function()
    fold(store.path("ses_root"))
    local names = transcript._io.scandir("opencode://ses_root/subagents")
    expect(#names).to_be(2)
    local meta_path = "opencode://ses_root/subagents/agent-ses_child.meta.json"
    expect(transcript._io.stat(meta_path)).not_to_be_nil()
    local meta = _G.json_decode(transcript._io.read_sync(meta_path, 4096))
    expect(meta.agentType).to_be("explore")
    expect(meta.toolUseId).to_be("toolu_sub")
  end)

  it("only grows its transcript, writing nothing twice", function()
    local path = store.path("ses_root")
    fold(path)
    local first = store.content(path)
    -- The service moved on: the same history comes back with nothing new.
    store.handle({ type = "session.step.ended", data = { sessionID = "ses_root" } })
    assert.is_true(transcript.stale(path))
    fold(path)
    expect(store.content(path)).to_be(first)
  end)

  it("writes a call as it starts and its result when it ends", function()
    messages.ses_root = {
      { id = "msg_1", type = "user", text = "go", time = { created = 1 } },
      {
        id = "msg_2",
        type = "assistant",
        time = { created = 2 },
        content = {
          { type = "tool", id = "t1", name = "shell", state = { status = "running", input = { command = "ls" } } },
        },
      },
    }
    local path = store.path("ses_root")
    fold(path)
    local before = store.content(path)
    assert_contains(before, '"tool_use"')
    assert_not_contains(before, '"tool_result"')
    messages.ses_root[2].content[1].state = {
      status = "completed",
      input = { command = "ls" },
      content = { { type = "text", text = "a.txt" } },
    }
    messages.ses_root[2].time.completed = 3
    store.handle({ type = "session.tool.success", data = { sessionID = "ses_root" } })
    fold(path)
    local after = store.content(path)
    expect(after:sub(1, #before)).to_be(before)
    assert_contains(after, '"tool_result"')
  end)

  it("writes a call only once its input is in, never with what has streamed so far", function()
    messages.ses_root = a_running_subagent()
    local call = messages.ses_root[2].content[1]
    call.state = { status = "streaming", input = '{"agent":"explore","descr' }
    local path = store.path("ses_root")
    fold(path)
    assert_not_contains(store.content(path), '"tool_use"')
    call.state = a_running_subagent()[2].content[1].state
    store.handle({ type = "session.tool.called", data = { sessionID = "ses_root" } })
    fold(path)
    assert_contains(store.content(path), '"description":"Look around"')
  end)

  it("lists a subagent while it runs, by the session its progress event names", function()
    messages.ses_root = a_running_subagent()
    fold(store.path("ses_root"))
    expect(#transcript._io.scandir("opencode://ses_root/subagents")).to_be(0)
    store.handle({
      type = "session.tool.progress",
      data = { sessionID = "ses_root", id = "toolu_sub", metadata = { sessionID = "ses_child", status = "running" } },
    })
    fold(store.path("ses_root"))
    expect(#transcript._io.scandir("opencode://ses_root/subagents")).to_be(2)
    local meta =
      _G.json_decode(transcript._io.read_sync("opencode://ses_root/subagents/agent-ses_child.meta.json", 4096))
    expect(meta.toolUseId).to_be("toolu_sub")
    expect(meta.description).to_be("Look around")
  end)

  it("finds a running subagent's session among the children when its progress event was missed", function()
    messages.ses_root = a_running_subagent()
    children.ses_root = {
      { id = "ses_other", parentID = "ses_root", title = "Something else", agent = "explore" },
      { id = "ses_child", parentID = "ses_root", title = "Look around", agent = "explore" },
    }
    fold(store.path("ses_root"))
    local meta =
      _G.json_decode(transcript._io.read_sync("opencode://ses_root/subagents/agent-ses_child.meta.json", 4096))
    expect(meta.toolUseId).to_be("toolu_sub")
    expect(transcript._io.stat("opencode://ses_root/subagents/agent-ses_other.meta.json")).to_be_nil()
  end)

  it("writes a declined call in the words the fold reads as declined", function()
    messages.ses_root = {
      {
        id = "msg_2",
        type = "assistant",
        time = { created = 2, completed = 3 },
        finish = "stop",
        content = {
          {
            type = "tool",
            id = "t1",
            name = "shell",
            state = {
              status = "error",
              input = { command = "rm -rf x" },
              error = { type = "permission.rejected", message = "no" },
            },
          },
        },
      },
    }
    local sum = fold(store.path("ses_root"))
    local found
    for _, event in ipairs(sum.events) do
      if event.tool_id == "t1" then
        found = event
      end
    end
    expect(found.status).to_be("rejected")
  end)

  it("answers nothing for a session the service does not have", function()
    local sum = fold(store.path("ses_gone"))
    -- An empty transcript folds to nothing worth showing.
    expect(sum == nil or sum.added == 0).to_be_true()
  end)
end)
