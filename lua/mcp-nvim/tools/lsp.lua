local registry = require("mcp-nvim.mcp.registry")

local function get_offset_encoding()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if clients[1] then
    return clients[1].offset_encoding or "utf-16"
  end
  return "utf-16"
end

registry.register("lsp_get_clients", {
  description = "List active LSP clients attached to the current buffer",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  local result = {}

  for _, client in ipairs(clients) do
    table.insert(result, {
      id = client.id,
      name = client.name,
      root_dir = client.config.root_dir,
      filetypes = client.config.filetypes or {}, ---@diagnostic disable-line: undefined-field
    })
  end

  return vim.json.encode(result)
end)

registry.register("lsp_goto_definition", {
  description = "Go to the definition of the symbol under the cursor or at a given position",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column (1-indexed). Default: current cursor column.",
      },
    },
  },
}, function(args)
  if args.line then
    local col = (args.column or 1) - 1
    vim.api.nvim_win_set_cursor(0, { args.line, col })
  end

  local params = vim.lsp.util.make_position_params(0, get_offset_encoding())
  local results = vim.lsp.buf_request_sync(0, "textDocument/definition", params, 5000)

  if not results then
    return "No definition found (no LSP response)"
  end

  local locations = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      local items = server_result.result
      if items.uri then
        items = { items }
      end
      for _, item in ipairs(items) do
        local uri = item.uri or item.targetUri
        local range = item.range or item.targetSelectionRange
        if uri and range then
          table.insert(locations, {
            file = vim.uri_to_fname(uri),
            line = range.start.line + 1,
            column = range.start.character + 1,
          })
        end
      end
    end
  end

  if #locations > 0 then
    vim.api.nvim_cmd({ cmd = "edit", args = { locations[1].file } }, {})
    vim.api.nvim_win_set_cursor(0, { locations[1].line, locations[1].column - 1 })
  end

  return vim.json.encode(locations)
end)

registry.register("lsp_references", {
  description = "Find all references to the symbol under the cursor",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column (1-indexed). Default: current cursor column.",
      },
    },
  },
}, function(args)
  if args.line then
    local col = (args.column or 1) - 1
    vim.api.nvim_win_set_cursor(0, { args.line, col })
  end

  local params = vim.lsp.util.make_position_params(0, get_offset_encoding()) --[[@as table]]
  params.context = { includeDeclaration = true }
  local results = vim.lsp.buf_request_sync(0, "textDocument/references", params, 10000)

  if not results then
    return vim.json.encode({})
  end

  local locations = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      for _, item in ipairs(server_result.result) do
        local uri = item.uri
        local range = item.range
        if uri and range then
          local file = vim.uri_to_fname(uri)
          local lnum = range.start.line + 1
          local col_num = range.start.character + 1
          local line_text = ""
          local bufnr = vim.uri_to_bufnr(uri)
          if vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
            line_text = lines[1] or ""
          end
          table.insert(locations, {
            file = file,
            line = lnum,
            column = col_num,
            text = line_text,
          })
        end
      end
    end
  end

  return vim.json.encode(locations)
end)

registry.register("lsp_hover", {
  description = "Get hover information (type info, docs) for the symbol at a position",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column (1-indexed). Default: current cursor column.",
      },
    },
  },
}, function(args)
  if args.line then
    local col = (args.column or 1) - 1
    vim.api.nvim_win_set_cursor(0, { args.line, col })
  end

  local params = vim.lsp.util.make_position_params(0, get_offset_encoding())
  local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 5000)

  if not results then
    return "No hover info available"
  end

  for _, server_result in pairs(results) do
    if server_result.result and server_result.result.contents then
      local contents = server_result.result.contents
      if type(contents) == "string" then
        return contents
      elseif contents.value then
        return contents.value
      elseif type(contents) == "table" then
        local parts = {}
        for _, part in ipairs(contents) do
          if type(part) == "string" then
            table.insert(parts, part)
          elseif part.value then
            table.insert(parts, part.value)
          end
        end
        return table.concat(parts, "\n")
      end
    end
  end

  return "No hover info available"
end)

