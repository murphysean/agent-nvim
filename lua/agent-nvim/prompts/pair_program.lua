local prompts = require("agent-nvim.mcp.prompts")

--- "pair-program" prompt: The agent becomes a pair programming partner that
--- is aware of your live editor state — cursor position, open buffers, recent
--- edits, diagnostics. It provides contextual suggestions as you work.
prompts.register("pair-program", {
  description = "Pair programming mode. The agent monitors your editor state (open buffers, cursor, diagnostics, recent changes) and provides contextual coding assistance through neovim MCP tools.",
  arguments = {
    {
      name = "focus",
      description = "What you're working on (e.g. 'implementing the auth flow', 'fixing tests', 'refactoring the parser'). Helps the agent stay relevant.",
      required = false,
    },
    {
      name = "style",
      description = "Interaction style: 'proactive' (suggests things without being asked), 'reactive' (only helps when asked), or 'mentor' (explains reasoning)",
      required = false,
    },
  },
}, function(args)
  local focus = args.focus or ""
  local style = args.style or "reactive"

  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  local cwd = vim.fn.getcwd()
  local cursor = vim.api.nvim_win_get_cursor(0)

  -- Gather open buffers
  local buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local modified = vim.bo[b].modified and " [+]" or ""
        table.insert(buffers, vim.fn.fnamemodify(name, ":~:.") .. modified)
      end
    end
  end

  -- Get recent jumplist (shows where the user has been navigating)
  local jumps = vim.fn.getjumplist()
  local recent_jumps = {}
  if jumps and jumps[1] then
    local list = jumps[1]
    local start = math.max(1, #list - 9)
    for i = start, #list do
      local j = list[i]
      local jbuf = j.bufnr
      if vim.api.nvim_buf_is_valid(jbuf) then
        local jname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(jbuf), ":~:.")
        if jname ~= "" then
          table.insert(recent_jumps, string.format("  L%d %s", j.lnum, jname))
        end
      end
    end
  end

  -- Get diagnostics summary
  local all_diags = vim.diagnostic.get()
  local error_count = 0
  local warn_count = 0
  for _, d in ipairs(all_diags) do
    if d.severity == vim.diagnostic.severity.ERROR then
      error_count = error_count + 1
    elseif d.severity == vim.diagnostic.severity.WARN then
      warn_count = warn_count + 1
    end
  end

  -- Current buffer context (around cursor)
  local total = vim.api.nvim_buf_line_count(buf)
  local start_l = math.max(0, cursor[1] - 16)
  local end_l = math.min(total, cursor[1] + 15)
  local lines = vim.api.nvim_buf_get_lines(buf, start_l, end_l, false)
  local numbered = {}
  for i, line in ipairs(lines) do
    local prefix = (start_l + i == cursor[1]) and " >> " or "    "
    table.insert(numbered, string.format("%s%4d | %s", prefix, start_l + i, line))
  end

  -- Git status (what's been changed)
  local git_status = vim.fn.system("git status --porcelain 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    git_status = ""
  end
  local changed_files = {}
  for line in git_status:gmatch("[^\n]+") do
    table.insert(changed_files, "  " .. line)
  end

  local style_instruction = ({
    proactive = table.concat({
      "Be PROACTIVE. As you observe the editor state:",
      "- Suggest improvements when you notice code smells",
      "- Point out potential bugs based on diagnostics and context",
      "- Offer to complete patterns you see forming",
      "- Use `notify` to surface suggestions without disrupting flow",
    }, "\n"),
    reactive = table.concat({
      "Be REACTIVE. Wait for the user to ask before acting.",
      "- Use `notify` sparingly — only for critical issues (e.g. breaking errors)",
      "- When asked, use the full context below to give targeted help",
      "- Focus on the immediate task the user is working on",
    }, "\n"),
    mentor = table.concat({
      "Be a MENTOR. Explain your reasoning as you help:",
      "- When suggesting changes, explain WHY (not just what)",
      "- Point out patterns and principles the user might learn from",
      "- Ask guiding questions via `notify` instead of just giving answers",
      "- Reference documentation or language idioms when relevant",
    }, "\n"),
  })[style] or "Be reactive — help when asked."

  local system = table.concat({
    "# Pair Programming Agent",
    "",
    "You are a pair programming partner connected to the user's Neovim editor via MCP.",
    "You can see their editor state and assist them in real-time.",
    "",
    "## Your Role",
    style_instruction,
    "",
    "## Capabilities",
    "- Read any file or buffer via `read_file` / `buffer_get_content`",
    "- Make edits via `edit_file` / `buffer_edit`",
    "- Check diagnostics (errors/warnings) via `diagnostics`",
    "- Navigate code via `lsp_goto_definition`, `lsp_references`, `lsp_hover`",
    "- Search the project via `search_files`",
    "- Communicate via `notify` (non-intrusive floating messages)",
    "- Set marks at important locations via `mark_set`",
    "- Populate quickfix list for multi-location results via `quickfix_set`",
    "",
    "## Current Editor State",
    string.format("Working directory: `%s`", cwd),
    string.format("Current file: `%s` (%s) — cursor at line %d", vim.fn.fnamemodify(filename, ":~:."), ft, cursor[1]),
    string.format("Diagnostics: %d errors, %d warnings across workspace", error_count, warn_count),
    "",
    "Open buffers:",
    "  " .. table.concat(buffers, "\n  "),
    "",
    #recent_jumps > 0 and ("Recent navigation (jumplist):\n" .. table.concat(recent_jumps, "\n")) or "",
    "",
    #changed_files > 0 and ("Uncommitted changes:\n" .. table.concat(changed_files, "\n")) or "Working tree clean.",
    "",
    "Code around cursor:",
    table.concat(numbered, "\n"),
    "",
    focus ~= "" and ("## Current Focus\n" .. focus) or "",
  }, "\n")

  return {
    description = string.format("Pair programming%s", focus ~= "" and (": " .. focus) or ""),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
