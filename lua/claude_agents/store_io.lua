---@brief [[
--- File I/O for the small JSON stores under `stdpath("cache")/claudecode/`
--- (flags, launch profiles): read, replace in one step, and a stamp to tell a
--- write by another Neovim from our own.
---
--- **libuv calls only, and that is load-bearing.** A store can be touched where a
--- transcript fold finishes, in the callback of an `uv.fs_read` — a fast context,
--- where every `vim.fn` call raises `E5560`. The flags store first read and wrote
--- with `readfile`/`writefile`: the read threw after the copy in memory had been
--- emptied for it, the error was swallowed by the fold's `pcall`, and every flag
--- was gone from memory. Measured in a real Neovim; a spec's fake filesystem has
--- no fast context to fail in.
---
--- libuv is looked up per call rather than captured at load, so a spec can stand
--- a fake one in.
---@brief ]]
---@module 'claude_agents.store_io'

local M = {}

local function uv()
  return vim.uv or vim.loop
end

---@param dir string
local function mkdir_p(dir)
  if dir == "" or uv().fs_stat(dir) then
    return
  end
  local parent = dir:match("^(.*)[/\\][^/\\]+$")
  if parent and parent ~= dir then
    mkdir_p(parent)
  end
  uv().fs_mkdir(dir, 493) -- 0755
end

---@param path string
---@param data string
---@return boolean written
local function write_file(path, data)
  local fd = uv().fs_open(path, "w", 420) -- 0644
  if not fd then
    return false
  end
  local written = uv().fs_write(fd, data, 0)
  uv().fs_close(fd)
  return written == #data
end

---@param path string
---@return string|nil data nil when the file cannot be read.
function M.read(path)
  local lib = uv()
  local fd = lib and lib.fs_open and lib.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local st = lib.fs_fstat(fd)
  local data = st and lib.fs_read(fd, st.size, 0) or nil
  lib.fs_close(fd)
  return data
end

---Replace the file in one step: a reader in another Neovim sees the old store or
---the new one, never the half of one that a truncate-then-write leaves. The
---temporary file is named for this process, so two editors writing at once do
---not write into each other's.
---@param path string
---@param data string
---@return boolean written
function M.write(path, data)
  local lib = uv()
  if not (lib and lib.fs_open) then
    return false
  end
  mkdir_p(path:match("^(.*)[/\\][^/\\]*$") or "")
  local tmp = string.format("%s.%d.tmp", path, lib.os_getpid())
  if write_file(tmp, data) and lib.fs_rename(tmp, path) then
    return true
  end
  lib.fs_unlink(tmp)
  return write_file(path, data)
end

---@param path string
---@return string|nil stamp Size and mtime as one comparable value; nil when there is no file.
function M.stat(path)
  local lib = uv()
  local st = lib and lib.fs_stat and lib.fs_stat(path)
  if not st then
    return nil
  end
  local mtime = st.mtime or {}
  return string.format("%d:%d.%d", st.size or 0, mtime.sec or 0, mtime.nsec or 0)
end

return M
