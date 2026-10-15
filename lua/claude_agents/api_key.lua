---@brief [[
--- Where an API profile's key lives, and how it is read: the OS keychain.
---
--- The plugin never holds the key. A profile names a keychain entry; the CLI is
--- given an `apiKeyHelper` that runs `scripts/api_key.lua get <entry>`, which
--- reads the entry and prints the key to the CLI alone. So the key is in no
--- config file, in neither Neovim's memory nor its environment, and — unlike an
--- `ANTHROPIC_API_KEY` in the environment, which every command Claude runs
--- inherits (measured: a hook process saw it) — out of reach of the tools Claude
--- calls.
---
--- Stored once by the user with the OS's own tool, which asks for the key with
--- hidden input (`store_command`). Read with:
---   * macOS: `security find-generic-password -s claudecode.nvim -a <entry> -w`
---   * Linux: `secret-tool lookup service claudecode.nvim account <entry>`
---     (libsecret: GNOME Keyring, KWallet, KeePassXC)
---   * Windows: Credential Manager, `CredReadW` through LuaJIT's FFI, since no
---     built-in command prints a stored secret.
---
--- Self-contained (it needs `vim` and nothing else of the plugin) because the
--- helper script loads it into a bare `nvim -l`.
---@brief ]]
---@module 'claude_agents.api_key'

local M = {}

--- Keychain service (macOS, Linux) and Credential Manager target prefix (Windows).
M.SERVICE = "claudecode.nvim"

--- Credential Manager's "not found" (`ERROR_NOT_FOUND`).
local ERROR_NOT_FOUND = 1168

---@return "macos"|"linux"|"windows"
function M.platform()
  if vim.fn.has("win32") == 1 then
    return "windows"
  end
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "macos"
  end
  return "linux"
end

---Whether an entry name is safe to put on a command line unquoted.
---@param entry any
---@return boolean
function M.valid_entry(entry)
  return type(entry) == "string" and entry:match("^[%w._-]+$") ~= nil
end

---The Credential Manager target an entry is stored under.
---@param entry string
---@return string
function M.target(entry)
  return M.SERVICE .. "/" .. entry
end

---The one command that stores a key under an entry, for the user to run in a
---terminal. Each asks for the key with hidden input, so it never lands in shell
---history and the plugin never sees it.
---@param entry string
---@param platform string|nil Defaults to this machine's.
---@return string
function M.store_command(entry, platform)
  platform = platform or M.platform()
  if platform == "macos" then
    return string.format("security add-generic-password -U -s %s -a %s -w", M.SERVICE, entry)
  elseif platform == "windows" then
    return string.format("cmdkey /generic:%s /user:%s /pass", M.target(entry), M.SERVICE)
  end
  return string.format(
    "secret-tool store --label='%s API key (%s)' service %s account %s",
    M.SERVICE,
    entry,
    M.SERVICE,
    entry
  )
end

---What a key looks like, without saying what it is.
---
---The CLI refuses a helper's output unless it is one printable-ASCII token, so
---anything else is worth catching before a launch rather than after.
---@param key string|nil
---@return "ok"|"empty"|"invalid"|"unexpected" shape `unexpected` is usable but not an Anthropic key's form.
function M.shape(key)
  if type(key) ~= "string" then
    return "empty"
  end
  local trimmed = key:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return "empty"
  end
  if not trimmed:match("^[%w%-_%.]+$") then
    return "invalid"
  end
  if not trimmed:match("^sk%-ant%-") then
    return "unexpected"
  end
  return "ok"
end

---Decode a Credential Manager blob. `cmdkey` stores the password as UTF-16LE;
---anything that is not that is taken as bytes.
---@param bytes string
---@return string
function M.decode_blob(bytes)
  if #bytes == 0 or #bytes % 2 ~= 0 then
    return bytes
  end
  local out = {}
  for i = 1, #bytes, 2 do
    if bytes:byte(i + 1) ~= 0 then
      return bytes
    end
    out[#out + 1] = bytes:sub(i, i)
  end
  return table.concat(out)
end

---Run a command, waiting for it. A seam for specs.
---@param argv string[]
---@return { code: integer, stdout: string, stderr: string }
M._run = function(argv)
  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait()
  end)
  if not ok or type(result) ~= "table" then
    return { code = -1, stdout = "", stderr = tostring(result) }
  end
  return { code = result.code or -1, stdout = result.stdout or "", stderr = result.stderr or "" }
end

---@param name string
---@return boolean
M._executable = function(name)
  return vim.fn.executable(name) == 1
end

