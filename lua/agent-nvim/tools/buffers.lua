local registry = require("agent-nvim.mcp.registry")

registry.register("buffer_list", {
  annotations = {
    title = "List Buffers",
    readOnlyHint = true,
    openWorldHint = false,
  },
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
  annotations = {
    title = "Get Buffer Content",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Get the content of a buffer with line numbers. Returns numbered lines (like 'cat -n') "
    .. "so you can orient yourself in the file. Use this before buffer_edit to see the current content.",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number",
      },
      file = {
        type = "string",
        description = "File path (alternative to buffer number). Opens the file if not already open.",
      },
      start_line = {
        type = "integer",
        description = "Start line (1-indexed, inclusive). Default: 1 (beginning of file).",
      },
      end_line = {
        type = "integer",
        description = "End line (1-indexed, inclusive). Default: end of file.",
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

  if not bufnr then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer")
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local start_idx = (args.start_line or 1) - 1
  local end_idx = args.end_line or total_lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)

  local numbered = {}
  for i, line in ipairs(lines) do
    local line_num = start_idx + i
    table.insert(numbered, string.format("%4d\t%s", line_num, line))
  end

  local header = string.format("File: %s (%d lines total)", vim.api.nvim_buf_get_name(bufnr), total_lines)
  return header .. "\n" .. table.concat(numbered, "\n")
end)

registry.register("buffer_open", {
  annotations = {
    title = "Open Buffer",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = true,
    openWorldHint = false,
  },
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
  require("agent-nvim.util").ensure_code_window()
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
  annotations = {
    title = "Close Buffer",
    readOnlyHint = false,
    destructiveHint = true,
    idempotentHint = true,
    openWorldHint = false,
  },
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

registry.register("buffer_edit", {
  annotations = {
    title = "Edit Buffer",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = false,
    openWorldHint = false,
  },
  description = "Edit a buffer by finding an exact string match and replacing it. "
    .. "Provide the exact text you want to change (before) and what to replace it with (after). "
    .. "The 'before' text must appear exactly once in the buffer — if it matches zero or multiple times, "
    .. "the tool returns an error asking you to provide more context to disambiguate. "
    .. "Always read the buffer first to ensure you have the current content.",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
      file = {
        type = "string",
        description = "File path (alternative to buffer number). Opens the file if not already open.",
      },
      before = {
        type = "string",
        description = "The exact text to find in the buffer. Must match exactly once.",
      },
      after = {
        type = "string",
        description = "The replacement text. Use empty string to delete the matched text.",
      },
    },
    required = { "before", "after" },
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

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer")
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  local before = args.before
  local after = args.after

  local start_pos, end_pos = content:find(before, 1, true)
  if not start_pos then
    local preview_lines = {}
    for i, line in ipairs(lines) do
      if i <= 20 then
        table.insert(preview_lines, string.format("%4d | %s", i, line))
      end
    end
    local preview = table.concat(preview_lines, "\n")
    error(
      "No match found for the provided 'before' text. "
        .. "The text may have changed since you last read the buffer, or there may be a whitespace mismatch.\n\n"
        .. "Current buffer content (first 20 lines):\n"
        .. preview
    )
  end

  local second_start = content:find(before, end_pos + 1, true)
  if second_start then
    local function line_of(pos)
      local count = 1
      for i = 1, pos - 1 do
        if content:sub(i, i) == "\n" then
          count = count + 1
        end
      end
      return count
    end
    error(
      string.format(
        "Multiple matches found (at line %d and line %d). "
          .. "Include more surrounding context in 'before' to uniquely identify the text you want to change.",
        line_of(start_pos),
        line_of(second_start)
      )
    )
  end

  local new_content = content:sub(1, start_pos - 1) .. after .. content:sub(end_pos + 1)
  local new_lines = vim.split(new_content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

  local old_line_count = #lines
  local new_line_count = #new_lines
  local line_diff = new_line_count - old_line_count

  local function line_of(pos)
    local count = 1
    for i = 1, pos - 1 do
      if content:sub(i, i) == "\n" then
        count = count + 1
      end
    end
    return count
  end

  local start_line = line_of(start_pos)
  local result_msg = string.format("Edit applied at line %d", start_line)
  if line_diff ~= 0 then
    result_msg = result_msg .. string.format(" (%+d lines)", line_diff)
  end
  result_msg = result_msg .. string.format(". Buffer now has %d lines.", new_line_count)

  return result_msg
end)
