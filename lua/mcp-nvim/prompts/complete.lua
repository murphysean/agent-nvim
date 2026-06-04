local prompts = require("mcp-nvim.mcp.prompts")

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

prompts.register("complete", {
  description = "Generate a code completion at the current cursor position. Returns context-rich prompt with surrounding code, file type, and cursor location. The agent should ONLY use neovim MCP tools to insert the completion.",
  arguments = {
    {
      name = "instructions",
      description = "Optional hint about what to complete (e.g. 'implement the error handling', 'finish this function')",
      required = false,
    },
  },
}, function(args)
  local ctx = get_context()
  local instructions = args.instructions or "Complete the code at the cursor position."

  local system = table.concat({
    "You are a code completion agent with direct access to a Neovim editor via MCP tools.",
    "Your ONLY job is to generate and insert code at the cursor position.",
    "Do NOT explain what you're doing. Do NOT ask questions. Just write the code.",
    "",
    "Rules:",
    "- Use ONLY the neovim MCP tools (buffer_insert, buffer_set_lines, buffer_set_text) to make changes.",
    "- Match the existing code style, indentation, and conventions exactly.",
    "- Insert only what's needed — no surrounding boilerplate the user didn't ask for.",
    "- If the completion is multi-line, use buffer_set_lines or buffer_insert.",
    "- After inserting, place the cursor at the end of the insertion with cursor_set.",
  }, "\n")

  local context = table.concat({
    string.format("File: %s", ctx.filename ~= "" and ctx.filename or "[unsaved]"),
    string.format("Language: %s", ctx.filetype),
    string.format("Cursor: line %d, col %d (of %d lines total)", ctx.row, ctx.col, ctx.total_lines),
    "",
    "--- Code before cursor (up to 50 lines) ---",
    ctx.before,
    "",
    string.format("--- Current line (cursor here, col %d) ---", ctx.col),
    ctx.current_line,
    "",
    "--- Code after cursor (up to 50 lines) ---",
    ctx.after,
  }, "\n")

  return {
    description = "Complete code at cursor",
    messages = {
      {
        role = "user",
        content = { type = "text", text = string.format("%s\n\n%s\n\nInstructions: %s", system, context, instructions) },
      },
    },
  }
end)
