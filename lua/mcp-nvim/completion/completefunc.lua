--- completefunc-based AI completion for mcp-nvim.
--- Provides AI completion via <C-x><C-u> (completefunc) and <C-x><C-o> (omnifunc)
--- when those functions are unclaimed by other plugins/LSP.
---
--- Flow:
--- 1. User presses <C-x><C-u> or <C-x><C-o> in insert mode
--- 2. We immediately fire the sampling request (no popup, no confirmation needed)
--- 3. Show virtual text "-- generating..." at cursor
--- 4. Insert result at cursor when it arrives
---
--- The user's intent is unambiguous — they pressed the keybind, so we just go.

local M = {}

local ns = vim.api.nvim_create_namespace("mcp_nvim_completefunc")
local pending = false

--- Trigger keywords — if the user typed one of these before triggering,
--- we erase it (it was just to summon us, not actual code).
local TRIGGER_KEYWORDS = {
  ai = true,
  autocomplete = true,
  llm = true,
  fillmein = true,
  helpme = true,
  complete = true,
  gen = true,
}

--- The completefunc/omnifunc implementation.
--- Called with (findstart, base):
---   findstart=1: return column where keyword starts
---   findstart=0: return list of completion items
---
--- We return an empty list and fire the AI completion immediately via vim.schedule.
--- This avoids the confusing popup-accept dance for a single async item.
function M.completefunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = col
    while start > 0 and line:sub(start, start):match("[%w_]") do
      start = start - 1
    end
    return start
  end

  -- Gate on sampling availability
  local completion = require("mcp-nvim.completion")
  if not completion.sampling_available() then
    return {}
  end

  -- Fire immediately — no popup needed. The user's intent is clear.
  vim.schedule(function()
    M.fire(base)
  end)

  -- Return empty so vim doesn't show a popup
  return {}
end

--- Fire the AI completion directly.
--- Erases trigger keyword if applicable, shows generating indicator, fires sampling.
---@param trigger_word string|nil The word the user typed before triggering
function M.fire(trigger_word)
  if pending then
    vim.notify("AI completion already in progress", vim.log.levels.INFO)
    return
  end
  pending = true

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  -- Erase the trigger keyword if it was one of our keywords
  trigger_word = trigger_word or ""
  if TRIGGER_KEYWORDS[trigger_word:lower()] and #trigger_word > 0 then
    local kw_start = col - #trigger_word
    if kw_start >= 0 then
      vim.api.nvim_buf_set_text(buf, row, kw_start, row, col, { "" })
      col = kw_start
      pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
    end
  end

  -- Show generating virtual text
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { "-- generating...", "Comment" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })

  -- Fire sampling
  local sessions = require("mcp-nvim.sessions")
  local sampling = require("mcp-nvim.mcp.sampling")
  local context_mod = require("mcp-nvim.prompts.context")
  local templates = require("mcp-nvim.prompts.template_engine")

  local session_list = sessions.list()
  if #session_list == 0 then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.notify("No active MCP session", vim.log.levels.WARN)
    pending = false
    return
  end

  local session_id = session_list[1].id
  local ctx = context_mod.gather({ mode = "insert", selection = "" })
  local system = templates.load_and_render("autocomplete", ctx)

  if not system then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.notify("Template error", vim.log.levels.ERROR)
    pending = false
    return
  end

  sampling.create_message({
    messages = {
      { role = "user", content = { type = "text", text = "Complete the code at the cursor position. Return only the text to insert inline." } },
    },
    systemPrompt = system,
    maxTokens = 256,
  }, function(result, err)
    vim.schedule(function()
      pending = false
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

      if err then
        vim.notify("AI completion error: " .. vim.inspect(err), vim.log.levels.ERROR)
        return
      end

      local text = result and result.content and result.content.text or ""
      text = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
      text = text:gsub("^\n", ""):gsub("\n$", "")

      if text == "" then
        vim.notify("AI completion returned empty", vim.log.levels.WARN)
        return
      end

      -- Detect if we need a leading space (cursor at end of a keyword)
      if col > 0 then
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
        local char_before = line:sub(col, col)
        if char_before:match("[%w_]") and not text:match("^%s") then
          text = " " .. text
        end
      end

      local lines = vim.split(text, "\n", { plain = true })
      vim.api.nvim_buf_set_text(buf, row, col, row, col, lines)

      local last_line_idx = row + #lines - 1
      local last_line_col = (#lines == 1) and (col + #lines[1]) or #lines[#lines]
      pcall(vim.api.nvim_win_set_cursor, 0, { last_line_idx + 1, last_line_col })

      vim.notify(string.format("AI completion inserted (%d lines)", #lines), vim.log.levels.INFO)
    end)
  end, session_id)
end

return M

