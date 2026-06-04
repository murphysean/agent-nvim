local prompts = require("mcp-nvim.mcp.prompts")

local function get_selection_or_function()
  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  local mode = vim.fn.mode()
  local start_line, end_line

  if mode == "v" or mode == "V" or mode == "\22" then
    start_line = vim.fn.line("'<")
    end_line = vim.fn.line("'>")
  else
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    start_line = math.max(1, row - 24 + 1)
    end_line = math.min(vim.api.nvim_buf_line_count(buf), row + 25 + 1)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local numbered = {}
  for i, line in ipairs(lines) do
    table.insert(numbered, string.format("%4d | %s", start_line + i - 1, line))
  end

  return {
    filename = filename,
    filetype = ft,
    start_line = start_line,
    end_line = end_line,
    code = table.concat(numbered, "\n"),
  }
end

prompts.register("explain", {
  description = "Explain the selected code or the function at cursor. Returns an explanation using a floating window via the notify tool. Does NOT modify code.",
  arguments = {
    {
      name = "depth",
      description = "Explanation depth: 'brief' (1-2 sentences), 'normal' (default, a paragraph), or 'deep' (detailed with examples)",
      required = false,
    },
  },
}, function(args)
  local ctx = get_selection_or_function()
  local depth = args.depth or "normal"

  local depth_instruction = ({
    brief = "Give a 1-2 sentence explanation.",
    normal = "Give a clear paragraph-length explanation.",
    deep = "Give a detailed explanation including how it works, why it's designed this way, and any edge cases.",
  })[depth] or "Give a clear paragraph-length explanation."

  local system = table.concat({
    "You are a code explanation agent with access to a Neovim editor via MCP tools.",
    "Your job is to explain the code shown below.",
    "",
    "Rules:",
    "- Use the notify tool to show your explanation to the user in a floating window.",
    "- Do NOT modify any code.",
    "- " .. depth_instruction,
    "- If relevant, mention what calls this code or what it depends on.",
    "- Use the buffer and LSP tools to gather additional context if needed (e.g. lsp_hover, lsp_goto_definition).",
  }, "\n")

  local context = table.concat({
    string.format("File: %s (%s)", ctx.filename, ctx.filetype),
    string.format("Lines %d-%d:", ctx.start_line, ctx.end_line),
    "",
    ctx.code,
  }, "\n")

  return {
    description = "Explain code",
    messages = {
      { role = "user", content = { type = "text", text = system .. "\n\n" .. context } },
    },
  }
end)
