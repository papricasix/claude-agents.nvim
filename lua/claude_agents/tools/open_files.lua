--- Tool for the model: open files in the user's Neovim (see `claude_agents.open_files`).
---
--- Offered on the launch's tool server only, never on the IDE connection. The
--- schema depends on who launched the CLI: an agent lives in a view with no
--- window to split, so it is not offered `split`/`vsplit`.
local M = {}

M.name = "open_files"

---@param ctx { kind: string|nil }
---@return table|nil schema nil when the feature is off.
function M.schema(ctx)
  local open_files = require("claude_agents.open_files")
  if not open_files.enabled() then
    return nil
  end
  local agent = ctx and ctx.kind == "agent"
  local opts = open_files.opts()
  local layouts = agent and { "tab", "float" } or vim.deepcopy(open_files.LAYOUTS)
  local default_layout = opts.layout
  if agent and (default_layout == "split" or default_layout == "vsplit") then
    default_layout = "tab"
  end
  local default_focus = opts.focus ~= false

  local layout_text = agent
      and "Where the files go: 'tab' (a new tab) or 'float' (one file over the screen; q closes it)."
    or "Where the files go: 'tab' (a new tab), 'float' (one file over the screen; q closes it), "
      .. "'split' or 'vsplit' (a split per file beside the editor window next to this conversation's terminal)."

  return {
    description = "Open files in the user's Neovim, the editor this conversation runs in. "
      .. "Call this only when the user asks you to open or show a file in their editor "
      .. '("open the parser", "show me a.lua and b.lua side by side", "open it in a float"), '
      .. "never on your own initiative. Several files in one call open together: in one new tab, "
      .. "side by side, stacked or in a grid"
      .. (agent and "" or ", or in one split each")
      .. ". A single file that is already visible in some window is jumped to instead of opened again, "
      .. (agent and "unless a float was asked for. " or "unless a float or split was asked for. ")
      .. ("Defaults: layout '%s', focus %s."):format(default_layout, tostring(default_focus)),
    inputSchema = {
      type = "object",
      properties = {
        files = {
          type = "array",
          minItems = 1,
          description = "The files, in the order they should appear.",
          items = {
            type = "object",
            properties = {
              path = {
                type = "string",
                description = "Absolute path; a relative one is taken from this conversation's working directory.",
              },
              line = {
                type = "integer",
                minimum = 1,
                description = "Line to put the cursor on (centred).",
              },
              end_line = {
                type = "integer",
                minimum = 1,
                description = "Last line of a range to highlight, starting at line.",
              },
            },
            required = { "path" },
            additionalProperties = false,
          },
        },
        layout = {
          type = "string",
          enum = layouts,
          description = layout_text .. " Omit it unless the user named one.",
        },
        arrangement = {
          type = "string",
          enum = vim.deepcopy(open_files.ARRANGEMENTS),
          description = "Several files in one tab: 'vertical' puts them side by side (the default), "
            .. "'horizontal' stacks them, 'grid' lays them out in rows and columns (4 files: 2×2).",
        },
        focus = {
          type = "boolean",
          description = "Whether the user's cursor moves to the opened file. false keeps it where it is "
            .. '("open it in the background"). A float always takes the cursor. Omit it unless the user said.',
        },
      },
      required = { "files" },
      additionalProperties = false,
      ["$schema"] = "http://json-schema.org/draft-07/schema#",
    },
  }
end

---@param params table|nil
---@return table result MCP tool result; a refusal is `isError` text the model reads.
function M.handler(params)
  local open_files = require("claude_agents.open_files")
  local asker = open_files.asker(require("claude_agents.request_context").get())
  local result, err = open_files.open(params or {}, asker)
  if not result then
    return { content = { { type = "text", text = err and err.message or "Could not open the files" } }, isError = true }
  end
  return { content = { { type = "text", text = result.message } } }
end

return M
