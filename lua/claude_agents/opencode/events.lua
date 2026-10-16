---@brief [[
--- One event stream from the OpenCode service, shared by everything that listens.
---
--- `GET /api/event` carries every event of every location on the service, as
--- server-sent events whose data is the event's JSON:
--- `{ id, created, type, location = { directory }, data, durable }`. The stream
--- is volatile by contract — a slow consumer overflows and fails it, and events
--- in a gap are not replayed — so it is reopened with a backoff, and each
--- (re)open is announced as a `stream.connected` event of our own, which is the
--- cue for listeners to re-read what they show instead of trusting the gap.
---
--- Opened by the first subscriber, closed when the last one leaves.
---@brief ]]
---@module 'claude_agents.opencode.events'

local logger = require("claude_agents.logger")

local M = {}

M._http = require("claude_agents.opencode.http")
M._service = require("claude_agents.opencode.service")
M._defer = function(fn, ms)
  vim.defer_fn(fn, ms)
end

--- What a (re)opened stream is announced as.
M.CONNECTED = "stream.connected"

local subscribers = {}
local next_id = 0
local stream = nil
local backoff = 1000
local MAX_BACKOFF = 15000
local generation = 0

local function emit(event)
  for _, fn in pairs(subscribers) do
    local ok, err = pcall(fn, event)
    if not ok then
      logger.debug("opencode", "event listener failed:", tostring(err))
    end
  end
end

local function has_subscribers()
  return next(subscribers) ~= nil
end

local open

local function schedule_reopen(gen)
  local delay = backoff
  backoff = math.min(backoff * 2, MAX_BACKOFF)
  M._defer(function()
    if gen == generation and has_subscribers() and not stream then
      open()
    end
  end, delay)
end

open = function()
  local gen = generation
  -- Never starts the service: a launch does that before anything is followed,
  -- and a listener that merely browses (the agents view) must not.
  M._service.find(function(err, conn)
    if gen ~= generation or not has_subscribers() or stream then
      return
    end
    if err or not conn then
      logger.debug("opencode", "event stream: no service yet:", tostring(err))
      schedule_reopen(gen)
      return
    end
    stream = M._http.stream({
      url = conn.url,
      path = "/api/event",
      auth = { user = M._service.USER, password = conn.password },
      timeout_ms = 0,
    }, {
      on_open = function()
        if gen ~= generation then
          return
        end
        backoff = 1000
        emit({ type = M.CONNECTED, data = {} })
      end,
      on_event = function(raw)
        if gen ~= generation then
          return
        end
        local event = M._http.decode(raw.data)
        if type(event) == "table" and type(event.type) == "string" then
          emit(event)
        end
      end,
      on_close = function(close_err)
        if gen ~= generation then
          return
        end
        stream = nil
        logger.debug("opencode", "event stream closed:", tostring(close_err))
        -- The service may have restarted on another port: read its registration
        -- again rather than knocking on the old one.
        M._service.invalidate()
        if has_subscribers() then
          schedule_reopen(gen)
        end
      end,
    })
  end)
end

---Listen to every event. Opens the stream when it is the first listener.
---@param fn fun(event: table)
---@return fun() unsubscribe
function M.subscribe(fn)
  next_id = next_id + 1
  local id = next_id
  subscribers[id] = fn
  if not stream then
    open()
  end
  return function()
    subscribers[id] = nil
    if not has_subscribers() then
      M.stop()
    end
  end
end

---Close the stream; listeners stay registered only if they subscribe again.
function M.stop()
  generation = generation + 1
  if stream then
    pcall(stream.close)
  end
  stream = nil
  backoff = 1000
end

---Hand an event to the listeners as if the stream had delivered it (specs).
---@param event table
function M._emit(event)
  emit(event)
end

---Test/reload helper.
function M._reset()
  M.stop()
  subscribers = {}
end

return M
