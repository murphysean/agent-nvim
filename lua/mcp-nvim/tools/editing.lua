local registry = require("mcp-nvim.mcp.registry")

registry.register("buffer_set_lines", {
  description = "Replace a range of lines in a buffer. Use this to insert, replace, or delete text.",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
      start_line = {
        type = "integer",
        description = "Start line (0-indexed, inclusive)",
      },
      end_line = {
        type = "integer",
        description = "End line (0-indexed, exclusive). Use same as start_line to insert before that line.",
      },
      lines = {
        type = "array",
        items = { type = "string" },
        description = "Lines to insert/replace with",
      },
    },
    required = { "start_line", "end_line", "lines" },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, args.start_line, args.end_line, false, args.lines)
  return string.format("Set lines %d-%d (%d lines written)", args.start_line, args.end_line, #args.lines)
end)

registry.register("buffer_set_text", {
  description = "Replace text within a specific range (can be partial lines). More precise than set_lines.",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
      start_line = {
        type = "integer",
        description = "Start line (0-indexed)",
      },
      start_col = {
        type = "integer",
        description = "Start column (0-indexed byte offset)",
      },
      end_line = {
        type = "integer",
        description = "End line (0-indexed)",
      },
      end_col = {
        type = "integer",
        description = "End column (0-indexed byte offset)",
      },
      text = {
        type = "array",
        items = { type = "string" },
        description = "Replacement text lines (empty array to delete)",
      },
    },
    required = { "start_line", "start_col", "end_line", "end_col", "text" },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_text(bufnr, args.start_line, args.start_col, args.end_line, args.end_col, args.text)
  return "Text replaced"
end)

registry.register("buffer_insert", {
  description = "Insert text at the current cursor position",
  inputSchema = {
    type = "object",
    properties = {
      text = {
        type = "string",
        description = "Text to insert. Use \\n for newlines.",
      },
    },
    required = { "text" },
  },
}, function(args)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local col = cursor[2]

  local lines = vim.split(args.text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, line, col, line, col, lines)
  return string.format("Inserted %d lines at line %d, col %d", #lines, line + 1, col + 1)
end)

registry.register("buffer_replace_file", {
  description = "Replace the entire content of a buffer. Useful for major rewrites.",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
      content = {
        type = "string",
        description = "Full file content to replace with",
      },
    },
    required = { "content" },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  local lines = vim.split(args.content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return string.format("Buffer content replaced (%d lines)", #lines)
end)

registry.register("buffer_save", {
  description = "Save a buffer to disk",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
      file = {
        type = "string",
        description = "Optional: save to a different file path",
      },
    },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  if args.file then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("saveas " .. vim.fn.fnameescape(args.file))
    end)
  else
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("write")
    end)
  end
  return "Buffer saved"
end)

registry.register("undo", {
  description = "Undo the last change in the current buffer",
  inputSchema = {
    type = "object",
    properties = {
      count = {
        type = "integer",
        description = "Number of undos. Default 1.",
      },
    },
  },
}, function(args)
  local count = args.count or 1
  for _ = 1, count do
    vim.cmd("undo")
  end
  return string.format("Undid %d change(s)", count)
end)

registry.register("redo", {
  description = "Redo the last undone change in the current buffer",
  inputSchema = {
    type = "object",
    properties = {
      count = {
        type = "integer",
        description = "Number of redos. Default 1.",
      },
    },
  },
}, function(args)
  local count = args.count or 1
  for _ = 1, count do
    vim.cmd("redo")
  end
  return string.format("Redid %d change(s)", count)
end)
