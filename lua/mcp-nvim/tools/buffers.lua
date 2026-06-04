local registry = require("mcp-nvim.mcp.registry")

registry.register("buffer_list", {
  description = "List all open buffers with their file paths, modified status, and buffer numbers",
  inputSchema = {
    type = "object",
    properties = {
      listed_only = {
        type = "boolean",
        description = "Only show listed (visible) buffers. Default true.",
      },
    },
  },
}, function(args)
  local listed_only = args.listed_only ~= false
  local buffers = vim.api.nvim_list_bufs()
  local result = {}

  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      local listed = vim.api.nvim_get_option_value("buflisted", { buf = buf })
      if not listed_only or listed then
        local name = vim.api.nvim_buf_get_name(buf)
        local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
        local loaded = vim.api.nvim_buf_is_loaded(buf)
        local line_count = loaded and vim.api.nvim_buf_line_count(buf) or 0

        table.insert(result, {
          bufnr = buf,
          name = name ~= "" and name or "[No Name]",
          modified = modified,
          loaded = loaded,
          line_count = line_count,
        })
      end
    end
  end

  return vim.json.encode(result)
end)

registry.register("buffer_get_content", {
  description = "Get the full content of a buffer by buffer number or file path",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number",
      },
      file = {
        type = "string",
        description = "File path (alternative to buffer number)",
      },
      start_line = {
        type = "integer",
        description = "Start line (0-indexed). Default 0.",
      },
      end_line = {
        type = "integer",
        description = "End line (0-indexed, exclusive). Default -1 (end of buffer).",
      },
    },
  },
}, function(args)
  local bufnr = args.buffer

  if not bufnr and args.file then
    bufnr = vim.fn.bufnr(args.file)
    if bufnr == -1 then
      vim.cmd("badd " .. vim.fn.fnameescape(args.file))
      bufnr = vim.fn.bufnr(args.file)
    end
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer")
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local start_line = args.start_line or 0
  local end_line = args.end_line or -1
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

  return table.concat(lines, "\n")
end)

registry.register("buffer_open", {
  description = "Open a file in a new buffer and optionally jump to a specific line",
  inputSchema = {
    type = "object",
    properties = {
      file = {
        type = "string",
        description = "File path to open",
      },
      line = {
        type = "integer",
        description = "Line number to jump to (1-indexed)",
      },
      column = {
        type = "integer",
        description = "Column number to jump to (1-indexed)",
      },
    },
    required = { "file" },
  },
}, function(args)
  vim.api.nvim_cmd({ cmd = "edit", args = { args.file } }, {})
  local bufnr = vim.api.nvim_get_current_buf()

  if args.line then
    local col = (args.column or 1) - 1
    vim.api.nvim_win_set_cursor(0, { args.line, col })
  end

  return vim.json.encode({
    bufnr = bufnr,
    file = vim.api.nvim_buf_get_name(bufnr),
    line_count = vim.api.nvim_buf_line_count(bufnr),
  })
end)

registry.register("buffer_close", {
  description = "Close a buffer by number or file path",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number to close",
      },
      file = {
        type = "string",
        description = "File path to close (alternative to buffer number)",
      },
      force = {
        type = "boolean",
        description = "Force close even if modified. Default false.",
      },
    },
  },
}, function(args)
  local bufnr = args.buffer
  if not bufnr and args.file then
    bufnr = vim.fn.bufnr(args.file)
  end

  if not bufnr or bufnr == -1 then
    error("Buffer not found")
  end

  local cmd = args.force and "bdelete!" or "bdelete"
  vim.cmd(cmd .. " " .. bufnr)
  return "Buffer " .. bufnr .. " closed"
end)
