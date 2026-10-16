---@brief [[
--- OpenCode's edits, reviewed as diffs in Neovim.
---
--- A session the plugin launches carries rules that make its edits ask first
--- (`rules.lua`). Asking is an event — `permission.asked` with `action = "edit"`
--- and, per file, the unified patch the edit would apply — and answering is a
--- call: `once` lets the edit through, `reject` stops it, and a reject's message
--- is what the model reads. So a request becomes one diff per file, in the same
--- view `openDiff` opens for Claude, and the user's answer becomes the reply:
---
---   * every file `:w`-ed as proposed            -> `once`; OpenCode writes them
---   * every file `:w`-ed, some changed by hand  -> the plugin writes every file
---     as accepted and replies `reject`, telling the model the user applied
---     their own version and it should read the files again
---   * any file `:q`-ed                          -> `reject`, the rest closed
---
--- OpenCode's TUI shows the same request and may be answered first; that answer
--- (`permission.replied`) takes the diffs down without answering again.
---@brief ]]
---@module 'claude_agents.opencode.review'

local logger = require("claude_agents.logger")
local tools = require("claude_agents.opencode.tools")

local M = {}

M._api = require("claude_agents.opencode.api")
M._diff = function()
  return require("claude_agents.diff")
end
M._io = {
  read = require("claude_agents.store_io").read,
  write = function(path, data)
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
      pcall(vim.fn.mkdir, dir, "p")
    end
    local f, err = io.open(path, "wb")
    if not f then
      return false, err
    end
    f:write(data)
    f:close()
    return true
  end,
}

M.REJECTED = "The user rejected this edit in Neovim."
M.APPLIED_OWN = "The user accepted this edit in Neovim with changes of their own, and the files are already saved "
  .. "as they want them: %s. Do not apply the edit again; read the files before changing them further."

---@class ClaudeCodeOpencodeReview
---@field request_id string
---@field session_id string
---@field root string
---@field files { path: string, tab_name: string, proposed: string, result: table|nil }[]
---@field answered boolean

--- [request id] = ClaudeCodeOpencodeReview
local reviews = {}

local function opencode()
  return require("claude_agents.opencode")
end

---@param text string|nil
---@return string
local function normalize(text)
  return (tostring(text or ""):gsub("\r\n", "\n"):gsub("\n+$", ""))
end

local function close_all(review, how)
  local diff = M._diff()
  for _, file in ipairs(review.files) do
    pcall(function()
      if how == "dismiss" then
        diff.dismiss_review(file.tab_name)
      else
        diff.finish_review(file.tab_name)
      end
    end)
  end
end

local function reply(review, decision, message)
  if review.answered then
    return
  end
  review.answered = true
  M._api.reply_permission(review.session_id, review.request_id, decision, message, function(err)
    if err then
      logger.error("opencode", "could not answer OpenCode's edit request:", err)
    end
  end)
end

