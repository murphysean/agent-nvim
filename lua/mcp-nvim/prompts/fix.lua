local prompts = require("mcp-nvim.mcp.prompts")

local function get_diagnostics_context()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  local diagnostics = vim.diagnostic.get(buf)
  local line_diags = {}
  local all_diags = {}

  for _, d in ipairs(diagnostics) do
    local entry = {
      line = d.lnum + 1,
      col = d.col + 1,
      severity = vim.diagnostic.severity[d.severity] or "Unknown",
      message = d.message,
      source = d.source or "",
    }
    table.insert(all_diags, entry)
    if d.lnum == row then
      table.insert(line_diags, entry)
    end
  end

  local context_start = math.max(0, row - 10)
  local context_end = math.min(vim.api.nvim_buf_line_count(buf), row + 11)
  local context_lines = vim.api.nvim_buf_get_lines(buf, context_start, context_end, false)

  local numbered = {}
  for i, line in ipairs(context_lines) do
    table.insert(numbered, string.format("%4d | %s", context_start + i, line))
  end

  return {
    filename = filename,
    filetype = ft,
    row = row + 1,
    context = table.concat(numbered, "\n"),
    line_diagnostics = line_diags,
    all_diagnostics = all_diags,
  }
end

prompts.register("fix", {
  description = "Fix diagnostics (errors/warnings) at or near the cursor. Provides diagnostic messages and surrounding code context. The agent should use neovim MCP tools to apply the fix directly.",
  arguments = {
    {
      name = "scope",
      description = "Fix scope: 'line' (default) for current line, 'buffer' for all diagnostics in file",
      required = false,
    },
  },
}, function(args)
  local ctx = get_diagnostics_context()
  local scope = args.scope or "line"

  local diags = scope == "buffer" and ctx.all_diagnostics or ctx.line_diagnostics
  if #diags == 0 then
    diags = ctx.all_diagnostics
    if #diags == 0 then
      return {
        description = "No diagnostics to fix",
        messages = {
          { role = "user", content = { type = "text", text = "No diagnostics found in this buffer." } },
        },
      }
    end
  end

  local diag_text = {}
  for _, d in ipairs(diags) do
    table.insert(
      diag_text,
      string.format("  [%s] line %d col %d: %s (%s)", d.severity, d.line, d.col, d.message, d.source)
    )
  end

  local system = table.concat({
    "You are a code fix agent with direct access to a Neovim editor via MCP tools.",
    "Your ONLY job is to fix the diagnostic issues listed below.",
    "Do NOT explain. Do NOT ask questions. Apply the fix directly.",
    "",
    "Rules:",
    "- Use ONLY neovim MCP tools (buffer_set_lines, buffer_set_text, buffer_replace_file) to make changes.",
    "- Fix the root cause, not just the symptom.",
    "- Preserve existing code style and formatting.",
    "- Make minimal changes — only what's needed to resolve the diagnostic.",
    "- After fixing, save the buffer with buffer_save.",
  }, "\n")

  local context = table.concat({
    string.format("File: %s (%s)", ctx.filename, ctx.filetype),
    string.format("Cursor: line %d", ctx.row),
    "",
    "Diagnostics to fix:",
    table.concat(diag_text, "\n"),
    "",
    "Surrounding code:",
    ctx.context,
  }, "\n")

  return {
    description = string.format("Fix %d diagnostic(s)", #diags),
    messages = {
      { role = "user", content = { type = "text", text = system .. "\n\n" .. context } },
    },
  }
end)
