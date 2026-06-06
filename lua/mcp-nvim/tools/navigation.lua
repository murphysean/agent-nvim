local registry = require("mcp-nvim.mcp.registry")

registry.register("cursor_get", {
  annotations = {
    title = "Get Cursor Position",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Get the current cursor position (line, column) and the file it's in",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf = vim.api.nvim_get_current_buf()
  return vim.json.encode({
    file = vim.api.nvim_buf_get_name(buf),
    bufnr = buf,
    line = cursor[1],
    column = cursor[2] + 1,
  })
end)

registry.register("cursor_set", {
  annotations = {
    title = "Set Cursor Position",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = true,
    openWorldHint = false,
  },
  description = "Move the cursor to a specific position in the current buffer",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number (1-indexed)",
      },
      column = {
        type = "integer",
        description = "Column number (1-indexed). Default 1.",
      },
    },
    required = { "line" },
  },
}, function(args)
  require("mcp-nvim.util").ensure_code_window()
  local col = (args.column or 1) - 1
  vim.api.nvim_win_set_cursor(0, { args.line, col })
  return "Cursor moved to line " .. args.line .. ", column " .. (args.column or 1)
end)

registry.register("search", {
  annotations = {
    title = "Search Buffer",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Search for text in the current buffer and return matching lines with line numbers. "
    .. "Defaults to literal (exact) string matching. Set regex=true for vim regex patterns.",
  inputSchema = {
    type = "object",
    properties = {
      pattern = {
        type = "string",
        description = "Text to search for (literal match by default)",
      },
      regex = {
        type = "boolean",
        description = "Treat pattern as a vim regex. Default: false (literal match).",
      },
      ignore_case = {
        type = "boolean",
        description = "Case-insensitive matching. Default: true.",
      },
      buffer = {
        type = "integer",
        description = "Buffer number to search. Default: current buffer.",
      },
    },
    required = { "pattern" },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  local pattern = args.pattern
  local use_regex = args.regex == true
  local ignore_case = args.ignore_case ~= false

  if not use_regex then
    pattern = vim.fn.escape(pattern, "\\/.*$^~[]")
  end

  if ignore_case then
    pattern = "\\c" .. pattern
  end

  local matches = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if vim.fn.match(line, pattern) >= 0 then
      table.insert(matches, {
        line = i,
        text = line,
      })
    end
  end

  return vim.json.encode(matches)
end)

registry.register("mark_set", {
  annotations = {
    title = "Set Mark",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = true,
    openWorldHint = false,
  },
  description = "Set a named mark at a position. Uppercase marks (A-Z) are global across files, lowercase (a-z) are buffer-local.",
  inputSchema = {
    type = "object",
    properties = {
      mark = {
        type = "string",
        description = "Mark name (a-z for local, A-Z for global)",
      },
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column (0-indexed). Default: 0.",
      },
    },
    required = { "mark" },
  },
}, function(args)
  local line = args.line or vim.api.nvim_win_get_cursor(0)[1]
  local col = args.column or 0
  vim.api.nvim_buf_set_mark(0, args.mark, line, col, {})
  return string.format("Mark '%s' set at line %d, col %d", args.mark, line, col)
end)

registry.register("mark_get", {
  annotations = {
    title = "Get Marks",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Get all marks and their positions",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local marks = {}
  local all_marks = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  for i = 1, #all_marks do
    local mark = all_marks:sub(i, i)
    local pos = vim.api.nvim_buf_get_mark(0, mark)
    if pos[1] > 0 then
      table.insert(marks, {
        mark = mark,
        line = pos[1],
        column = pos[2],
      })
    end
  end

  return vim.json.encode(marks)
end)