---Read a generic credential from Credential Manager. A seam for specs.
---@param target string
---@return string|nil blob
---@return string|nil err
---@return boolean|nil missing
M._credread = function(target)
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi then
    return nil, "LuaJIT FFI is not available"
  end
  pcall(
    ffi.cdef,
    [[
    typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } CCN_FILETIME;
    typedef struct {
      uint32_t Flags;
      uint32_t Type;
      uint16_t *TargetName;
      uint16_t *Comment;
      CCN_FILETIME LastWritten;
      uint32_t CredentialBlobSize;
      uint8_t *CredentialBlob;
      uint32_t Persist;
      uint32_t AttributeCount;
      void *Attributes;
      uint16_t *TargetAlias;
      uint16_t *UserName;
    } CCN_CREDENTIALW;
    int CredReadW(const uint16_t *TargetName, uint32_t Type, uint32_t Flags, CCN_CREDENTIALW **Credential);
    void CredFree(void *Buffer);
    uint32_t GetLastError(void);
  ]]
  )
  local ok_lib, advapi = pcall(ffi.load, "advapi32")
  if not ok_lib then
    return nil, "advapi32 could not be loaded"
  end
  local wide = ffi.new("uint16_t[?]", #target + 1)
  for i = 1, #target do
    wide[i - 1] = target:byte(i)
  end
  local out = ffi.new("CCN_CREDENTIALW*[1]")
  -- 1 = CRED_TYPE_GENERIC, which is what `cmdkey /generic:` writes.
  if advapi.CredReadW(wide, 1, 0, out) == 0 then
    local code = ffi.C.GetLastError()
    if code == ERROR_NOT_FOUND then
      return nil, nil, true
    end
    return nil, "CredReadW failed with error " .. tostring(code)
  end
  local cred = out[0]
  local blob = ffi.string(cred.CredentialBlob, cred.CredentialBlobSize)
  advapi.CredFree(cred)
  return blob
end

---Read the key stored under an entry.
---@param entry string
---@param platform string|nil
---@return string|nil key
---@return string|nil err Something went wrong reading it (not "there is none").
---@return boolean|nil missing Nothing is stored under the entry.
function M.read(entry, platform)
  platform = platform or M.platform()
  if platform == "windows" then
    local blob, err, missing = M._credread(M.target(entry))
    if missing then
      return nil, nil, true
    end
    if not blob then
      return nil, err
    end
    return M.decode_blob(blob)
  end

  if platform == "macos" then
    local res = M._run({ "security", "find-generic-password", "-s", M.SERVICE, "-a", entry, "-w" })
    if res.code == 0 then
      return (res.stdout:gsub("%s+$", ""))
    end
    -- 44 is `errSecItemNotFound` as an exit status.
    if res.code == 44 or res.stderr:find("could not be found", 1, true) then
      return nil, nil, true
    end
    return nil, (res.stderr:gsub("%s+$", ""))
  end

  if not M._executable("secret-tool") then
    return nil, "secret-tool is not installed (libsecret-tools); install it, or give the profile an api_key_cmd"
  end
  local res = M._run({ "secret-tool", "lookup", "service", M.SERVICE, "account", entry })
  local key = res.stdout:gsub("%s+$", "")
  if res.code == 0 and key ~= "" then
    return key
  end
  if res.stderr:match("%S") and res.code ~= 1 then
    return nil, (res.stderr:gsub("%s+$", ""))
  end
  return nil, nil, true
end

---Run a user's own key command the way the CLI would (`/bin/sh -c`, `cmd.exe /c`).
---@param cmd string
---@param platform string|nil
---@return string|nil key
---@return string|nil err
function M.run_command(cmd, platform)
  platform = platform or M.platform()
  local argv = platform == "windows" and { "cmd.exe", "/c", cmd } or { "/bin/sh", "-c", cmd }
  local res = M._run(argv)
  if res.code ~= 0 then
    local detail = res.stderr:gsub("%s+$", "")
    return nil, "exited " .. tostring(res.code) .. (detail ~= "" and (": " .. detail) or "")
  end
  return (res.stdout:gsub("^%s+", ""):gsub("%s+$", ""))
end

---The helper's command line: `get <entry>`, `check <entry>`, `check-cmd <cmd>`.
---
---`get` prints the key and nothing else — the CLI takes the helper's whole
---output as the key. `check` and `check-cmd` print one line that describes the
---key without containing it (`found <length> <shape>` or `missing`), so the
---plugin can say whether a profile is usable without the key passing through
---Neovim.
---@param args string[]
---@param out { write: fun(self: any, s: string) }|nil Defaults to stdout.
---@param err { write: fun(self: any, s: string) }|nil Defaults to stderr.
---@return integer code 0 found, 2 missing, 1 error or misuse.
function M.main(args, out, err)
  out = out or io.stdout
  err = err or io.stderr
  local command, value = args[1], args[2]

  if command == "check-cmd" then
    local key, failure = M.run_command(value or "")
    if failure then
      err:write("api_key_cmd failed: " .. failure .. "\n")
      return 1
    end
    if not key or key == "" then
      out:write("missing\n")
      return 2
    end
    out:write(string.format("found %d %s\n", #key, M.shape(key)))
    return 0
  end

  if (command ~= "get" and command ~= "check") or not M.valid_entry(value) then
    err:write("usage: api_key.lua get|check <entry> | check-cmd <command>\n")
    return 1
  end

  local key, failure, missing = M.read(value)
  if missing or (not failure and (not key or key == "")) then
    if command == "check" then
      out:write("missing\n")
    else
      err:write(
        string.format("No API key stored as %s/%s. Store it once with: %s\n", M.SERVICE, value, M.store_command(value))
      )
    end
    return 2
  end
  if not key then
    err:write("Reading the API key failed: " .. tostring(failure) .. "\n")
    return 1
  end
  if command == "check" then
    out:write(string.format("found %d %s\n", #key, M.shape(key)))
  else
    out:write(key .. "\n")
  end
  return 0
end

return M
