local registry = require("agent-nvim.mcp.registry")

registry.register("quickfix_set", {
  annotations = {
    title = "Set Quickfix List",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = true,
    openWorldHint = false,
  },
  description = "Set the quickfix list with a set of locations. Useful for presenting search results, errors, or any list of file positions the user should visit.",
  inputSchema = {
    type = "object",
    properties = {
      items = {
        type = "array",
        description = "List of quickfix entries",
        items = {
          type = "object",
          properties = {
            file = { type = "string", description = "File path" },
            line = { type = "integer", description = "Line number (1-indexed)" },
            column = { type = "integer", description = "Column (1-indexed)" },
            text = { type = "string", description = "Description text" },
            type = { type = "string", description = "Type: 'E' (error), 'W' (warning), 'I' (info)" },
          },
          required = { "file", "line", "text" },
        },
      },
      title = {
        type = "string",
        description = "Title for the quickfix list",
      },
      open = {
        type = "boolean",
        description = "Open the quickfix window after setting. Default true.",
      },
    },
    required = { "items" },
  },
}, function(args)
  local qf_items = {}
  for _, item in ipairs(args.items) do
    table.insert(qf_items, {
      filename = item.file,
      lnum = item.line,
      col = item.column or 1,
      text = item.text,
      type = item.type or "",
    })
  end

  vim.fn.setqflist({}, "r", {
    title = args.title or "MCP Results",
    items = qf_items,
  })

  if args.open ~= false then
    vim.cmd("copen")
  end

  return string.format("Quickfix list set with %d items", #qf_items)
end)

registry.register("quickfix_get", {
  annotations = {
    title = "Get Quickfix List",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Get the current quickfix list contents",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local qf = vim.fn.getqflist({ all = true })
  local items = {}

  for _, item in ipairs(qf.items or {}) do
    local file = ""
    if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      file = vim.api.nvim_buf_get_name(item.bufnr)
    end
    table.insert(items, {
      file = file,
      line = item.lnum,
      column = item.col,
      text = item.text,
      type = item.type,
    })
  end

  return vim.json.encode({
    title = qf.title or "",
    items = items,
    size = #items,
  })
end)

registry.register("loclist_set", {
  annotations = {
    title = "Set Location List",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = true,
    openWorldHint = false,
  },
  description = "Set the location list for the current window",
  inputSchema = {
    type = "object",
    properties = {
      items = {
        type = "array",
        description = "List of location entries",
        items = {
          type = "object",
          properties = {
            file = { type = "string", description = "File path" },
            line = { type = "integer", description = "Line number (1-indexed)" },
            column = { type = "integer", description = "Column (1-indexed)" },
            text = { type = "string", description = "Description text" },
          },
          required = { "file", "line", "text" },
        },
      },
      title = {
        type = "string",
        description = "Title for the location list",
      },
      open = {
        type = "boolean",
        description = "Open the location list window after setting. Default true.",
      },
    },
    required = { "items" },
  },
}, function(args)
  local loc_items = {}
  for _, item in ipairs(args.items) do
    table.insert(loc_items, {
      filename = item.file,
      lnum = item.line,
      col = item.column or 1,
      text = item.text,
    })
  end

  vim.fn.setloclist(0, {}, "r", {
    title = args.title or "MCP Locations",
    items = loc_items,
  })

  if args.open ~= false then
    vim.cmd("lopen")
  end

  return string.format("Location list set with %d items", #loc_items)
end)
