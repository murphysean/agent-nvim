local prompts = require("agent-nvim.mcp.prompts")

--- "navigate" prompt: Guided code exploration agent that uses LSP and search
--- to trace code paths, set marks, and populate quickfix for the user.
prompts.register("navigate", {
  description = "Guided code navigation. Find where something happens in the codebase using LSP references, definition jumps, and search. Sets marks at key locations and populates quickfix for jumping.",
  arguments = {
    {
      name = "query",
      description = "What to find (e.g. 'where is the session created', 'what calls this function', 'how does auth flow work')",
      required = true,
    },
    {
      name = "output",
      description = "How to present results: 'quickfix' (populate quickfix list), 'marks' (set A-Z marks at locations), or 'both'",
      required = false,
    },
  },
}, function(args)
  local query = args.query or ""
  local output = args.output or "both"

  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cwd = vim.fn.getcwd()

  -- Current symbol at cursor (if any)
  local current_line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local word_at_cursor = vim.fn.expand("<cword>")

  -- Get document symbols for orientation
  local symbols_text = ""
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients > 0 then
    local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
    local result = vim.lsp.buf_request_sync(buf, "textDocument/documentSymbol", params, 2000)
    if result then
      local parts = {}
      for _, r in pairs(result) do
        if r.result then
          for _, sym in ipairs(r.result) do
            local kind = vim.lsp.protocol.SymbolKind[sym.kind] or "?"
            table.insert(parts, string.format("  %s %s (L%d)", kind, sym.name, sym.range.start.line + 1))
          end
        end
      end
      symbols_text = table.concat(parts, "\n")
    end
  end

  local output_instruction = ({
    quickfix = table.concat({
      "Populate the quickfix list with all relevant locations using `quickfix_set`.",
      "Format each entry with: file, line, and a description of what happens there.",
      "The user can then use :cnext/:cprev to jump through results.",
    }, "\n"),
    marks = table.concat({
      "Set global marks (A-Z) at the most important locations using `mark_set`.",
      "Use them in order of the flow (A = entry point, B = next step, etc.).",
      "Use `notify` to explain what each mark represents.",
    }, "\n"),
    both = table.concat({
      "Do both:",
      "1. Set global marks (A-Z) at key locations in the flow (A = start, B = next, etc.)",
      "2. Populate quickfix with ALL relevant locations (including secondary references)",
      "3. Use `notify` to present a summary of the flow with mark labels",
    }, "\n"),
  })[output] or "Use both marks and quickfix."

  local system = table.concat({
    "# Code Navigation Agent",
    "",
    "You are a code navigation agent connected to Neovim via MCP tools.",
    "Your job is to trace through the codebase and find the answer to the user's query.",
    "",
    "## Approach",
    "1. Start from the current file/symbol as context",
    "2. Use `lsp_goto_definition` to follow symbol definitions",
    "3. Use `lsp_references` to find all callers/usages",
    "4. Use `search_files` for pattern-based discovery (config keys, strings, etc.)",
    "5. Use `lsp_workspace_symbols` to find types/classes by name",
    "6. Build a mental model of the flow, then present the results",
    "",
    "## Output",
    output_instruction,
    "",
    "## Rules",
    "- Trace the actual code — don't guess from names alone",
    "- Follow the chain: caller → function → dependencies → effects",
    "- If a path branches, note both branches",
    "- Present results in flow order (what happens first → last)",
    "- Keep the quickfix descriptions concise but informative",
    "",
    "## Starting Context",
    string.format("File: `%s` (%s)", vim.fn.fnamemodify(filename, ":~:."), ft),
    string.format("Cursor: line %d — `%s`", cursor[1], vim.trim(current_line)),
    string.format("Word at cursor: `%s`", word_at_cursor),
    string.format("Workspace: `%s`", cwd),
    "",
    symbols_text ~= "" and ("Document symbols:\n" .. symbols_text) or "",
    "",
    "## Query",
    query,
  }, "\n")

  return {
    description = string.format("Navigate: %s", query:sub(1, 60)),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