---Every file answered: work out the reply.
---@param review ClaudeCodeOpencodeReview
local function settle(review)
  for _, file in ipairs(review.files) do
    if not file.result then
      return
    end
  end
  local changed = false
  for _, file in ipairs(review.files) do
    if normalize(file.result.content) ~= normalize(file.proposed) then
      changed = true
    end
  end
  if not changed then
    reply(review, "once", nil)
    close_all(review, "finish")
  else
    local written = {}
    for _, file in ipairs(review.files) do
      local ok, err = M._io.write(file.path, file.result.content or file.proposed)
      if ok then
        written[#written + 1] = file.path
      else
        logger.error("opencode", "could not write " .. file.path .. ":", tostring(err))
      end
    end
    reply(review, "reject", string.format(M.APPLIED_OWN, table.concat(written, ", ")))
    close_all(review, "finish")
  end
  reviews[review.request_id] = nil
end

---@param review ClaudeCodeOpencodeReview
---@param file table
---@param result { saved: boolean, content: string|nil }
local function on_result(review, file, result)
  if review.answered then
    return
  end
  if not result.saved then
    reply(review, "reject", M.REJECTED)
    -- The rejected diff is finished; the files still open are not being asked
    -- about any more.
    for _, other in ipairs(review.files) do
      pcall(function()
        if other == file then
          M._diff().finish_review(other.tab_name)
        else
          M._diff().dismiss_review(other.tab_name)
        end
      end)
    end
    reviews[review.request_id] = nil
    return
  end
  file.result = result
  settle(review)
end

---OpenCode asks whether it may edit. Opens the diffs, unless review is off or a
---proposal cannot be rebuilt (then OpenCode's own prompt is the only one).
---@param data table `permission.asked` data: `{ id, sessionID, action, resources, metadata = { files = { { file, patch, status } } } }`.
---@param entry ClaudeCodeOpencodeTracked The launched session it belongs to.
function M.asked(data, entry)
  if not opencode().config().review_edits or type(data) ~= "table" or data.action ~= "edit" then
    return
  end
  if type(data.id) ~= "string" or reviews[data.id] then
    return
  end
  local metadata = type(data.metadata) == "table" and data.metadata or {}
  local files = type(metadata.files) == "table" and metadata.files or {}
  if #files == 0 then
    return
  end

  local review = {
    request_id = data.id,
    session_id = data.sessionID,
    root = entry.root,
    files = {},
    answered = false,
  }
  for _, item in ipairs(files) do
    local path = tools.absolute(item.file, entry.cwd)
    if not path then
      return
    end
    local current = M._io.read(path) or ""
    local hunks = tools.first_hunks(item.patch) or {}
    local proposed, err = tools.apply_hunks(current, hunks)
    if not proposed then
      logger.warn("opencode", "cannot show OpenCode's edit of " .. path .. " as a diff (" .. tostring(err) .. ")")
      return
    end
    local rel = vim.fn.fnamemodify(path, ":.")
    review.files[#review.files + 1] = {
      path = path,
      proposed = proposed,
      tab_name = string.format("✻ [OpenCode] %s (%s) ⧉", rel, data.id:sub(-6)),
    }
  end

  reviews[data.id] = review
  local context = require("claude_agents.request_context")
  local saved_context = context.get()
  for _, file in ipairs(review.files) do
    context.set({
      instance_id = entry.instance and entry.instance.id or nil,
      tab = entry.tab,
      session_id = entry.kind == "agent" and entry.root or nil,
      kind = entry.kind,
    })
    local ok, err = M._diff().open_review({
      old_file_path = file.path,
      new_file_path = file.path,
      new_file_contents = file.proposed,
      tab_name = file.tab_name,
      agent = "OpenCode",
    }, function(result)
      on_result(review, file, result)
    end)
    context.set(saved_context)
    if not ok then
      logger.warn("opencode", "could not open the review diff for " .. file.path .. ":", tostring(err))
      -- Nothing half-shown: the TUI's prompt stays the way to answer.
      close_all(review, "dismiss")
      reviews[data.id] = nil
      return
    end
  end
end

---OpenCode heard an answer to a request: when it was not given here, the diffs
---it was about come down unanswered.
---@param data table `{ sessionID, requestID, reply }`
function M.replied(data)
  local review = type(data) == "table" and reviews[data.requestID]
  if not review then
    return
  end
  reviews[data.requestID] = nil
  review.answered = true
  close_all(review, "dismiss")
end

---After the event stream reopened: requests asked in the gap get their diffs.
---@param root string
---@param entry ClaudeCodeOpencodeTracked|nil
function M.resync(root, entry)
  if not entry or not opencode().config().review_edits then
    return
  end
  M._api.permissions(root, function(err, data)
    if err or type(data) ~= "table" then
      return
    end
    for _, request in ipairs(data) do
      if type(request) == "table" and not reviews[request.id] then
        M.asked(request, entry)
      end
    end
  end)
end

---A launched session ended: what it asked can no longer be answered.
---@param root string
function M.forget_session(root)
  for id, review in pairs(reviews) do
    if review.root == root then
      review.answered = true
      close_all(review, "dismiss")
      reviews[id] = nil
    end
  end
end

local function reapply(session_id, agent)
  M._api.get_session(session_id, function(err, info)
    if err or type(info) ~= "table" then
      return
    end
    require("claude_agents.opencode.sessions").apply_rules(info, agent)
  end)
end

---The session switched agents: the rules are rebuilt for the new one, whose
---refusals they must keep.
---@param session_id string
---@param agent string|nil
function M.agent_selected(session_id, agent)
  reapply(session_id, agent)
end

---A subagent's session appeared: it inherited its parent's rules, which were
---built for the parent's agent.
---@param session_id string
---@param agent string|nil
function M.child_created(session_id, agent)
  reapply(session_id, agent)
end

---Pending reviews (specs).
---@return table<string, ClaudeCodeOpencodeReview>
function M._reviews()
  return reviews
end

---Test/reload helper.
function M._reset()
  reviews = {}
end

return M
