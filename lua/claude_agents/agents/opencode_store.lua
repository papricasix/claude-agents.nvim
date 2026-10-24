---@brief [[
--- OpenCode conversations, read the way the agents view reads Claude's.
---
--- The agents view draws everything from Claude Code's transcripts: one JSONL
--- file per conversation, folded incrementally (`agents/transcript.lua`) into the
--- counts, files, activity and tasks every pane shows, searched line by line,
--- read again for one tool call or one file's history. OpenCode keeps its
--- conversations in its service instead, as structured messages.
---
--- Rather than a second fold with a second set of rules, each OpenCode session
--- is written out here as the transcript Claude would have written for it —
--- prompts, tool calls under Claude's tool names, results in `toolUseResult`'s
--- shapes, `structuredPatch` hunks parsed from OpenCode's unified patches — and
--- handed to `transcript.lua` as a file at `opencode://<session id>`. The fold
--- reads it through its I/O seam exactly as it reads a file on disk, so every
--- pane, the search and the views work on OpenCode sessions unchanged.
---
--- The written transcript only ever grows, like a real one, which is what the
--- incremental fold relies on: a call is written when it starts and its result
--- when it ends, text when its message completes. A session whose history was
--- taken back (OpenCode's revert) is written afresh under a new inode, which the
--- fold reads as a different file and folds from the start.
---
--- Messages are fetched from the service: the whole history once, then the
--- newest page each time the session is known to have moved (its events mark
--- it), back to the first message already complete here.
---@brief ]]
---@module 'claude_agents.agents.opencode_store'

local logger = require("claude_agents.logger")
local tools = require("claude_agents.opencode.tools")

local M = {}

M.PREFIX = "opencode://"

M._api = function()
  return require("claude_agents.opencode.api")
end
M._events = function()
  return require("claude_agents.opencode.events")
end
M._service = function()
  return require("claude_agents.opencode.service")
end
M._dirs = function()
  return require("claude_agents.opencode.dirs")
end
M._now = function()
  return os.time()
end

--- What the fold recognises a declined call by (`transcript.REJECTION_MARKER`).
local REJECTION = "The user doesn't want to proceed with this tool use."
--- And an interrupted turn (`transcript.INTERRUPT_MARKER`).
local INTERRUPT = "[Request interrupted by user]"

--- How long a project's session list is believed before it is asked again (s).
local LIST_TTL = 3
--- Newest messages asked for when a known session moved.
local TAIL_PAGE = 20
local FULL_PAGE = 200

---@param path any
---@return boolean
function M.is_path(path)
  return type(path) == "string" and path:sub(1, #M.PREFIX) == M.PREFIX
end

---A session's transcript path. Named like a Claude transcript (`<id>.jsonl`), so
---everything that reads an id or a sidecar directory out of a path — the fold's
---session id, `subagents.dir` — reads an OpenCode one the same way.
---@param id string
---@return string
function M.path(id)
  return M.PREFIX .. id .. ".jsonl"
end

---Where a subagent's transcript is: in its root session's `subagents/`
---directory, as Claude keeps them.
---@param root string
---@param child string
---@return string
function M.child_path(root, child)
  return M.PREFIX .. root .. "/subagents/agent-" .. child .. ".jsonl"
end

---The session a transcript path is of: a session's own, or a subagent's.
---@param path string
---@return string|nil
function M.id_of(path)
  if not M.is_path(path) then
    return nil
  end
  local rest = path:sub(#M.PREFIX + 1)
  local child = rest:match("/subagents/agent%-(ses_[%w]+)%.jsonl$")
  if child then
    return child
  end
  return rest:match("^(ses_[%w]+)%.jsonl$") or rest:match("^(ses_[%w]+)$")
end

--- Subagents, by the session that is their root: `[root] = { [child] = meta }`,
--- `meta` in the shape of Claude's `agent-<id>.meta.json`.
local subagents_of = {}
--- `[child] = root`, for a subagent's own subagents.
local root_of = {}
--- `[call id] = child`, for a `subagent` call still running: its own record names
--- the child only once it has ended. `false`: looked for, not found.
local child_of_call = {}

---A `subagent` call's descriptor, before the session it started is known.
---@param id string The call's id.
---@param input table The call's input, as OpenCode records it.
---@param time table The part's `time`.
---@return table
local function subagent_meta(id, input, time)
  return {
    agentType = input.agent or "general",
    description = input.description,
    toolUseId = id,
    requestShape = "foreground",
    started = time.ran or time.created,
  }
end

---Record a subagent session a `subagent` call started.
---@param store_id string The session that made the call.
---@param child string
---@param meta table
local function note_subagent(store_id, child, meta)
  local root = root_of[store_id] or store_id
  root_of[child] = root
  subagents_of[root] = subagents_of[root] or {}
  local known = subagents_of[root][child] or {}
  for key, value in pairs(meta) do
    known[key] = value
  end
  if store_id ~= root then
    known.parentAgentId = store_id
  end
  subagents_of[root][child] = known
end

--------------------------------------------------------------------------------
-- Writing a session out as a transcript
--------------------------------------------------------------------------------

---@param ms number|nil Epoch milliseconds.
---@return string
function M.iso(ms)
  ms = tonumber(ms) or 0
  local sec = math.floor(ms / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", math.floor(ms % 1000))
end

---@class ClaudeCodeOpencodeStore
---@field id string
---@field info table|nil Session.Info
---@field parts string[] The transcript's lines, each with its newline.
---@field size integer
---@field gen integer The transcript's inode: bumped when it is written afresh.
---@field emitted table<string, boolean>
---@field complete table<string, boolean> Message ids nothing more will be written for.
---@field title string|nil The title last written.
---@field parent string|nil The previous user message's id (for `parentUuid`).
---@field dirty boolean The service has moved on since the last fetch.
---@field fetched boolean
---@field waiters function[]|nil
---@field unlinked table[]|nil Descriptors of running `subagent` calls whose session is not known yet.
---@field updated integer The session's `time.updated` when last fetched (ms).
---@field revert any The session's revert marker when last fetched.

---@type table<string, ClaudeCodeOpencodeStore>
local stores = {}
--- A project's session list, by the directory asked for.
local lists = {}

local function new_store(id)
  return {
    id = id,
    parts = {},
    size = 0,
    gen = 1,
    emitted = {},
    complete = {},
    dirty = true,
    fetched = false,
    updated = 0,
  }
end

---@param id string
---@return ClaudeCodeOpencodeStore
local function store_for(id)
  local store = stores[id]
  if not store then
    store = new_store(id)
    stores[id] = store
  end
  return store
end

local function write(store, record)
  local line = vim.json.encode(record) .. "\n"
  store.parts[#store.parts + 1] = line
  store.size = store.size + #line
  store.content = nil
end

local function once(store, key, fn)
  if store.emitted[key] then
    return
  end
  store.emitted[key] = true
  fn()
end

local function cwd_of_store(store)
  local info = store.info
  return info and info.location and info.location.directory or nil
end

---The text of a tool's output parts.
---@param state table
---@return string
local function output_text(state)
  local out = {}
  for _, item in ipairs(type(state.content) == "table" and state.content or {}) do
    if type(item) == "table" and type(item.text) == "string" then
      out[#out + 1] = item.text
    end
  end
  if #out == 0 and type(state.output) == "string" then
    out[1] = state.output
  end
  return table.concat(out, "\n")
end

---The hunks an edit's result carries: OpenCode's unified patch, parsed. V2
---records it per file (`metadata.files[] = { file, patch, status, additions,
---deletions }`, as its permission request does); V1 as `diff`/`filediff`.
---@param metadata table
---@return table[]|nil
local function result_hunks(metadata)
  local patch = tools.metadata_patch(metadata)
  if not patch then
    return nil
  end
  return tools.first_hunks(patch) or {}
end

---`toolUseResult` for a finished OpenCode call, in the shape Claude records for
---the tool it is renamed to.
---@param name string OpenCode's tool name.
---@param input table Claude-shaped input.
---@param state table
---@param time table|nil The part's `time` (`created`, `ran`, `completed`, ms).
---@return any
local function tool_use_result(name, input, state, time)
  time = time or {}
  local metadata = type(state.metadata) == "table" and state.metadata or {}
  local text = output_text(state)
  if state.status == "error" then
    local message = type(state.error) == "table" and state.error.message or text
    return "Error: " .. tostring(message or "")
  end
  if name == "edit" then
    return {
      filePath = input.file_path,
      oldString = input.old_string,
      newString = input.new_string,
      structuredPatch = result_hunks(metadata) or {},
    }
  elseif name == "write" then
    local hunks = result_hunks(metadata)
    local created = metadata.exists == false
      or metadata.created == true
      or (hunks ~= nil and #hunks == 1 and hunks[1].oldLines == 0)
    if created or not hunks then
      return { filePath = input.file_path, content = input.content, type = "create", structuredPatch = {} }
    end
    return { filePath = input.file_path, content = input.content, type = "update", structuredPatch = hunks }
  elseif name == "read" then
    local start = tonumber(text:match("lines (%d+)%-%d+")) or tonumber(input.offset) or 1
    local last = tonumber(text:match("lines %d+%-(%d+)"))
    local count = last and (last - start + 1) or tonumber(input.limit) or 0
    -- No `totalLines` worth trusting, so a read never stands for the whole file.
    return {
      type = "text",
      file = { filePath = input.file_path, content = "", numLines = count, startLine = start, totalLines = -1 },
    }
  elseif name == "shell" then
    return { stdout = text, stderr = "", interrupted = false, isImage = false }
  elseif name == "subagent" then
    -- What a foreground run's result records about it, which the Tasks pane
    -- reads its cost and end from.
    local started, ended = time.ran or time.created, time.completed
    return {
      status = "completed",
      agentId = metadata.sessionID,
      content = { { type = "text", text = text } },
      totalDurationMs = (started and ended) and math.max(0, ended - started) or 0,
      totalTokens = 0,
    }
  end
  return text
end

---@param store ClaudeCodeOpencodeStore
---@param message table An assistant message.
---@param part table A `tool` content part.
local function write_tool(store, message, part)
  local state = type(part.state) == "table" and part.state or {}
  -- Written once the call is made. Until then its input is still streaming in
  -- (2.0.30 `streaming`, the input so far a string; V1 `pending`), and a call
  -- written then would keep an empty input for good: a `Task` with no description.
  if state.status ~= "running" and state.status ~= "completed" and state.status ~= "error" then
    return
  end
  if store.emitted[part.id .. ":result"] then
    return
  end
  local cwd = cwd_of_store(store)
  local raw_input = type(state.input) == "table" and state.input or {}
  local time = type(part.time) == "table" and part.time or {}
  local claude_name = tools.name(part.name)
  local input = tools.input(part.name, raw_input, cwd)
  local id = part.id

  -- A patch can touch several files; each becomes an Edit of its own so every
  -- file gets its row and its counts.
  if part.name == "patch" or part.name == "apply_patch" then
    local metadata = type(state.metadata) == "table" and state.metadata or {}
    local files, order = {}, {}
    if type(metadata.files) == "table" and #metadata.files > 0 then
      -- V2: a patch per file.
      for _, item in ipairs(metadata.files) do
        if type(item) == "table" and type(item.file) == "string" then
          files[item.file] = tools.first_hunks(item.patch) or {}
          order[#order + 1] = item.file
        end
      end
    else
      local patch = metadata.diff or raw_input.patchText or raw_input.patch
      files, order = tools.parse_patch(type(patch) == "string" and patch or "")
    end
    once(store, id .. ":use", function()
      write(store, {
        type = "assistant",
        timestamp = M.iso(time.created or message.time and message.time.created),
        message = {
          role = "assistant",
          content = { { type = "tool_use", id = id, name = "Patch", input = raw_input } },
        },
      })
    end)
    if state.status ~= "completed" and state.status ~= "error" then
      return
    end
    once(store, id .. ":result", function()
      write(store, {
        type = "user",
        timestamp = M.iso(time.completed or time.created),
        message = {
          role = "user",
          content = {
            {
              type = "tool_result",
              tool_use_id = id,
              content = output_text(state),
              is_error = state.status == "error",
            },
          },
        },
        toolUseResult = output_text(state),
      })
      if state.status == "completed" then
        for n, file in ipairs(order) do
          local sub = id .. ":" .. n
          local path = tools.absolute(file, cwd)
          write(store, {
            type = "assistant",
            timestamp = M.iso(time.completed or time.created),
            message = {
              role = "assistant",
              content = { { type = "tool_use", id = sub, name = "Edit", input = { file_path = path } } },
            },
          })
          write(store, {
            type = "user",
            timestamp = M.iso(time.completed or time.created),
            message = { role = "user", content = { { type = "tool_result", tool_use_id = sub, content = "" } } },
            toolUseResult = { filePath = path, structuredPatch = files[file] },
          })
        end
      end
    end)
    return
  end

  -- A subagent runs as a session of its own, which the Tasks pane lists from the
  -- moment it is known: by the call once ended, by its progress event while it
  -- runs, or — that event missed — by `link_children` after this pass.
  local metadata = type(state.metadata) == "table" and state.metadata or {}
  if part.name == "subagent" then
    local child = type(metadata.sessionID) == "string" and metadata.sessionID or child_of_call[id]
    if child then
      note_subagent(store.id, child, subagent_meta(id, raw_input, time))
    elseif child_of_call[id] == nil and state.status == "running" then
      store.unlinked = store.unlinked or {}
      table.insert(store.unlinked, subagent_meta(id, raw_input, time))
    end
  end

  once(store, id .. ":use", function()
    write(store, {
      type = "assistant",
      timestamp = M.iso(time.created or (message.time and message.time.created)),
      message = { role = "assistant", content = { { type = "tool_use", id = id, name = claude_name, input = input } } },
    })
  end)
  if state.status ~= "completed" and state.status ~= "error" then
    return
  end
  once(store, id .. ":result", function()
    local is_error = state.status == "error"
    local err_type = is_error and type(state.error) == "table" and state.error.type or nil
    local content = is_error and (type(state.error) == "table" and state.error.message or output_text(state))
      or output_text(state)
    if err_type == "permission.rejected" or err_type == "aborted" then
      -- What the fold reads as "declined": the user said no, it did not fail.
      content = REJECTION .. " " .. tostring(content or "")
    end
    write(store, {
      type = "user",
      timestamp = M.iso(time.completed or time.ran or time.created),
      message = {
        role = "user",
        content = { { type = "tool_result", tool_use_id = id, content = content, is_error = is_error } },
      },
      toolUseResult = tool_use_result(part.name, input, state, time),
    })
  end)
end

---@param store ClaudeCodeOpencodeStore
---@param message table Session.Message.Info
function M._write_message(store, message)
  if type(message) ~= "table" or type(message.id) ~= "string" then
    return
  end
  local mid = message.id
  if store.complete[mid] then
    return
  end
  local time = type(message.time) == "table" and message.time or {}
  local cwd = cwd_of_store(store)

  if message.type == "user" then
    once(store, mid, function()
      write(store, {
        type = "user",
        timestamp = M.iso(time.created),
        cwd = cwd,
        uuid = mid,
        parentUuid = store.parent,
        origin = { kind = "human" },
        message = { role = "user", content = type(message.text) == "string" and message.text or "" },
      })
      store.parent = mid
    end)
    store.complete[mid] = true
  elseif message.type == "assistant" then
    local done = time.completed ~= nil or message.finish ~= nil
    for index, part in ipairs(type(message.content) == "table" and message.content or {}) do
      if type(part) == "table" then
        if part.type == "tool" and type(part.id) == "string" then
          write_tool(store, message, part)
        elseif done and part.type == "text" and type(part.text) == "string" and part.text ~= "" then
          once(store, mid .. ":text:" .. index, function()
            local record = {
              type = "assistant",
              timestamp = M.iso(time.completed or time.created),
              message = { role = "assistant", content = { { type = "text", text = part.text } } },
            }
            local tokens = type(message.tokens) == "table" and message.tokens or nil
            if tokens then
              local cache = type(tokens.cache) == "table" and tokens.cache or {}
              record.message.usage = {
                input_tokens = tokens.input or 0,
                output_tokens = tokens.output or 0,
                cache_read_input_tokens = cache.read or 0,
                cache_creation_input_tokens = cache.write or 0,
              }
            end
            write(store, record)
          end)
        elseif done and part.type == "reasoning" and type(part.text) == "string" and part.text ~= "" then
          once(store, mid .. ":reasoning:" .. index, function()
            write(store, {
              type = "assistant",
              timestamp = M.iso(time.created),
              message = { role = "assistant", content = { { type = "thinking", thinking = part.text } } },
            })
          end)
        end
      end
    end
    if done then
      local all_tools_done = true
      for _, part in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(part) == "table" and part.type == "tool" then
          local status = type(part.state) == "table" and part.state.status or nil
          if status ~= "completed" and status ~= "error" then
            all_tools_done = false
          end
        end
      end
      if all_tools_done then
        store.complete[mid] = true
      end
    end
  elseif message.type == "idle" then
    if message.outcome == "interrupted" then
      once(store, mid, function()
        write(store, {
          type = "user",
          timestamp = M.iso(time.created),
          message = { role = "user", content = INTERRUPT },
        })
      end)
    end
    store.complete[mid] = true
  else
    store.complete[mid] = true
  end
end

---Write what the session's info says that the messages do not: its title.
---@param store ClaudeCodeOpencodeStore
local function write_info(store)
  local title = store.info and store.info.title
  if type(title) == "string" and title ~= "" and title ~= store.title then
    store.title = title
    write(store, { type = "ai-title", aiTitle = title, sessionId = store.id })
  end
end

--- What a restart carries over: the session and the fetch under way. Every
--- other field describes the transcript written so far, and goes with it.
local KEPT_ON_RESTART = { "id", "info", "revert", "updated", "waiters" }

---Start the transcript over (the session's history was taken back). The same
---table is kept, since `stores` and a running fetch hold it.
---@param store ClaudeCodeOpencodeStore
local function restart(store)
  local fresh = new_store(store.id)
  for _, key in ipairs(KEPT_ON_RESTART) do
    fresh[key] = store[key]
  end
  fresh.gen = store.gen + 1
  for key in pairs(store) do
    store[key] = nil
  end
  for key, value in pairs(fresh) do
    store[key] = value
  end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---A session's messages in `order`, page after page until the last, or until a
---page holds one `stop` says is far enough.
---@param id string
---@param order "asc"|"desc"
---@param limit integer
---@param stop (fun(message: table): boolean)|nil
---@param cb fun(err: string|nil, messages: table[]|nil)
local function fetch_pages(id, order, limit, stop, cb)
  local got = {}
  local function page(cursor)
    local query = cursor and { cursor = cursor, limit = limit } or { order = order, limit = limit }
    M._api()
      .call("GET", "/api/session/" .. id .. "/message", { query = query, no_start = true }, function(err, data, res)
        if err then
          cb(err, nil)
          return
        end
        local reached = false
        for _, message in ipairs(type(data) == "table" and data or {}) do
          got[#got + 1] = message
          reached = reached or (stop ~= nil and type(message) == "table" and stop(message))
        end
        local cursor_info = res and type(res.json) == "table" and res.json.cursor or nil
        local next_cursor = type(cursor_info) == "table" and cursor_info.next or nil
        if
          not reached
          and type(next_cursor) == "string"
          and next_cursor ~= ""
          and type(data) == "table"
          and #data > 0
        then
          page(next_cursor)
        else
          cb(nil, got)
        end
      end)
  end
  page(nil)
end

---Every message of a session, oldest first.
local function fetch_all(store, cb)
  fetch_pages(store.id, "asc", FULL_PAGE, nil, cb)
end

---The newest messages, back to (and including) the first one already complete
---here; oldest first.
local function fetch_tail(store, cb)
  fetch_pages(store.id, "desc", TAIL_PAGE, function(message)
    return store.complete[message.id] == true
  end, function(err, newest)
    if err then
      cb(err, nil)
      return
    end
    local ordered = {}
    for i = #newest, 1, -1 do
      ordered[#ordered + 1] = newest[i]
    end
    cb(nil, ordered)
  end)
end

local function settle(store, err)
  local waiters = store.waiters or {}
  store.waiters = nil
  for _, waiter in ipairs(waiters) do
    pcall(waiter, err)
  end
end

---Find the sessions of running `subagent` calls whose progress event this
---Neovim never saw (the view opened while they ran), among the session's
---children: a child's title is the call's description, its agent the call's.
---Asked once per call.
---@param store ClaudeCodeOpencodeStore
---@param done fun()
local function link_children(store, done)
  local calls = store.unlinked or {}
  store.unlinked = nil
  if #calls == 0 then
    done()
    return
  end
  for _, call in ipairs(calls) do
    child_of_call[call.toolUseId] = false
  end
  local query = { parentID = store.id, limit = 100, order = "asc" }
  M._api().call("GET", "/api/session", { query = query, no_start = true }, function(err, children)
    if not err and type(children) == "table" then
      local taken = {}
      for child in pairs(subagents_of[root_of[store.id] or store.id] or {}) do
        taken[child] = true
      end
      for _, call in ipairs(calls) do
        for _, child in ipairs(children) do
          if
            type(child) == "table"
            and type(child.id) == "string"
            and not taken[child.id]
            and child.title == call.description
            and child.agent == call.agentType
          then
            taken[child.id] = true
            child_of_call[call.toolUseId] = child.id
            note_subagent(store.id, child.id, call)
            break
          end
        end
      end
    end
    done()
  end)
end

---Bring a session's transcript up to date with the service, then call back.
---Answers at once when nothing is known to have changed.
---@param id string
---@param cb fun(err: string|nil)
function M.refresh(id, cb)
  local store = store_for(id)
  M.listen()
  if store.fetched and not store.dirty then
    cb(nil)
    return
  end
  if store.waiters then
    table.insert(store.waiters, cb)
    return
  end
  store.waiters = { cb }
  store.dirty = false

  local function fetch_messages(info)
    -- A history taken back (OpenCode's revert) is not an append: the transcript
    -- is written afresh, under a new inode the fold reads as another file.
    local reverted = store.fetched and vim.inspect(info.revert) ~= vim.inspect(store.revert)
    if reverted then
      restart(store)
      store.dirty = false
    end
    store.info = info
    store.revert = info.revert
    store.updated = info.time and info.time.updated or store.updated
    local fetch = store.fetched and fetch_tail or fetch_all
    fetch(store, function(err, messages)
      if err then
        store.dirty = true
        settle(store, err)
        return
      end
      store.unlinked = nil
      for _, message in ipairs(messages) do
        local ok, write_err = pcall(M._write_message, store, message)
        if not ok then
          logger.debug("opencode", "could not write a message of", id, tostring(write_err))
        end
      end
      write_info(store)
      store.fetched = true
      link_children(store, function()
        settle(store, nil)
      end)
    end)
  end

  -- A first read of a listed session: the list already said what it is (the
  -- revert check only matters once something has been written).
  if not store.fetched and store.info then
    fetch_messages(store.info)
    return
  end
  M._api().call("GET", "/api/session/" .. id, { no_start = true }, function(info_err, info)
    if info_err or type(info) ~= "table" then
      settle(store, info_err or "no such session")
      return
    end
    fetch_messages(info)
  end)
end

--------------------------------------------------------------------------------
-- The transcript file the fold reads
--------------------------------------------------------------------------------

---A subagent's descriptor, as `agent-<id>.meta.json` would hold it.
---@param path string
---@return string|nil json
---@return table|nil meta
local function meta_at(path)
  if not M.is_path(path) then
    return nil
  end
  local root, child = path:sub(#M.PREFIX + 1):match("^(ses_[%w]+)/subagents/agent%-(ses_[%w]+)%.meta%.json$")
  local meta = root and subagents_of[root] and subagents_of[root][child]
  if not meta then
    return nil
  end
  return vim.json.encode(meta), meta
end

---The `_io.scandir` of a session's `subagents/` directory: a descriptor and a
---transcript per subagent it started, at any depth.
---@param dir string
---@return string[]|nil
function M.scandir(dir)
  if not M.is_path(dir) then
    return nil
  end
  local root = dir:sub(#M.PREFIX + 1):match("^(ses_[%w]+)/subagents/?$")
  if not root then
    return nil
  end
  local names = {}
  for child in pairs(subagents_of[root] or {}) do
    names[#names + 1] = "agent-" .. child .. ".meta.json"
    names[#names + 1] = "agent-" .. child .. ".jsonl"
  end
  table.sort(names)
  return names
end

---@param path string
---@return { size: integer, mtime: integer, ino: integer, birth: number|nil }|nil
function M.stat(path)
  local json, meta = meta_at(path)
  if json then
    local started = tonumber(meta.started) or 0
    return { size = #json, mtime = math.floor(started / 1000), ino = 1 }
  end
  local id = M.id_of(path)
  if not id then
    return nil
  end
  local store = stores[id]
  if not store then
    -- Known from the list but never read: an empty file the fold reads nothing
    -- of until `refresh` fills it.
    return { size = 0, mtime = 0, ino = 1 }
  end
  local info = store.info
  local updated = info and info.time and info.time.updated or store.updated or 0
  local created = info and info.time and info.time.created or nil
  return {
    size = store.size,
    mtime = math.floor(updated / 1000),
    ino = store.gen,
    birth = created and (created / 1000) or nil,
  }
end

---@param path string
---@return string
function M.content(path)
  local json = meta_at(path)
  if json then
    return json
  end
  local id = M.id_of(path)
  local store = id and stores[id]
  if not store then
    return ""
  end
  if not store.content then
    store.content = table.concat(store.parts)
  end
  return store.content
end

---The `_io.read` of an OpenCode transcript: answered in the same tick.
function M.read(path, offset, len, cb)
  cb(M.content(path):sub(offset + 1, offset + len), nil)
end

function M.read_sync(path, len)
  return M.content(path):sub(1, len)
end

function M.read_tail_sync(path, len)
  local content = M.content(path)
  return content:sub(math.max(1, #content - len + 1))
end

---Whether the service has moved on since the transcript was written.
---@param path string
---@return boolean
function M.outdated(path)
  local id = M.id_of(path)
  local store = id and stores[id]
  return store == nil or store.dirty or not store.fetched
end

---The directory a session ran in.
---@param path string
---@return string|nil
function M.cwd_of(path)
  local id = M.id_of(path)
  local store = id and stores[id]
  return store and cwd_of_store(store) or nil
end

---Delete a session from the service. Irreversible, like deleting a transcript.
---@param path string
---@return boolean ok
---@return string|nil err
function M.delete(path)
  local id = M.id_of(path)
  if not id then
    return false, "not an OpenCode session"
  end
  local err = M._api().call_sync("DELETE", "/api/session/" .. id, nil, 5000)
  if err then
    return false, "could not delete the OpenCode session: " .. tostring(err)
  end
  stores[id] = nil
  for _, list in pairs(lists) do
    list.dirty = true
  end
  return true, nil
end

--------------------------------------------------------------------------------
-- The service, while it is not answering
--------------------------------------------------------------------------------

--- The view lists OpenCode's conversations only through the service, which runs
--- once per user and does not come back by itself after a login. So the store
--- keeps what it knows about it: `unknown` until a listing answers or fails,
--- `up`, `down` (nothing answered), `starting`, `failed` (a start did not bring
--- it up) or `disabled` (the user switched it off). One state for every
--- directory, since there is one service; whether a directory hears about it is
--- `note`'s business.
---@type { kind: string, err: string|nil, explicit: boolean }
local service_state = { kind = "unknown", err = nil, explicit = false }
--- Whether this view open has already acted on a stopped service (started it,
--- or asked whether it is switched off), or found it running. Reset when the
--- view closes.
local view_acted = false

---Have the view list again (and repaint): the rows or the note changed.
local function relist()
  vim.schedule(function()
    local ok, model = pcall(require, "claude_agents.agents.model")
    if ok and type(model.refresh_list) == "function" then
      pcall(model.refresh_list)
    end
  end)
end

---@param kind string
---@param err string|nil
local function set_service(kind, err)
  if kind == "up" then
    service_state.explicit = false
  end
  if service_state.kind == kind and service_state.err == err then
    return
  end
  service_state.kind, service_state.err = kind, err
  relist()
end

---Start the service, and say how it went.
---@param explicit boolean A request (`gO`, the command) rather than the view's own start.
local function start_service(explicit)
  local was = service_state.kind
  if was == "starting" then
    return
  end
  service_state.explicit = service_state.explicit or explicit
  set_service("starting", nil)
  M._service().ensure(function(err)
    if not err then
      -- Asked for from the command too, with no view open to show the outcome.
      if explicit then
        logger.info(
          "opencode",
          was == "up" and "OpenCode's service is already running" or "OpenCode's service is running"
        )
      end
      for _, list in pairs(lists) do
        list.dirty = true
      end
      set_service("up", nil)
      return
    end
    local off = err == M._service().DISABLED_ERR
    set_service(off and "disabled" or "failed", err)
    -- Switched off is the user's own setting: the view's start says so on the
    -- hint alone; a request is answered either way.
    if explicit or not off then
      logger.warn("opencode", tostring(err))
    end
  end)
end

---A listing found nothing answering.
---@param cwd string
local function service_down(cwd)
  local kind = service_state.kind
  if kind ~= "starting" and kind ~= "failed" and kind ~= "disabled" then
    set_service("down", nil)
  end
  if view_acted or service_state.kind ~= "down" or not M._dirs().marked(cwd) then
    return
  end
  view_acted = true
  if require("claude_agents.opencode").config().start_service == "view" then
    start_service(false)
  else
    -- Left to the user: the hint should say so when no key would help.
    M._service().disabled(function(off)
      if off and service_state.kind == "down" then
        set_service("disabled", M._service().DISABLED_ERR)
      end
    end)
  end
end

---What the view should say about the service in a directory: nil while it
---answers (or nothing is known), and for a directory the plugin never launched
---OpenCode in — unless the user asked for a start, whose outcome is theirs to see
---anywhere.
---@param cwd string|nil
---@return { kind: "down"|"starting"|"failed"|"disabled", err: string|nil }|nil
function M.note(cwd)
  local kind = service_state.kind
  if kind == "unknown" or kind == "up" then
    return nil
  end
  if not service_state.explicit and not M._dirs().marked(cwd) then
    return nil
  end
  return { kind = kind, err = service_state.err }
end

---Start OpenCode's service because the user asked (`gO`, `<CR>` on the hint,
---`:ClaudeCodeOpencodeStart`), in any directory. Its progress shows on the hint;
---the conversations follow once it answers.
function M.start_service()
  start_service(true)
end

--------------------------------------------------------------------------------
-- Listing a project's sessions
--------------------------------------------------------------------------------

---@type table<string, { rows: table[], at: integer, fetching: boolean, dirty: boolean, project: string|nil }>
local function row_of(info)
  local updated = info.time and info.time.updated or 0
  local store = store_for(info.id)
  if not store.fetched then
    store.info = info
  end
  -- A session that moved since it was written out is read again when next asked.
  if store.fetched and updated > (store.updated or 0) then
    store.dirty = true
  end
  return {
    id = info.id,
    path = M.path(info.id),
    size = store.size,
    mtime = math.floor(updated / 1000),
  }
end

---Sessions of a project, or — where OpenCode has no project for it (no
---repository: the "global" project) — of a directory under both of its
---spellings: the one Neovim uses and the real path OpenCode's TUI moves the
---sessions it opens to.
---@param cb fun(err: string|nil, data: table|nil, answered: boolean) `answered`: the service replied, if only with an error.
local function query_sessions(cwd, list, project, cb)
  local base = { parentID = "null", limit = 100, order = "desc" }
  if project and project ~= "global" then
    base.project = project
    M._api().call("GET", "/api/session", { query = base, no_start = true }, function(err, data, res)
      cb(err, data, err == nil or res ~= nil)
    end)
    return
  end
  local dirs = { cwd }
  local real = require("claude_agents.opencode").canonical(cwd)
  if real ~= cwd then
    dirs[2] = real
  end
  if list.directory and list.directory ~= cwd and list.directory ~= real then
    dirs[#dirs + 1] = list.directory
  end
  local merged, seen, pending, failed, answered = {}, {}, #dirs, nil, false
  for _, dir in ipairs(dirs) do
    local query = vim.deepcopy(base)
    query.directory = dir
    M._api().call("GET", "/api/session", { query = query, no_start = true }, function(err, data, res)
      answered = answered or err == nil or res ~= nil
      if err then
        failed = err
      else
        for _, info in ipairs(type(data) == "table" and data or {}) do
          if type(info) == "table" and info.id and not seen[info.id] then
            seen[info.id] = true
            merged[#merged + 1] = info
          end
        end
      end
      pending = pending - 1
      if pending == 0 then
        table.sort(merged, function(a, b)
          return ((a.time and a.time.updated) or 0) > ((b.time and b.time.updated) or 0)
        end)
        cb(#merged == 0 and failed or nil, merged, answered)
      end
    end)
  end
end

local function fetch_list(cwd, list)
  list.fetching = true
  local function query_with(project)
    query_sessions(cwd, list, project, function(err, data, answered)
      list.fetching = false
      list.at = M._now()
      if err then
        if not answered then
          service_down(cwd)
        end
        return
      end
      set_service("up", nil)
      -- Found running: one that stops while the view is open (`opencode service
      -- stop`, a setting changed) is the user's doing, and is not started again.
      view_acted = true
      local rows = {}
      for _, info in ipairs(type(data) == "table" and data or {}) do
        if type(info) == "table" and type(info.id) == "string" and not (info.time and info.time.archived) then
          rows[#rows + 1] = row_of(info)
        end
      end
      local changed = #rows ~= #list.rows
      if not changed then
        for i, row in ipairs(rows) do
          local old = list.rows[i]
          if old.id ~= row.id or old.mtime ~= row.mtime then
            changed = true
            break
          end
        end
      end
      list.rows = rows
      list.dirty = false
      if #rows == 0 then
        -- Nothing to list here: no reason left to start the service for this
        -- directory. A project listing covers its worktrees too; a directory's
        -- only itself.
        M._dirs().forget(cwd, { exact = not (project and project ~= "global") })
      end
      if changed then
        relist()
      end
    end)
  end
  if list.project ~= nil then
    query_with(list.project)
    return
  end
  M._api()
    .call("GET", "/api/location", { query = { ["location[directory]"] = cwd }, no_start = true }, function(err, data, res)
      if err then
        -- Asked again on the next listing.
        list.fetching = false
        list.at = M._now()
        if res == nil then
          service_down(cwd)
        end
        return
      end
      local project = (type(data) == "table" and type(data.project) == "table") and data.project.id or false
      list.project = project
      list.directory = (type(data) == "table" and type(data.directory) == "string") and data.directory or nil
      query_with(project or nil)
    end)
end

---A project's OpenCode sessions, newest first, as `transcript.list` rows. Answers
---from what is known now and asks the service again when that is old; the
---answer arriving re-lists the view.
---@param cwd string
---@return { id: string, path: string, size: integer, mtime: integer }[]
function M.list(cwd)
  if type(cwd) ~= "string" or cwd == "" or not require("claude_agents.opencode").available() then
    return {}
  end
  M.listen()
  -- Another Neovim may have launched OpenCode here since (one stat).
  M._dirs().refresh()
  local list = lists[cwd]
  if not list then
    list = { rows = {}, at = 0, fetching = false, dirty = true, project = nil }
    lists[cwd] = list
  end
  if not list.fetching and (list.dirty or M._now() - list.at >= LIST_TTL) then
    fetch_list(cwd, list)
  end
  local out = {}
  for _, row in ipairs(list.rows) do
    local store = stores[row.id]
    out[#out + 1] = {
      id = row.id,
      path = row.path,
      size = store and store.size or row.size,
      mtime = row.mtime,
    }
  end
  return out
end

---Every top-level OpenCode session on the service, for the widest search.
---@return { id: string, path: string, size: integer, mtime: integer, dir: string }[]
function M.list_all()
  if not require("claude_agents.opencode").available() then
    return {}
  end
  local err, data = M._api()
    .call_sync("GET", "/api/session", { query = { parentID = "null", limit = 200 }, no_start = true }, 3000)
  if err then
    return {}
  end
  local rows = {}
  for _, info in ipairs(type(data) == "table" and data or {}) do
    if type(info) == "table" and type(info.id) == "string" then
      local row = row_of(info)
      row.dir = info.location and info.location.directory or ""
      rows[#rows + 1] = row
    end
  end
  return rows
end

--------------------------------------------------------------------------------
-- Following the service
--------------------------------------------------------------------------------

local unsubscribe = nil

--- Events after which a session's transcript has more to say.
local MOVES = {
  ["session.tool.called"] = true,
  ["session.tool.success"] = true,
  ["session.tool.failed"] = true,
  ["session.execution.started"] = true,
  ["session.execution.succeeded"] = true,
  ["session.execution.failed"] = true,
  ["session.execution.interrupted"] = true,
  ["session.inbox.delivered"] = true,
  ["session.text.ended"] = true,
  ["session.renamed"] = true,
  ["session.step.ended"] = true,
}

---@param event table
function M.handle(event)
  local data = type(event.data) == "table" and event.data or {}
  local etype = event.type
  if etype == M._events().CONNECTED then
    for _, store in pairs(stores) do
      store.dirty = true
    end
    for _, list in pairs(lists) do
      list.dirty = true
    end
    return
  end
  if etype == "session.created" or etype == "session.deleted" or etype == "session.moved" then
    for _, list in pairs(lists) do
      list.dirty = true
    end
    if etype == "session.deleted" and data.sessionID then
      stores[data.sessionID] = nil
    end
    return
  end
  local store = data.sessionID and stores[data.sessionID]
  if etype == "session.tool.progress" then
    -- A `subagent` call names its session here, as soon as it has one.
    local child = type(data.metadata) == "table" and data.metadata.sessionID or nil
    if type(child) == "string" and type(data.id) == "string" and child_of_call[data.id] ~= child then
      child_of_call[data.id] = child
      if store then
        store.dirty = true
      end
    end
    return
  end
  if store and MOVES[etype] then
    store.dirty = true
    if etype == "session.renamed" and store.info and type(data.title) == "string" then
      store.info.title = data.title
    end
  end
end

---Follow the service's events (idempotent).
function M.listen()
  if unsubscribe then
    return
  end
  local ok, events = pcall(M._events)
  if ok then
    -- What happened while nothing listened is not known: all of it is read
    -- again. (A stream already open for the bridge announces nothing new.)
    for _, store in pairs(stores) do
      store.dirty = true
    end
    for _, list in pairs(lists) do
      list.dirty = true
    end
    unsubscribe = events.subscribe(M.handle)
  end
end

---Stop following, and forget what was read (the view closed).
function M.stop()
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
  -- The next open acts on a stopped service again, and learns its state afresh
  -- (a start still under way reports itself when it lands).
  view_acted = false
  if service_state.kind ~= "starting" then
    service_state = { kind = "unknown", err = nil, explicit = false }
  end
end

---Test/reload helper.
function M._reset()
  M.stop()
  stores, lists = {}, {}
  subagents_of, root_of, child_of_call = {}, {}, {}
  service_state = { kind = "unknown", err = nil, explicit = false }
end

---@param id string
---@return ClaudeCodeOpencodeStore|nil
function M._store(id)
  return stores[id]
end

return M
