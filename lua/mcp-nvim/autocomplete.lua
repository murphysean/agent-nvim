local M = {}

--- Get the visual selection text and range from '< '> marks.
--- Returns selection_text, start_row (1-indexed), end_row (1-indexed), or nil.
local function get_visual_selection(buf)
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  if start_pos[1] == 0 and end_pos[1] == 0 then
    return nil, nil, nil
  end

  local start_row = start_pos[1]
  local end_row = end_pos[1]

  local lines = vim.api.nvim_buf_get_lines(buf, start_row - 1, end_row, false)
  return table.concat(lines, "\n"), start_row, end_row
end

--- Determine the completion mode and what range to replace.
--- Returns: mode ("normal"|"visual"|"insert"), selection_text, replace_start (0-indexed), replace_end (0-indexed)
local function detect_mode(buf, cursor_row_0)
  -- Check if we were in visual mode (command from visual leaves marks)
  local sel_text, sel_start, sel_end = get_visual_selection(buf)

  -- Heuristic: if the visual marks encompass the cursor and are "recent"
  -- (we can't know for sure from command mode, but if marks are set we use them)
  local last_mode = vim.fn.mode(1)

  -- If called from visual mode command (:'<,'>McpAutoComplete), use selection
  if sel_text and sel_start and sel_end then
    -- Check if cursor is within or near the selection (command exits visual)
    local cursor_1 = cursor_row_0 + 1
    if cursor_1 >= sel_start and cursor_1 <= sel_end then
      return "visual", sel_text, sel_start - 1, sel_end
    end
  end

  -- Check if we're in insert mode
  if last_mode:match("^i") then
    return "insert", "", cursor_row_0, cursor_row_0
  end

  -- Normal mode: operate on the current line
  local line = vim.api.nvim_buf_get_lines(buf, cursor_row_0, cursor_row_0 + 1, false)[1] or ""

  -- If current line is blank or just whitespace, replace it
  if line:match("^%s*$") then
    return "normal", "", cursor_row_0, cursor_row_0 + 1
  end

  -- If current line looks like a placeholder/todo/stub, replace it
  if line:match("TODO") or line:match("FIXME") or line:match("%.%.%.") or line:match("pass$") then
    return "normal", line, cursor_row_0, cursor_row_0 + 1
  end

  -- Otherwise, insert after the current line
  return "normal", "", cursor_row_0 + 1, cursor_row_0 + 1
end

--- Trigger an AI-powered code completion via sampling/createMessage.
--- Gathers rich editor context, renders the prompt template, and inserts the result.
---@param hint string|nil Optional user instruction (e.g. "implement error handling")
---@param visual boolean|nil Whether invoked from visual mode
function M.complete(hint, visual)
  local sessions = require("mcp-nvim.sessions")
  local sampling = require("mcp-nvim.mcp.sampling")
  local context_mod = require("mcp-nvim.prompts.context")
  local templates = require("mcp-nvim.prompts.template_engine")

  local session_list = sessions.list()
  if #session_list == 0 then
    vim.notify("No active MCP session — is Goose connected?", vim.log.levels.WARN)
    return
  end

  local session_id = session_list[1].id

  -- Snapshot buffer state before async call
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row_0 = cursor[1] - 1
  local cursor_col = cursor[2]

  -- Detect mode and determine replacement range
  local mode, selection, replace_start, replace_end

  if visual then
    local sel_text, sel_start_1, sel_end_1 = get_visual_selection(buf)
    if sel_text then
      mode = "visual"
      selection = sel_text
      replace_start = sel_start_1 - 1
      replace_end = sel_end_1
    else
      mode = "normal"
      selection = ""
      replace_start = cursor_row_0 + 1
      replace_end = cursor_row_0 + 1
    end
  else
    mode, selection, replace_start, replace_end = detect_mode(buf, cursor_row_0)
  end

  -- Gather context
  local ctx = context_mod.gather({ mode = mode, selection = selection })

  -- Add hint to intent if provided
  if hint and hint ~= "" then
    ctx.intent = ctx.intent .. " User hint: " .. hint
  end

  -- Render the system prompt from the template
  local system, err = templates.load_and_render("autocomplete", ctx)
  if not system then
    vim.notify("Template error: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- User message
  local user_msg = hint or "Complete the code at the cursor position."

  vim.notify(string.format("Requesting AI completion [%s]...", mode), vim.log.levels.INFO)

  sampling.create_message({
    messages = {
      { role = "user", content = { type = "text", text = user_msg } },
    },
    systemPrompt = system,
    maxTokens = 512,
  }, function(result, sampling_err)
    vim.schedule(function()
      if sampling_err then
        vim.notify("Completion error: " .. vim.inspect(sampling_err), vim.log.levels.ERROR)
        return
      end

      local text = nil
      if result and result.content then
        text = result.content.text
      end

      if not text or text == "" then
        vim.notify("Completion returned empty", vim.log.levels.WARN)
        return
      end

      -- Strip markdown code fences if the LLM ignores our instructions
      text = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")

      -- Strip single leading/trailing blank lines (LLM artifact)
      text = text:gsub("^\n", ""):gsub("\n$", "")

      if text == "" then
        vim.notify("Completion returned empty (after cleanup)", vim.log.levels.WARN)
        return
      end

      local new_lines = vim.split(text, "\n", { plain = true })

      -- Determine indentation from context
      local indent = ""
      if mode == "insert" then
        -- Match indent of the current line
        local current = vim.api.nvim_buf_get_lines(buf, cursor_row_0, cursor_row_0 + 1, false)[1] or ""
        indent = current:match("^(%s*)") or ""
      elseif mode == "normal" or mode == "visual" then
        -- Match indent of the line at replace_start (or the line above if inserting)
        local ref_row = replace_start
        if replace_start == replace_end then
          -- Inserting (not replacing) — use the line above as reference
          ref_row = math.max(0, replace_start - 1)
        end
        local ref_line = vim.api.nvim_buf_get_lines(buf, ref_row, ref_row + 1, false)[1] or ""
        indent = ref_line:match("^(%s*)") or ""
      end

      -- Apply indentation to lines that don't already have it
      -- (skip first line if inserting inline in insert mode)
      local apply_indent_from = 1
      if mode == "insert" then
        -- In insert mode, first line goes at cursor col — no extra indent needed
        apply_indent_from = 2
      else
        -- For normal/visual, only indent lines that have less indentation than expected
        for i = 1, #new_lines do
          local line_indent = new_lines[i]:match("^(%s*)") or ""
          if #line_indent == 0 and new_lines[i] ~= "" then
            new_lines[i] = indent .. new_lines[i]
          end
        end
        apply_indent_from = #new_lines + 1 -- skip the loop below
      end

      for i = apply_indent_from, #new_lines do
        if new_lines[i] ~= "" then
          local line_indent = new_lines[i]:match("^(%s*)") or ""
          if #line_indent == 0 then
            new_lines[i] = indent .. new_lines[i]
          end
        end
      end

      -- Insert the completion
      if mode == "insert" then
        -- Character-level insertion at exact cursor position
        vim.api.nvim_buf_set_text(buf, cursor_row_0, cursor_col, cursor_row_0, cursor_col, new_lines)
      else
        -- Line-level replacement for normal/visual modes
        vim.api.nvim_buf_set_lines(buf, replace_start, replace_end, false, new_lines)
      end

      vim.notify(string.format("Completion applied (%d lines, %s mode)", #new_lines, mode), vim.log.levels.INFO)
    end)
  end, session_id)
end

return M

