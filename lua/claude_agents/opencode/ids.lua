---@brief [[
--- OpenCode session ids, minted the way OpenCode mints them.
---
--- A launch names its conversation before the TUI starts (`--session <id>`),
--- like `--session-id` for Claude. OpenCode accepts any id starting with `ses`,
--- but its own lists sort ids as strings and its ids are built to sort newest
--- first, so a plugin id is built the same way:
---
---   `ses_` .. 12 hex digits .. 14 base62 characters
---
--- where the hex is `(2^48 - 1) - ((ms mod 2^36) * 4096 + counter)`: the
--- millisecond clock times 4096 plus a per-millisecond counter, kept to 48 bits
--- and inverted. Every step stays below 2^53, so doubles compute it exactly.
--- Checked against ids OpenCode 2.0.30 generated itself.
---@brief ]]
---@module 'claude_agents.opencode.ids'

local M = {}

local BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local TWO_36 = 68719476736 -- 2^36
local TWO_48_MINUS_1 = 281474976710655 -- 2^48 - 1
local TWO_24 = 16777216

local last_ms, counter = nil, 0

--- Injectable clock (epoch milliseconds) and randomness, for specs.
M._now_ms = function()
  local ok, sec, usec = pcall(function()
    return (vim.uv or vim.loop).gettimeofday()
  end)
  if ok and type(sec) == "number" then
    return sec * 1000 + math.floor((tonumber(usec) or 0) / 1000)
  end
  return os.time() * 1000
end

M._random_bytes = function(n)
  return require("claude_agents.utils").random_bytes(n)
end

---The 12 hex digits for a moment and a counter.
---@param ms number Epoch milliseconds.
---@param count integer 1-based counter within that millisecond.
---@return string
function M.time_part(ms, count)
  local x = (ms % TWO_36) * 4096 + count
  local inverted = TWO_48_MINUS_1 - x
  local high = math.floor(inverted / TWO_24)
  local low = inverted % TWO_24
  return string.format("%06x%06x", high, low)
end

---A fresh OpenCode session id.
---@return string
function M.new_session_id()
  local ms = math.floor(M._now_ms())
  if ms == last_ms then
    counter = counter + 1
  else
    last_ms, counter = ms, 1
  end
  local bytes = M._random_bytes(14)
  local tail = {}
  for i = 1, 14 do
    local b = bytes:byte(i) or 0
    tail[i] = BASE62:sub(b % 62 + 1, b % 62 + 1)
  end
  return "ses_" .. M.time_part(ms, counter) .. table.concat(tail)
end

return M
