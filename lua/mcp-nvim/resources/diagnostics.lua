local resources = require("mcp-nvim.mcp.resources")

local severity_names = { "ERROR", "WARN", "INFO", "HINT" }

resources.register("nvim://diagnostics", {
  name = "All Diagnostics",
  description = "Diagnostics (errors, warnings, info, hints) across all open buffers",
  mimeType = "application/json",
}, function()
  local diagnostics = vim.diagnostic.get()
  local result = {}

  for _, d in ipairs(diagnostics) do
    local file = ""
    if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
      file = vim.api.nvim_buf_get_name(d.bufnr)
    end
    table.insert(result, {
      file = file,
      bufnr = d.bufnr,
      line = d.lnum + 1,
      column = d.col + 1,
      message = d.message,
      severity = severity_names[d.severity] or "UNKNOWN",
      source = d.source,
      code = d.code,
    })
  end

  return {
    uri = "nvim://diagnostics",
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)

resources.register("nvim://symbols", {
  name = "Document Symbols",
  description = "LSP document symbols (functions, classes, variables) for the current buffer",
  mimeType = "application/json",
}, function()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 5000)

  if not results then
    return { uri = "nvim://symbols", mimeType = "application/json", text = "[]" }
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

  local function flatten(symbols, parent)
    local flat = {}
    for _, sym in ipairs(symbols) do
      local name = sym.name
      if parent then
        name = parent .. "." .. name
      end
      local range = sym.range or (sym.location and sym.location.range)
      table.insert(flat, {
        name = name,
        kind = symbol_kinds[sym.kind] or "Unknown",
        line = range and (range.start.line + 1) or 0,
        end_line = range and (range["end"].line + 1) or 0,
      })
      if sym.children then
        vim.list_extend(flat, flatten(sym.children, sym.name))
      end
    end
    return flat
  end

  local all = {}
  for _, server_result in pairs(results) do
    if server_result.result then
      vim.list_extend(all, flatten(server_result.result, nil))
    end
  end

  return {
    uri = "nvim://symbols",
    mimeType = "application/json",
    text = vim.json.encode(all),
  }
end)

-- Template: diagnostics for a specific buffer
resources.register_template("nvim://diagnostics/{bufnr}", {
  name = "Buffer Diagnostics",
  description = "Diagnostics for a specific buffer by number",
  mimeType = "application/json",
}, function(params)
  local bufnr = tonumber(params.bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local diagnostics = vim.diagnostic.get(bufnr)
  local result = {}
  local file = vim.api.nvim_buf_get_name(bufnr)

  for _, d in ipairs(diagnostics) do
    table.insert(result, {
      file = file,
      line = d.lnum + 1,
      column = d.col + 1,
      message = d.message,
      severity = severity_names[d.severity] or "UNKNOWN",
      source = d.source,
      code = d.code,
    })
  end

  return {
    uri = "nvim://diagnostics/" .. params.bufnr,
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)
