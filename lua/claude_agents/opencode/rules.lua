---@brief [[
--- The permission rules that make OpenCode ask before editing, without making
--- it ask where it would have refused.
---
--- OpenCode evaluates a session's own rules after its agent's, and the last
--- matching rule wins (`action`/`resource` with whole-value `*` and `?`). A bare
--- `{ edit, *, ask }` on the session would therefore turn every refusal into a
--- question: the `plan` agent's "no edits outside the plan folder", `explore`'s
--- read-only policy, a user's own `deny` for a path. So the session gets the
--- ask rule followed by every rule of its agent that can decide an edit —
--- rewritten to the `edit` action, so a copied `* * deny` cannot reach other
--- actions — except catch-all allows, which are exactly what the ask replaces.
--- For any path the agent's own specific rules still decide; only what would
--- have been allowed by default now asks.
---@brief ]]
---@module 'claude_agents.opencode.rules'

local M = {}

M.ASK = { action = "edit", resource = "*", effect = "ask" }

---OpenCode's whole-value wildcard match: `*` is any run of characters
---(including `/`), `?` exactly one, everything else literal.
---@param pattern string
---@param value string
---@return boolean
function M.wildcard(pattern, value)
  if type(pattern) ~= "string" or type(value) ~= "string" then
    return false
  end
  local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
  return value:match(lua) ~= nil
end

---@param a table
---@param b table
---@return boolean
local function same_rule(a, b)
  return a.action == b.action and a.resource == b.resource and a.effect == b.effect
end

---The rules the plugin adds for an agent.
---@param agent_rules table[]|nil The agent's effective ruleset, in order.
---@return table[]
function M.for_agent(agent_rules)
  local added = { vim.deepcopy(M.ASK) }
  for _, rule in ipairs(type(agent_rules) == "table" and agent_rules or {}) do
    if type(rule) == "table" and M.wildcard(rule.action, "edit") then
      local catch_all_allow = rule.effect == "allow" and rule.resource == "*"
      if not catch_all_allow then
        added[#added + 1] = { action = "edit", resource = rule.resource, effect = rule.effect }
      end
    end
  end
  return added
end

---A session's rules with the plugin's rules for an agent in place of any the
---plugin added before. The user's own session rules keep their order, ahead.
---@param current table[]|nil The session's rules now.
---@param previous table[]|nil What the plugin added last time (from the session's metadata).
---@param agent_rules table[]|nil The agent's effective ruleset.
---@return table[] rules The session's new rules.
---@return table[] added What the plugin added this time, to record.
function M.compose(current, previous, agent_rules)
  current = type(current) == "table" and current or {}
  previous = type(previous) == "table" and previous or {}
  -- The plugin's rules are always the tail; drop that tail if it is still there.
  local keep = #current
  if #previous > 0 and #current >= #previous then
    local matches = true
    for i = 1, #previous do
      if not same_rule(current[#current - #previous + i], previous[i]) then
        matches = false
        break
      end
    end
    if matches then
      keep = #current - #previous
    end
  end
  local rules = {}
  for i = 1, keep do
    rules[#rules + 1] = vim.deepcopy(current[i])
  end
  local added = M.for_agent(agent_rules)
  for _, rule in ipairs(added) do
    rules[#rules + 1] = rule
  end
  return rules, added
end

---A session's rules without the plugin's (review switched off, or the agent
---switched to one with nothing to ask about).
---@param current table[]|nil
---@param previous table[]|nil
---@return table[]
function M.strip(current, previous)
  local rules = M.compose(current, previous, nil)
  table.remove(rules) -- the ask rule compose just appended
  return rules
end

---What OpenCode would decide for an edit of `path` under a ruleset (last match
---wins; nothing matching means ask). Used by specs and the health check.
---@param rules table[]
---@param path string
---@return "allow"|"deny"|"ask"
function M.evaluate(rules, path)
  local effect = "ask"
  for _, rule in ipairs(rules or {}) do
    if M.wildcard(rule.action, "edit") and M.wildcard(rule.resource, path) then
      effect = rule.effect
    end
  end
  return effect
end

return M