registry.register("lsp_symbols", {
  description = "Get document symbols (functions, classes, variables, etc.) from the current buffer",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Default: current buffer.",
      },
    },
  },
}, function(args)
  local bufnr = args.buffer or vim.api.nvim_get_current_buf()
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 5000)

  if not results then
    return vim.json.encode({})
  end

  local symbol_kinds = {
    [1] = "File",
    [2] = "Module",
    [3] = "Namespace",
    [4] = "Package",
    [5] = "Class",
    [6] = "Method",
    [7] = "Property",
    [8] = "Field",
    [9] = "Constructor",
    [10] = "Enum",
    [11] = "Interface",
    [12] = "Function",
    [13] = "Variable",
    [14] = "Constant",
    [15] = "String",
    [16] = "Number",
    [17] = "Boolean",
    [18] = "Array",
    [19] = "Object",
    [20] = "Key",
    [21] = "Null",
    [22] = "EnumMember",
    [23] = "Struct",
    [24] = "Event",
    [25] = "Operator",
    [26] = "TypeParameter",
  }

  local function flatten_symbols(symbols, parent_name)
    local flat = {}
    for _, sym in ipairs(symbols) do
      local name = sym.name
      if parent_name then
        name = parent_name .. "." .. name
      end
      local range = sym.range or sym.location and sym.location.range
      table.insert(flat, {
        name = name,
        kind = symbol_kinds[sym.kind] or "Unknown",
        line = range and (range.start.line + 1) or 0,
        end_line = range and (range["end"].line + 1) or 0,
      })
      if sym.children then
        vim.list_extend(flat, flatten_symbols(sym.children, sym.name))
      end
    end
    return flat
  end

  local all_symbols = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      vim.list_extend(all_symbols, flatten_symbols(server_result.result, nil))
    end
  end

  return vim.json.encode(all_symbols)
end)

registry.register("lsp_workspace_symbols", {
  description = "Search for symbols across the entire workspace/project",
  inputSchema = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "Symbol name query (supports fuzzy matching depending on the LSP server)",
      },
    },
    required = { "query" },
  },
}, function(args)
  local params = { query = args.query }
  local results = vim.lsp.buf_request_sync(0, "workspace/symbol", params, 10000)

  if not results then
    return vim.json.encode({})
  end

  local symbol_kinds = {
    [1] = "File",
    [2] = "Module",
    [3] = "Namespace",
    [4] = "Package",
    [5] = "Class",
    [6] = "Method",
    [7] = "Property",
    [8] = "Field",
    [9] = "Constructor",
    [10] = "Enum",
    [11] = "Interface",
    [12] = "Function",
    [13] = "Variable",
    [14] = "Constant",
    [15] = "String",
    [16] = "Number",
    [17] = "Boolean",
    [18] = "Array",
    [19] = "Object",
    [20] = "Key",
    [21] = "Null",
    [22] = "EnumMember",
    [23] = "Struct",
    [24] = "Event",
    [25] = "Operator",
    [26] = "TypeParameter",
  }

  local symbols = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      for _, sym in ipairs(server_result.result) do
        local location = sym.location
        local uri = location and location.uri
        local range = location and location.range

        table.insert(symbols, {
          name = sym.name,
          kind = symbol_kinds[sym.kind] or "Unknown",
          file = uri and vim.uri_to_fname(uri) or "",
          line = range and (range.start.line + 1) or 0,
          container = sym.containerName or "",
        })
      end
    end
  end

  return vim.json.encode(symbols)
end)

registry.register("lsp_rename", {
  description = "Rename a symbol across the project using LSP",
  inputSchema = {
    type = "object",
    properties = {
      new_name = {
        type = "string",
        description = "New name for the symbol",
      },
      line = {
        type = "integer",
        description = "Line of the symbol (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column of the symbol (1-indexed). Default: current cursor column.",
      },
    },
    required = { "new_name" },
  },
}, function(args)
  if args.line then
    local col = (args.column or 1) - 1
    vim.api.nvim_win_set_cursor(0, { args.line, col })
  end

  local params = vim.lsp.util.make_position_params(0, get_offset_encoding()) --[[@as table]]
  params.newName = args.new_name

  local results = vim.lsp.buf_request_sync(0, "textDocument/rename", params, 10000)

  if not results then
    return "Rename failed: no LSP response"
  end

  for _, server_result in pairs(results) do
    if server_result.result then
      vim.lsp.util.apply_workspace_edit(server_result.result, "utf-8")
      local changes = server_result.result.changes or server_result.result.documentChanges
      local file_count = 0
      if changes then
        for _ in pairs(changes) do
          file_count = file_count + 1
        end
      end
      return string.format("Renamed to '%s' across %d file(s)", args.new_name, file_count)
    end
  end

  return "Rename failed"
end)

registry.register("lsp_code_actions", {
  description = "Get available code actions at the current position or for a selection",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current line.",
      },
      apply_first = {
        type = "boolean",
        description = "Automatically apply the first available action. Default false.",
      },
    },
  },
}, function(args)
  if args.line then
    vim.api.nvim_win_set_cursor(0, { args.line, 0 })
  end

  local params = vim.lsp.util.make_range_params(0, get_offset_encoding()) --[[@as table]]
  params.context = { diagnostics = vim.diagnostic.get(0, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 }) }

  local results = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, 5000)

  if not results then
    return vim.json.encode({})
  end

  local actions = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      for _, action in ipairs(server_result.result) do
        table.insert(actions, {
          title = action.title,
          kind = action.kind,
        })
      end
    end
  end

  if args.apply_first and #actions > 0 then
    vim.lsp.buf.code_action({
      apply = true,
      filter = function(a)
        return a.title == actions[1].title
      end,
    })
    return "Applied action: " .. actions[1].title
  end

  return vim.json.encode(actions)
end)
