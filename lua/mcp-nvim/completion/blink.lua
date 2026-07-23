--- blink.cmp source for MCP AI completion.
--- Shows a placeholder item in the completion menu. On accept, fires a
--- sampling/createMessage request and inserts the result at the cursor.
--- While waiting, displays virtual text "-- generating..." at the cursor.
---
--- This module is registered dynamically by mcp-nvim on startup — users
--- don't need to configure anything if blink.cmp is installed.

--- @class mcp-nvim.BlinkSource : blink.cmp.Source
local source = {}

--- Namespace for virtual text indicators
local ns = vim.api.nvim_create_namespace("mcp_nvim_completion")

--- Track active generation state
local active_generation = nil

--- Trigger keywords that explicitly invoke AI completion.
--- When the user types one of these and selects our item, we erase the keyword
--- before sending context to the LLM (it was just a trigger, not real code).
local TRIGGER_KEYWORDS = {
  ai = true,
  autocomplete = true,
  llm = true,
  fillmein = true,
  helpme = true,
  complete = true,
  gen = true,
}

--- Check whether sampling is available (session + client capability).
local function sampling_available()
  local ok, sessions = pcall(require, "mcp-nvim.sessions")
  if not ok or #sessions.list() == 0 then
    return false
  end
  local protocol = require("mcp-nvim.mcp.protocol")
  return protocol.client_supports("sampling")
end

--- Show virtual text placeholder while generating
---@param buf number Buffer number
---@param row number 0-indexed row
local function show_generating(buf, row)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { "-- generating...", "Comment" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
  active_generation = { buf = buf, row = row }
end

--- Clear virtual text placeholder
---@param buf number Buffer number
local function clear_generating(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  active_generation = nil
end

--- Extract the keyword at cursor from context.
--- Returns: keyword string, keyword_start (0-indexed col), keyword_end (0-indexed col)
local function get_keyword_at_cursor(context)
  local cursor_col = context.cursor and context.cursor[2] or 0
  local line = context.line or ""
  local start_col = cursor_col
  while start_col > 0 and line:sub(start_col, start_col):match("[%w_]") do
    start_col = start_col - 1
  end
  local keyword = line:sub(start_col + 1, cursor_col)
  return keyword, start_col, cursor_col
end

function source.new(opts, config)
  local self = setmetatable({}, { __index = source })
  return self
end

--- We don't need trigger characters — the item is always available.
function source:get_trigger_characters()
  return {}
end

--- Return a single placeholder item instantly.
--- We set is_incomplete_forward = true so blink re-queries us on each keystroke,
--- and we dynamically set filterText to match the current keyword.
function source:get_completions(context, callback)
  if not sampling_available() then
    callback(nil)
    return
  end

  -- Don't show AI completion in chat buffers — it's for code buffers only.
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  if ft == "mcpchat" then
    callback(nil)
    return
  end

  local CompletionItemKind = require("blink.cmp.types").CompletionItemKind

  local keyword = get_keyword_at_cursor(context)

  callback({
    is_incomplete_forward = true,
    is_incomplete_backward = true,
    items = {
      {
        label = "✨ AI Complete",
        kind = CompletionItemKind.Text,
        insertText = "",
        documentation = {
          kind = "markdown",
          value = "Generate AI code completion at cursor via MCP sampling.\n\nAccept this item to trigger AI generation.\n\n**Trigger words:** `ai`, `autocomplete`, `llm`, `fillmein`, `helpme`, `complete`, `gen`",
        },
        -- Match whatever the user has typed so we always appear
        filterText = keyword ~= "" and keyword or "ai",
        -- Sort it at the bottom
        sortText = "~~~~ai",
        -- Custom data
        data = { mcp_ai_complete = true, keyword = keyword },
      },
    },
  })
end

--- Only show if sampling is available
function source:should_show_items(context, items)
  if not sampling_available() then
    return false
  end
  -- Don't show in chat buffers.
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  if ft == "mcpchat" then
    return false
  end
  return true
end

--- Execute: fires when the user accepts/confirms the AI completion item.
--- Erases any trigger keyword, shows virtual text, fires sampling, inserts result.
function source:execute(context, item, callback, default_implementation)
  local sessions = require("mcp-nvim.sessions")
  local sampling = require("mcp-nvim.mcp.sampling")
  local context_mod = require("mcp-nvim.prompts.context")
  local templates = require("mcp-nvim.prompts.template_engine")

  local session_list = sessions.list()
  if #session_list == 0 then
    vim.notify("No active MCP session", vim.log.levels.WARN)
    callback()
    return
  end

  local session_id = session_list[1].id

  -- Snapshot state
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  -- Determine what keyword the user typed to trigger us
  local keyword = item.data and item.data.keyword or ""
  local keyword_lower = keyword:lower()
  local is_trigger_keyword = TRIGGER_KEYWORDS[keyword_lower]

  -- If it's a trigger keyword, erase it from the buffer before sending to LLM
  -- The keyword occupies [col - #keyword, col) on the current row
  local erase_start = col - #keyword
  if is_trigger_keyword and #keyword > 0 and erase_start >= 0 then
    vim.api.nvim_buf_set_text(buf, row, erase_start, row, col, { "" })
    col = erase_start
    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
  end

  -- Show generating indicator
  show_generating(buf, row)

  -- Dismiss the completion menu immediately — insertion happens async
  callback()

  -- Gather context (insert mode, after erasing trigger keyword)
  local ctx = context_mod.gather({ mode = "insert", selection = "" })

  -- Render prompt
  local system, err = templates.load_and_render("autocomplete", ctx)
  if not system then
    clear_generating(buf)
    vim.notify("Template error: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end

  local user_msg = "Complete the code at the cursor position. Return only the text to insert inline."

  -- Fire sampling request
  sampling.create_message({
    messages = {
      { role = "user", content = { type = "text", text = user_msg } },
    },
    systemPrompt = system,
    maxTokens = 256,
  }, function(result, sampling_err)
    vim.schedule(function()
      clear_generating(buf)

      if sampling_err then
        vim.notify("AI completion error: " .. vim.inspect(sampling_err), vim.log.levels.ERROR)
        return
      end

      local text = nil
      if result and result.content then
        text = result.content.text
      end

      if not text or text == "" then
        vim.notify("AI completion returned empty", vim.log.levels.WARN)
        return
      end

      -- Strip markdown fences
      text = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
      -- Strip leading/trailing blank lines
      text = text:gsub("^\n", ""):gsub("\n$", "")

      if text == "" then
        vim.notify("AI completion returned empty (after cleanup)", vim.log.levels.WARN)
        return
      end

      -- Detect if we need a leading space (cursor glued to end of keyword)
      if col > 0 then
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
        local char_before = line:sub(col, col)
        if char_before:match("[%w_]") and not text:match("^%s") then
          text = " " .. text
        end
      end

      -- Insert at the cursor position
      local lines = vim.split(text, "\n", { plain = true })
      vim.api.nvim_buf_set_text(buf, row, col, row, col, lines)

      -- Move cursor to end of insertion
      local last_line_idx = row + #lines - 1
      local last_line_col = (#lines == 1) and (col + #lines[1]) or #lines[#lines]
      pcall(vim.api.nvim_win_set_cursor, 0, { last_line_idx + 1, last_line_col })

      vim.notify(string.format("AI completion inserted (%d lines)", #lines), vim.log.levels.INFO)
    end)
  end, session_id)
end

return source
