---@brief [[
--- OpenCode's tools in the words the rest of the plugin speaks.
---
--- Every consumer of agent activity — status, the live cursor, the agents
--- view's panes — was written against Claude Code's tool names and input
--- fields. OpenCode's differ (`read`/`edit`/`write`/`shell`/`subagent`, with
--- `path`, `oldString`, `newString`, paths relative to the session's
--- directory), so its calls are renamed here once, rather than every consumer
--- learning a second vocabulary.
---@brief ]]
---@module 'claude_agents.opencode.tools'

local M = {}

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- OpenCode tool -> the Claude Code tool that does the same job.
M.NAMES = {
  read = "Read",
  edit = "Edit",
  write = "Write",
  patch = "Patch",
  apply_patch = "Patch",
  shell = "Bash",
  glob = "Glob",
  grep = "Grep",
  subagent = "Task",
  question = "AskUserQuestion",
  webfetch = "WebFetch",
  websearch = "WebSearch",
  todowrite = "TodoWrite",
  skill = "Skill",
}

---The Claude Code name for an OpenCode tool; unknown tools keep their own.
---@param name string|nil
---@return string|nil
function M.name(name)
  if type(name) ~= "string" then
    return nil
  end
  return M.NAMES[name] or name
end

---@param path string|nil
---@param cwd string|nil
---@return string|nil
function M.absolute(path, cwd)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:sub(1, 1) == "~" then
    return path
  end
  if type(cwd) ~= "string" or cwd == "" then
    return path
  end
  return (cwd:gsub("/+$", "")) .. "/" .. path:gsub("^%./", "")
end

---An OpenCode call's input with Claude Code's field names, file paths made
---absolute against the session's directory. Fields with no counterpart are
---kept as they are.
---@param name string|nil OpenCode's tool name.
---@param input table|nil
---@param cwd string|nil
---@return table
function M.input(name, input, cwd)
  local out = {}
  for key, value in pairs(type(input) == "table" and input or {}) do
    out[key] = value
  end
  local path = out.path or out.filePath or out.file_path
  if name == "read" or name == "edit" or name == "write" then
    out.file_path = M.absolute(path, cwd)
  elseif name == "glob" or name == "grep" then
    out.path = M.absolute(out.path, cwd)
  end
  if name == "edit" then
    out.old_string = out.oldString or out.old_string
    out.new_string = out.newString or out.new_string
  elseif name == "subagent" then
    out.subagent_type = out.agent or out.subagent_type
  end
  return out
end

---The unified patch a finished edit's metadata carries: per file in V2
---(`files[] = { file, patch, … }`, as its permission request), as `diff` or
---`filediff.patch` in V1.
---@param metadata table|nil
---@return string|nil
function M.metadata_patch(metadata)
  if type(metadata) ~= "table" then
    return nil
  end
  local files = type(metadata.files) == "table" and metadata.files or nil
  if files and type(files[1]) == "table" and type(files[1].patch) == "string" then
    return files[1].patch
  end
  local filediff = type(metadata.filediff) == "table" and metadata.filediff or nil
  local patch = (filediff and filediff.patch) or metadata.diff
  return type(patch) == "string" and patch or nil
end

---Parse a unified diff into Claude Code's `structuredPatch` hunks, one list per
---file named in it: `{ [path] = { { oldStart, oldLines, newStart, newLines, lines } } }`.
---Lines keep their ` `, `+` or `-` prefix, as Claude's do.
---@param patch string|nil
---@return table<string, table[]> files
---@return string[] order Paths in the order they appear.
function M.parse_patch(patch)
  local files, order = {}, {}
  if type(patch) ~= "string" or patch == "" then
    return files, order
  end
  local current, hunk = nil, nil
  for line in (patch .. "\n"):gmatch("(.-)\r?\n") do
    local plus = line:match("^%+%+%+ (.+)$")
    local index = line:match("^Index: (.+)$")
    if index then
      current = trim(index)
      hunk = nil
    elseif plus then
      local path = trim((plus:gsub("^b/", ""):gsub("\t.*$", "")))
      if path ~= "/dev/null" then
        current = path
      end
      hunk = nil
    elseif line:match("^%-%-%- ") or line:match("^=+$") then
      hunk = nil
    else
      local os_, ol, ns, nl = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if os_ and current then
        hunk = {
          oldStart = tonumber(os_),
          oldLines = ol ~= "" and tonumber(ol) or 1,
          newStart = tonumber(ns),
          newLines = nl ~= "" and tonumber(nl) or 1,
          lines = {},
        }
        if not files[current] then
          files[current] = {}
          order[#order + 1] = current
        end
        table.insert(files[current], hunk)
      elseif hunk and (line:sub(1, 1) == " " or line:sub(1, 1) == "+" or line:sub(1, 1) == "-") then
        table.insert(hunk.lines, line)
      end
    end
  end
  return files, order
end

---Apply a file's hunks to its text, for the proposal a review diff shows.
---Hunks are applied by position (`oldStart`), checked against the context; a
---hunk whose context does not match is reported rather than guessed at.
---@param text string The file as it is now ("" for a new file).
---@param hunks table[]
---@return string|nil result
---@return string|nil error
function M.apply_hunks(text, hunks)
  local lines = {}
  local had_trailing_newline = text:sub(-1) == "\n"
  for line in (text .. (had_trailing_newline and "" or "\n")):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if text == "" then
    lines = {}
  end
  local out = {}
  local cursor = 1
  for _, hunk in ipairs(hunks or {}) do
    local start = hunk.oldStart
    if hunk.oldLines == 0 then
      -- A pure insertion names the line after which it goes.
      start = start + 1
    end
    while cursor < start and cursor <= #lines do
      out[#out + 1] = lines[cursor]
      cursor = cursor + 1
    end
    for _, hline in ipairs(hunk.lines) do
      local mark, body = hline:sub(1, 1), hline:sub(2)
      if mark == " " or mark == "-" then
        if lines[cursor] ~= body then
          return nil, string.format("the file changed: line %d no longer reads as the proposal expects", cursor)
        end
        if mark == " " then
          out[#out + 1] = body
        end
        cursor = cursor + 1
      elseif mark == "+" then
        out[#out + 1] = body
      end
    end
  end
  while cursor <= #lines do
    out[#out + 1] = lines[cursor]
    cursor = cursor + 1
  end
  local result = table.concat(out, "\n")
  if #out > 0 and (had_trailing_newline or text == "") then
    result = result .. "\n"
  end
  return result, nil
end

---Count added and removed lines in hunks.
---@param hunks table[]|nil
---@return integer added
---@return integer removed
function M.count(hunks)
  local added, removed = 0, 0
  for _, hunk in ipairs(hunks or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      local mark = line:sub(1, 1)
      if mark == "+" then
        added = added + 1
      elseif mark == "-" then
        removed = removed + 1
      end
    end
  end
  return added, removed
end

return M
