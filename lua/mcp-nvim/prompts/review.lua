local prompts = require("mcp-nvim.mcp.prompts")

prompts.register("review", {
  description = "Review the current buffer or git diff for issues. Reports findings via the notify tool and optionally sets marks at problem locations. Does NOT modify code unless asked.",
  arguments = {
    {
      name = "scope",
      description = "What to review: 'buffer' (current file), 'diff' (unstaged git changes), or 'staged' (staged changes)",
      required = false,
    },
    {
      name = "focus",
      description = "What to focus on: 'bugs', 'security', 'performance', 'style', or 'all' (default)",
      required = false,
    },
  },
}, function(args)
  local scope = args.scope or "buffer"
  local focus = args.focus or "all"

  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  local code_context
  if scope == "diff" or scope == "staged" then
    local flag = scope == "staged" and "--staged" or ""
    local diff = vim.fn.system(string.format("git diff %s -- %s 2>/dev/null", flag, vim.fn.shellescape(filename)))
    if vim.v.shell_error ~= 0 or diff == "" then
      diff = vim.fn.system(string.format("git diff %s 2>/dev/null", flag))
    end
    code_context = diff ~= "" and diff or "(no changes found)"
  else
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local numbered = {}
    for i, line in ipairs(lines) do
      table.insert(numbered, string.format("%4d | %s", i, line))
    end
    code_context = table.concat(numbered, "\n")
  end

  local focus_instruction = ({
    bugs = "Focus on correctness issues: logic errors, off-by-one, nil/null handling, race conditions.",
    security = "Focus on security: injection, auth bypass, data exposure, unsafe operations.",
    performance = "Focus on performance: unnecessary allocations, O(n²) where O(n) would work, blocking operations.",
    style = "Focus on code style: naming, structure, readability, idiomatic patterns for this language.",
    all = "Check for bugs, security issues, performance problems, and style improvements.",
  })[focus] or "Check for bugs, security issues, performance problems, and style improvements."

  local system = table.concat({
    "You are a code review agent with access to a Neovim editor via MCP tools.",
    "Review the code below and report your findings.",
    "",
    "Rules:",
    "- Use the notify tool to present your review findings to the user.",
    "- Set marks (A, B, C...) at locations with issues using mark_set so the user can jump to them.",
    "- Do NOT modify code unless the user's instructions explicitly say to fix things.",
    "- " .. focus_instruction,
    "- Be specific: cite line numbers and explain the issue concisely.",
    "- If you need more context, use lsp_hover, lsp_references, or grep_workspace.",
    "- Prioritize: show the most important issues first.",
  }, "\n")

  local context = table.concat({
    string.format("File: %s (%s)", filename, ft),
    string.format("Scope: %s", scope),
    "",
    code_context,
  }, "\n")

  return {
    description = string.format("Review %s (%s)", scope, focus),
    messages = {
      { role = "user", content = { type = "text", text = system .. "\n\n" .. context } },
    },
  }
end)
