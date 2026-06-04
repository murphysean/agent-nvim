local registry = require("mcp-nvim.mcp.registry")

registry.register("diagnostics_get", {
  description = "Get diagnostics (errors, warnings, etc.) for a buffer or all buffers",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number. Omit to get diagnostics for all buffers.",
      },
      severity = {
        type = "string",
        enum = { "error", "warn", "info", "hint" },
        description = "Filter by severity level",
      },
    },
  },
}, function(args)
  local opts = {}
  if args.severity then
    local severity_map = {
      error = vim.diagnostic.severity.ERROR,
      warn = vim.diagnostic.severity.WARN,
      info = vim.diagnostic.severity.INFO,
      hint = vim.diagnostic.severity.HINT,
    }
    opts.severity = severity_map[args.severity]
  end

  local bufnr = args.buffer
  local diagnostics = vim.diagnostic.get(bufnr, opts)

  local severity_names = { "ERROR", "WARN", "INFO", "HINT" }
  local result = {}
  for _, d in ipairs(diagnostics) do
    local file = ""
    if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
      file = vim.api.nvim_buf_get_name(d.bufnr)
    end
    table.insert(result, {
      file = file,
      line = d.lnum + 1,
      column = d.col + 1,
      end_line = d.end_lnum and (d.end_lnum + 1) or nil,
      end_column = d.end_col and (d.end_col + 1) or nil,
      message = d.message,
      severity = severity_names[d.severity] or "UNKNOWN",
      source = d.source,
      code = d.code,
    })
  end

  return vim.json.encode(result)
end)

registry.register("diagnostics_next", {
  description = "Jump to the next diagnostic in the current buffer",
  inputSchema = {
    type = "object",
    properties = {
      severity = {
        type = "string",
        enum = { "error", "warn", "info", "hint" },
        description = "Only jump to diagnostics of this severity",
      },
    },
  },
}, function(args)
  local severity
  if args.severity then
    local severity_map = {
      error = vim.diagnostic.severity.ERROR,
      warn = vim.diagnostic.severity.WARN,
      info = vim.diagnostic.severity.INFO,
      hint = vim.diagnostic.severity.HINT,
    }
    severity = severity_map[args.severity]
  end

  vim.diagnostic.jump({ count = 1, float = false, severity = severity })
  local cursor = vim.api.nvim_win_get_cursor(0)
  local diags = vim.diagnostic.get(0, { lnum = cursor[1] - 1 })
  local msg = #diags > 0 and diags[1].message or "No diagnostic at cursor"

  return vim.json.encode({
    line = cursor[1],
    column = cursor[2] + 1,
    message = msg,
  })
end)
