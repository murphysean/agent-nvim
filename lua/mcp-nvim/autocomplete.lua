local M = {}

--- Capture buffer context around the cursor (reuses prompts/complete pattern).
local function get_context()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  local before_start = math.max(0, row - 51)
  local before_lines = vim.api.nvim_buf_get_lines(buf, before_start, row - 1, false)
  local current_line = lines[row] or ""
  local after_end = math.min(#lines, row + 50)
  local after_lines = vim.api.nvim_buf_get_lines(buf, row, after_end, false)

  return {
    filename = filename,
    filetype = ft,
    row = row,
    col = cursor[2],
    current_line = current_line,
    before = table.concat(before_lines, "\n"),
    after = table.concat(after_lines, "\n"),
    total_lines = #lines,
  }
end

--- Build the sampling prompt for code completion.
local function build_prompt()
  local ctx = get_context()

  local system = table.concat({
    "You are a code completion engine. Return ONLY the code to insert — no explanations, no backticks, no markdown.",
    "",
    "Rules:",
    "- Return raw code that can be inserted directly at the cursor position.",
    "- Match the existing code style, indentation, and conventions exactly.",
    "- Return only what should be added — never repeat existing code.",
    "- If the completion continues the current line, start from the cursor column.",
  }, "\n")

  local context = table.concat({
    string.format("File: %s", ctx.filename ~= "" and ctx.filename or "[unsaved]"),
    string.format("Language: %s", ctx.filetype),
    string.format("Cursor: line %d, col %d (of %d lines total)", ctx.row, ctx.col, ctx.total_lines),
    "",
    "--- Code before cursor ---",
    ctx.before,
    "",
    string.format("--- Current line (cursor at col %d) ---", ctx.col),
    ctx.current_line,
    "",
    "--- Code after cursor ---",
    ctx.after,
  }, "\n")

  return system, context
end

--- Trigger an AI-powered code completion via sampling/createMessage.
--- Inserts the result at the current cursor position.
function M.complete()
  local sessions = require("mcp-nvim.sessions")
  local sampling = require("mcp-nvim.mcp.sampling")

  -- Find an active session to target
  local session_list = sessions.list()
  if #session_list == 0 then
    vim.notify("No active MCP session — is Goose connected?", vim.log.levels.WARN)
    return
  end

  local session_id = session_list[1].id
  local system, context = build_prompt()

  vim.notify("Requesting AI completion...", vim.log.levels.INFO)

  sampling.create_message({
    messages = {
      { role = "user", content = { type = "text", text = context } },
    },
    systemPrompt = system,
    maxTokens = 256,
  }, function(result, err)
    vim.schedule(function()
      if err then
        vim.notify("Completion error: " .. vim.inspect(err), vim.log.levels.ERROR)
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

      -- Get current cursor position for insertion
      local buf = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1  -- 0-indexed for nvim_buf_set_text
      local col = cursor[2]      -- already 0-indexed

      -- If the completion starts on a new line, use buffer_set_lines
      if text:find("^\n") or text:find("[\r\n]") then
        local lines = vim.split(text, "\n", { plain = true })
        -- Insert at the next line, preserving indentation
        vim.api.nvim_buf_set_lines(buf, row + 1, row + 1, false, lines)
      else
        -- Inline completion on the current line
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        local new_line = line:sub(1, col) .. text .. line:sub(col + 1)
        vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { new_line })
      end

      vim.notify("Completion applied", vim.log.levels.INFO)
    end)
  end, session_id)
end

return M

