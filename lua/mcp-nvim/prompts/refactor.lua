local prompts = require("mcp-nvim.mcp.prompts")

local function get_selection_context()
  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  local total_lines = vim.api.nvim_buf_line_count(buf)

  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")

  if start_line == 0 or end_line == 0 or start_line == end_line then
    local cursor = vim.api.nvim_win_get_cursor(0)
    start_line = math.max(1, cursor[1] - 25)
    end_line = math.min(total_lines, cursor[1] + 25)
  end

  local selected = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local numbered = {}
  for i, line in ipairs(selected) do
    table.insert(numbered, string.format("%4d | %s", start_line + i - 1, line))
  end

  local before_start = math.max(0, start_line - 11)
  local before = vim.api.nvim_buf_get_lines(buf, before_start, start_line - 1, false)
  local after_end = math.min(total_lines, end_line + 10)
  local after = vim.api.nvim_buf_get_lines(buf, end_line, after_end, false)

  return {
    filename = filename,
    filetype = ft,
    start_line = start_line,
    end_line = end_line,
    code = table.concat(numbered, "\n"),
    before = table.concat(before, "\n"),
    after = table.concat(after, "\n"),
  }
end

prompts.register("refactor", {
  description = "Refactor the selected code region or the function at cursor. Applies changes directly via MCP tools. Preserves behavior while improving structure.",
  arguments = {
    {
      name = "instructions",
      description = "What kind of refactoring to perform (e.g. 'extract into a function', 'simplify', 'add error handling')",
      required = false,
    },
  },
}, function(args)
  local ctx = get_selection_context()
  local instructions = args.instructions
    or "Improve the structure and clarity of this code while preserving its behavior."

  local system = table.concat({
    "You are a code refactoring agent with direct access to a Neovim editor via MCP tools.",
    "Your ONLY job is to refactor the specified code region.",
    "Do NOT explain what you're doing. Apply the refactoring directly.",
    "",
    "Rules:",
    "- Use ONLY neovim MCP tools (buffer_edit, edit_file) to make changes.",
    "- Preserve the external behavior — inputs and outputs must remain the same.",
    "- Match the existing code style (indentation, naming conventions, patterns).",
    "- If the refactoring requires changes elsewhere in the file (e.g. new imports), make those too.",
    "- Use lsp_references or search_files if you need to check for callers.",
  }, "\n")

  local context = table.concat({
    string.format("File: %s (%s)", ctx.filename, ctx.filetype),
    string.format("Region: lines %d-%d", ctx.start_line, ctx.end_line),
    "",
    "Code before the region:",
    ctx.before,
    "",
    "--- Region to refactor ---",
    ctx.code,
    "--- End of region ---",
    "",
    "Code after the region:",
    ctx.after,
    "",
    "Refactoring instructions: " .. instructions,
  }, "\n")

  return {
    description = "Refactor code",
    messages = {
      { role = "user", content = { type = "text", text = system .. "\n\n" .. context } },
    },
  }
end)
