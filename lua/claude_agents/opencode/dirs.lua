---@brief [[
--- The directories the plugin has launched OpenCode in, persisted in
--- `stdpath("cache")/claudecode/opencode-dirs.json`.
---
--- The agents view lists OpenCode's conversations only while OpenCode's shared
--- service runs, and nothing else the plugin can read says a directory has any:
--- the conversations live in the service's database, reachable only through the
--- service. So the plugin keeps its own note of where it started OpenCode
--- (`mark`, from a launch whose process actually started), which the view reads
--- while the service is down to decide whether to start it or say it is missing.
---
--- Keyed by the directory's canonical spelling (symlinks resolved, as OpenCode's
--- processes see it), and a directory counts as marked when it or a directory
--- inside it was (`marked`), so a view opened in the repository finds the
--- launches the plugin made in its worktrees. The note clears itself: a marked
--- directory whose listing comes back empty from a running service is forgotten
--- (`forget`).
---
--- Shared between Neovims like the flags and profiles stores (`store_io`): read
--- again before every change, replaced in one step, and re-read on `refresh`
--- when another Neovim wrote it.
---@brief ]]
---@module 'claude_agents.opencode.dirs'

local utils = require("claude_agents.utils")

local M = {}

local STORE_VERSION = 1

--- `[key] = { at = epoch }`
---@type table<string, { at: number }>
local dirs = {}
local loaded = false
---@type string|nil
local stamp = nil
---@type string|nil
local store_path = nil

--- The filesystem, as a seam for specs.
M._io = require("claude_agents.store_io")

---@return string|nil path nil only when first asked from a fast context.
function M.store_path()
  if not store_path and not (vim.in_fast_event and vim.in_fast_event()) then
    store_path = vim.fn.stdpath("cache") .. "/claudecode/opencode-dirs.json"
  end
  return store_path
end

---A directory as the store's key: canonical, normalized, case-folded on Windows.
---@param dir string|nil
---@return string|nil
function M.key(dir)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return utils.path_key(require("claude_agents.opencode").canonical(dir))
end

---@return boolean read false when the file exists and could not be read.
local function read_store()
  local path = M.store_path()
  if not path then
    return false
  end
  local seen = M._io.stat(path)
  local data = M._io.read(path)
  if data == nil and seen ~= nil then
    return false
  end
  local fresh = {}
  local ok, decoded = pcall(vim.json.decode, data or "")
  if ok and type(decoded) == "table" and decoded.version == STORE_VERSION and type(decoded.dirs) == "table" then
    for key, record in pairs(decoded.dirs) do
      if type(key) == "string" and key ~= "" and type(record) == "table" then
        fresh[key] = { at = tonumber(record.at) or 0 }
      end
    end
  end
  dirs, stamp, loaded = fresh, seen, true
  return true
end

local function load()
  if not loaded then
    read_store()
  end
end

---Apply a change to the store as it is on disk now (another Neovim may have
---written since), and write it back.
---@param change fun(): boolean
local function mutate(change)
  if not read_store() or not change() then
    return
  end
  local ok, encoded = pcall(vim.json.encode, { version = STORE_VERSION, dirs = dirs })
  local path = M.store_path()
  if ok and path and M._io.write(path, encoded) ~= false then
    stamp = M._io.stat(path)
  end
end

---Whether a recorded key is `key` itself or a directory inside it.
---@param recorded string
---@param key string
---@return boolean
local function covers(recorded, key)
  if recorded == key then
    return true
  end
  -- A root (`/`, `D:/`) already ends in its separator.
  local prefix = key:sub(-1) == "/" and key or (key .. "/")
  return recorded:sub(1, #prefix) == prefix
end

---Record that OpenCode was launched in a directory.
---@param dir string|nil
function M.mark(dir)
  local key = M.key(dir)
  if not key then
    return
  end
  mutate(function()
    dirs[key] = { at = os.time() }
    return true
  end)
end

---Whether OpenCode was launched in a directory, or in a directory inside it.
---Asks nothing of the disk (see `refresh`).
---@param dir string|nil
---@return boolean
function M.marked(dir)
  local key = M.key(dir)
  if not key then
    return false
  end
  load()
  for recorded in pairs(dirs) do
    if covers(recorded, key) then
      return true
    end
  end
  return false
end

---Forget a directory, and every recorded directory inside it: everything
---`marked(dir)` would answer true for.
---@param dir string|nil
---@param opts { exact: boolean|nil }|nil `exact`: the directory alone, not those inside it.
function M.forget(dir, opts)
  local key = M.key(dir)
  if not key or not M.marked(dir) then
    return
  end
  local exact = opts and opts.exact
  mutate(function()
    local changed = false
    for recorded in pairs(dirs) do
      if recorded == key or (not exact and covers(recorded, key)) then
        dirs[recorded] = nil
        changed = true
      end
    end
    return changed
  end)
end

---Take in what another Neovim wrote since the store was last read: one stat,
---the file read again only when it moved.
---@return boolean changed
function M.refresh()
  local path = M.store_path()
  if loaded and path and M._io.stat(path) == stamp then
    return false
  end
  return read_store()
end

---Test/reload helper.
function M._reset()
  dirs, loaded, stamp, store_path = {}, false, nil, nil
end

return M
