local prompts = require("agent-nvim.mcp.prompts")

--- "diagnostic-repair" prompt: Systematic diagnostic resolution workflow.
--- Unlike a simple "fix this error", this gathers ALL diagnostics, understands
--- dependency order, fixes cascading errors, and verifies each fix.
prompts.register("diagnostic-repair", {
  description = "Systematic diagnostic repair. Gathers all errors/warnings, resolves them in dependency order (fixing root causes first), and verifies each fix doesn't introduce new issues. Uses live LSP diagnostics.",
  arguments = {
    {
      name = "scope",
      description = "Repair scope: 'buffer' (current file), 'workspace' (all open files), or 'related' (current file + its imports)",
      required = false,
    },
    {
      name = "severity",
      description = "Minimum severity to fix: 'error' (only errors), 'warning' (errors + warnings), or 'all' (including hints)",
      required = false,
    },
  },
}, function(args)
  local scope = args.scope or "buffer"
  local severity = args.severity or "error"

  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  -- Gather diagnostics based on scope
  local diags = {}
  local min_severity = ({
    error = vim.diagnostic.severity.ERROR,
    warning = vim.diagnostic.severity.WARN,
    all = vim.diagnostic.severity.HINT,
  })[severity] or vim.diagnostic.severity.ERROR

  if scope == "buffer" then
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if d.severity <= min_severity then
        table.insert(diags, {
          file = vim.fn.fnamemodify(filename, ":~:."),
          line = d.lnum + 1,
          col = d.col + 1,
          severity = vim.diagnostic.severity[d.severity] or "?",
          message = d.message,
          source = d.source or "",
          code = d.code or "",
        })
      end
    end
  else
    -- workspace or related — gather from all loaded buffers
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= "" then
          for _, d in ipairs(vim.diagnostic.get(b)) do
            if d.severity <= min_severity then
              table.insert(diags, {
                file = vim.fn.fnamemodify(bname, ":~:."),
                line = d.lnum + 1,
                col = d.col + 1,
                severity = vim.diagnostic.severity[d.severity] or "?",
                message = d.message,
                source = d.source or "",
                code = d.code or "",
              })
            end
          end
        end
      end
    end
  end

  -- Sort: errors first, then by file, then by line
  table.sort(diags, function(a, b)
    if a.severity ~= b.severity then
      return a.severity < b.severity
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)

  -- Format diagnostic list
  local diag_parts = {}
  local current_file = ""
  for _, d in ipairs(diags) do
    if d.file ~= current_file then
      current_file = d.file
      table.insert(diag_parts, string.format("\n  %s:", d.file))
    end
    local code_str = d.code ~= "" and string.format(" [%s]", d.code) or ""
    table.insert(
      diag_parts,
      string.format("    L%d:%d [%s] %s%s (%s)", d.line, d.col, d.severity, d.message, code_str, d.source)
    )
  end

  -- Get imports/requires from current file (to understand dependency chain)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(30, vim.api.nvim_buf_line_count(buf)), false)
  local imports = {}
  for _, line in ipairs(lines) do
    if line:match("require") or line:match("import") or line:match("from.*import") then
      table.insert(imports, "  " .. vim.trim(line))
    end
  end

  local system = table.concat({
    "# Diagnostic Repair Agent",
    "",
    "You are a systematic diagnostic repair agent connected to Neovim via MCP tools.",
    "Your job is to fix ALL diagnostics listed below, in the correct order.",
    "",
    "## Strategy",
    "1. **Analyze** — Read the diagnostics. Identify root causes vs. cascading errors.",
    "2. **Order** — Fix root causes first. A missing import causes 10 'undefined' errors — fix the import.",
    "3. **Fix** — Apply each fix using `edit_file` or `buffer_edit`.",
    "4. **Verify** — After each fix, check `diagnostics` to see if cascading errors resolved.",
    "5. **Iterate** — If new diagnostics appear, address them.",
    "",
    "## Rules",
    "- Use `lsp_hover` and `lsp_goto_definition` to understand types and interfaces",
    "- Use `search_files` to find correct import paths or function signatures",
    "- Don't suppress errors (e.g. don't add `-- @diagnostic disable`) — fix the actual code",
    "- If a fix requires changes in another file, make those too",
    "- After all fixes, do a final `diagnostics` check and report the result",
    "- Use `notify` to report progress (e.g. '3/7 diagnostics resolved')",
    "",
    "## Context",
    string.format("Current file: `%s` (%s)", vim.fn.fnamemodify(filename, ":~:."), ft),
    string.format("Scope: %s | Minimum severity: %s", scope, severity),
    string.format("Total diagnostics to fix: %d", #diags),
    "",
    #imports > 0 and ("Imports in current file:\n" .. table.concat(imports, "\n")) or "",
    "",
    "## Diagnostics",
    #diags > 0 and table.concat(diag_parts, "\n") or "(no diagnostics found — workspace is clean!)",
  }, "\n")

  return {
    description = string.format("Repair %d diagnostic(s) (%s, %s)", #diags, scope, severity),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
