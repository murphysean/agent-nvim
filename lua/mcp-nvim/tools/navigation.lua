local registry = require("mcp-nvim.mcp.registry")

registry.register("cursor_get", {
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
  local col = (args.column or 1) - 1
  vim.api.nvim_win_set_cursor(0, { args.line, col })
  return "Cursor moved to line " .. args.line .. ", column " .. (args.column or 1)
end)

registry.register("jumplist_set", {
  description = "Set the jump list to a series of locations. The user can then navigate these with Ctrl-O / Ctrl-I. This is ideal for guiding a user through a code path.",
  inputSchema = {
    type = "object",
    properties = {
      locations = {
        type = "array",
        description = "Ordered list of locations to add to the jump list",
        items = {
          type = "object",
          properties = {
            file = { type = "string", description = "File path" },
            line = { type = "integer", description = "Line number (1-indexed)" },
            column = { type = "integer", description = "Column (1-indexed). Default 1." },
          },
          required = { "file", "line" },
        },
      },
    },
    required = { "locations" },
  },
}, function(args)
  vim.cmd("clearjumps")

  for _, loc in ipairs(args.locations) do
    vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
    local line = math.min(loc.line, vim.api.nvim_buf_line_count(0))
    vim.cmd("normal! " .. line .. "G")
    if loc.column and loc.column > 1 then
      vim.cmd("normal! " .. (loc.column - 1) .. "l")
    end
  end

  if #args.locations > 0 then
    local first = args.locations[1]
    vim.cmd("edit " .. vim.fn.fnameescape(first.file))
    local line = math.min(first.line, vim.api.nvim_buf_line_count(0))
    vim.cmd("normal! " .. line .. "G")
  end

  return string.format("Jump list set with %d locations. Use Ctrl-O to step back through them.", #args.locations)
end)

registry.register("jumplist_get", {
  description = "Get the current jump list contents",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local jumplist = vim.fn.getjumplist()
  local jumps = jumplist[1]
  local current_pos = jumplist[2]

  local result = {}
  for _, jump in ipairs(jumps) do
    local bufnr = jump.bufnr
    local name = ""
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      name = vim.api.nvim_buf_get_name(bufnr)
    end
    table.insert(result, {
      file = name,
      line = jump.lnum,
      column = jump.col + 1,
    })
  end

  return vim.json.encode({
    jumps = result,
    current_index = current_pos,
  })
end)

registry.register("search", {
  description = "Search for a pattern in the current buffer and return matching lines",
  inputSchema = {
    type = "object",
    properties = {
      pattern = {
        type = "string",
        description = "Vim regex pattern to search for",
      },
      literal = {
        type = "boolean",
        description = "Treat pattern as a literal string. Default false.",
      },
    },
    required = { "pattern" },
  },
}, function(args)
  local pattern = args.pattern
  if args.literal then
    pattern = vim.fn.escape(pattern, "\\/.*$^~[]")
  end

  local matches = {}
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
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

registry.register("grep_workspace", {
  description = "Search for a pattern across all files in the workspace using vimgrep or the configured grepprg",
  inputSchema = {
    type = "object",
    properties = {
      pattern = {
        type = "string",
        description = "Search pattern",
      },
      glob = {
        type = "string",
        description = "File glob pattern to restrict search. Default '**/*'.",
      },
    },
    required = { "pattern" },
  },
}, function(args)
  local glob = args.glob or "**/*"
  local escaped = vim.fn.escape(args.pattern, "/\\")
  vim.cmd("silent! vimgrep /" .. escaped .. "/j " .. glob)

  local qflist = vim.fn.getqflist()
  local results = {}

  for _, item in ipairs(qflist) do
    local file = ""
    if item.bufnr and item.bufnr > 0 then
      file = vim.api.nvim_buf_get_name(item.bufnr)
    end
    table.insert(results, {
      file = file,
      line = item.lnum,
      column = item.col,
      text = item.text,
    })
  end

  return vim.json.encode(results)
end)
