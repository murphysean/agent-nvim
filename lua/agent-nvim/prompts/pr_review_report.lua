local prompts = require("agent-nvim.mcp.prompts")

--- "pr-review-report" prompt: The agent researches a PR/branch, then deploys
--- an interactive review "app" into Neovim — a self-contained Lua program that
--- sets up buffers, windows, keymaps, and navigation for an interactive report.
prompts.register("pr-review-report", {
  description = "Generate an interactive PR review report deployed as a Neovim app. The agent analyzes the diff using all available tools, then sends a self-contained Lua program via lua_exec that creates an interactive, navigable review experience with diff views, annotations, keybindings, and a structured report — like shipping a single-page app to your editor.",
  arguments = {
    {
      name = "target",
      description = "What to review: a branch name (compared against current), a commit range ('abc..def'), or 'staged'. Defaults to comparing against main/master.",
      required = false,
    },
    {
      name = "focus",
      description = "Review focus: 'general' (full review), 'security' (auth, input, data), 'performance' (allocations, complexity, I/O), 'correctness' (logic, edge cases, types)",
      required = false,
    },
  },
}, function(args)
  local target = args.target or ""
  local focus = args.focus or "general"

  local cwd = vim.fn.getcwd()

  -- Detect the default branch if no target specified
  if target == "" then
    local main = vim.trim(vim.fn.system("git rev-parse --verify main 2>/dev/null"))
    if vim.v.shell_error == 0 then
      target = "main"
    else
      local master = vim.trim(vim.fn.system("git rev-parse --verify master 2>/dev/null"))
      if vim.v.shell_error == 0 then
        target = "master"
      else
        target = "HEAD~5"
      end
    end
  end

  -- Current branch
  local current_branch = vim.trim(vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null") or "")

  -- Get changed files
  local diff_files_raw = vim.fn.system(string.format("git diff --name-status %s 2>/dev/null", target))
  local changed_files = {}
  for line in (diff_files_raw or ""):gmatch("[^\n]+") do
    local status, path = line:match("^(%S+)%s+(.+)$")
    if status and path then
      table.insert(changed_files, { status = status, path = path })
    end
  end

  local diff_shortstat = vim.trim(vim.fn.system(string.format("git diff --shortstat %s 2>/dev/null", target)) or "")
  local commit_log = vim.fn.system(string.format("git log --oneline %s..HEAD 2>/dev/null", target))
  if vim.v.shell_error ~= 0 then
    commit_log = ""
  end

  -- PR metadata
  local pr_title = ""
  local pr_body = ""
  if vim.fn.executable("gh") == 1 then
    local pr_info = vim.fn.system("gh pr view --json title,body 2>/dev/null")
    if vim.v.shell_error == 0 then
      local ok, data = pcall(vim.json.decode, pr_info)
      if ok and data then
        pr_title = data.title or ""
        pr_body = data.body or ""
      end
    end
  end

  local focus_instruction = ({
    general = "Perform a comprehensive review: architecture, correctness, style, testing, documentation.",
    security = "Focus on security: auth flows, input validation, injection vectors, data exposure, privilege escalation, secrets handling.",
    performance = "Focus on performance: allocations, algorithmic complexity, I/O patterns, caching, unnecessary work, hot paths.",
    correctness = "Focus on correctness: logic errors, edge cases, type safety, error handling, race conditions, state management.",
  })[focus] or "Perform a comprehensive review."

  -- Build file list string
  local file_list = {}
  for _, f in ipairs(changed_files) do
    table.insert(file_list, string.format("  %s %s", f.status, f.path))
  end

  local system = table.concat({
    "# PR Review Report Generator",
    "",
    "You are a code review agent. Your job is to:",
    "1. **Research** the PR thoroughly using MCP tools",
    "2. **Generate** an interactive report as a self-contained Lua program",
    "3. **Deploy** it into Neovim via `lua_exec`",
    "",
    "## Phase 1: Research (use tools extensively)",
    "",
    "Before writing any report, do a deep analysis:",
    "- Use `run` to get the full diff: `git diff " .. target .. "`",
    "- Use `run` to get diff per file: `git diff " .. target .. " -- <filepath>`",
    "- Use `read_file` to read the full current version of changed files",
    "- Use `run` with `git show " .. target .. ":<filepath>` to see old versions",
    "- Use `lsp_symbols` on changed files to understand their structure",
    "- Use `lsp_references` on changed/new functions to see impact",
    "- Use `search_files` to find related code that might need updates",
    "- Use `diagnostics` to check if changes introduced errors",
    "- Read test files related to changed code",
    "",
    "Take your time. Read everything. Understand the change deeply.",
    "",
    "## Phase 2: Generate the Interactive Report",
    "",
    "After your research, construct a **single Lua program** that, when executed via",
    "`lua_exec`, creates an interactive review experience in Neovim.",
    "",
    "The Lua program you generate should create:",
    "",
    "### Content Layer (the report)",
    "- A main **report buffer** (filetype=markdown) with your full analysis",
    "- Per-file **annotation buffers** with inline commentary",
    "- A **TOC buffer** listing all stops/sections",
    "",
    "### Layout Layer (the presentation)",
    "- A dedicated tab (`:tabnew`) so the review is self-contained",
    "- Window layout: TOC sidebar (left, narrow) | main content (center) | optional diff (right)",
    "- Or: TOC top bar | diff split below | annotations bottom",
    "- Use `vim.wo` to set window-local options (number=false, signcolumn=no, wrap=true, etc.)",
    "- Use `vim.bo` to set buffer options (buftype=nofile, bufhidden=wipe, modifiable=false, filetype=markdown)",
    "",
    "### Behavior Layer (the interactivity)",
    "Buffer-local keymaps that make it navigable:",
    "- `n` / `p` or `]` / `[` — next/previous section",
    "- `<CR>` on a TOC line — jump to that section",
    "- `d` — open a diff view for the file under the current section",
    "- `o` — open the actual file at the relevant line",
    "- `q` — close the entire review (close tab, wipe buffers)",
    "- `?` — show help floating window",
    "",
    "Use `vim.keymap.set('n', key, fn, { buffer = bufnr, desc = ... })` for all keymaps.",
    "",
    "### Report Structure",
    "The markdown report should contain:",
    "```markdown",
    "# PR Review: [title]",
    "",
    "## Summary",
    "[2-3 sentence overview of what this PR does]",
    "",
    "## Verdict: [APPROVE | REQUEST_CHANGES | DISCUSS]",
    "[One-line reasoning]",
    "",
    "## Changes Overview",
    "| File | Status | Risk | Summary |",
    "|------|--------|------|---------|",
    "| ... | Modified | ⚠️ Medium | ... |",
    "",
    "## Detailed Review",
    "",
    "### [Section 1: Logical grouping]",
    "**Files:** `path/a.lua`, `path/b.lua`",
    "",
    "[Analysis, concerns, praise, suggestions]",
    "",
    "```diff",
    "- old code",
    "+ new code",
    "```",
    "",
    "💡 **Suggestion:** ...",
    "⚠️ **Concern:** ...",
    "✅ **Good:** ...",
    "",
    "### [Section N: ...]",
    "...",
    "",
    "## Testing",
    "[Are changes tested? What's missing?]",
    "",
    "## Questions for the Author",
    "1. ...",
    "2. ...",
    "```",
    "",
    "### Diff View Setup",
    "When the user presses `d`, the program should:",
    "1. Get the file path from the current section",
    "2. Open a vertical split",
    "3. Load the base version (`git show " .. target .. ":<path>`) into a scratch buffer",
    "4. Open the current version in the other split",
    "5. Run `:diffthis` on both",
    "6. Set a keymap `q` in the diff buffers to close back to the report",
    "",
    "### Example Lua Structure",
    "```lua",
    "-- The program you send via lua_exec should look like this skeleton:",
    "local report_content = [=[",
    "# PR Review: ...",
    "...full markdown report...",
    "]=]",
    "",
    "local sections = {",
    "  { title = '...', line = N, files = {'...'} },",
    "  ...",
    "}",
    "",
    "-- Create tab and buffers",
    "vim.cmd('tabnew')",
    "local report_buf = vim.api.nvim_get_current_buf()",
    "vim.bo[report_buf].buftype = 'nofile'",
    "vim.bo[report_buf].filetype = 'markdown'",
    "vim.api.nvim_buf_set_name(report_buf, 'review://report')",
    "vim.api.nvim_buf_set_lines(report_buf, 0, -1, false, vim.split(report_content, '\\n'))",
    "vim.bo[report_buf].modifiable = false",
    "",
    "-- TOC sidebar",
    "vim.cmd('topleft vsplit | vertical resize 30 | enew')",
    "local toc_buf = vim.api.nvim_get_current_buf()",
    "-- ... set up TOC content and keymaps ...",
    "",
    "-- Navigation keymaps",
    "local current_section = 1",
    "local function goto_section(idx) ... end",
    "vim.keymap.set('n', 'n', function() goto_section(current_section + 1) end, { buffer = report_buf })",
    "-- ... etc ...",
    "",
    "-- Cleanup",
    "vim.keymap.set('n', 'q', function()",
    "  vim.cmd('tabclose')",
    "end, { buffer = report_buf })",
    "```",
    "",
    "## Phase 3: Deploy",
    "",
    "Send the complete Lua program via a single `lua_exec` call.",
    "After deployment, use `notify` to tell the user:",
    "- The review is ready",
    "- Key bindings: n/p (navigate), d (diff), o (open file), q (quit)",
    "- How many sections/files were reviewed",
    "",
    "## Review Focus",
    focus_instruction,
    "",
    "## PR Context",
    string.format("- Repository: `%s`", vim.fn.fnamemodify(cwd, ":t")),
    string.format("- Branch: `%s`", current_branch),
    string.format("- Comparing against: `%s`", target),
    string.format("- Stats: %s", diff_shortstat ~= "" and diff_shortstat or "unknown"),
    pr_title ~= "" and string.format("- PR Title: %s", pr_title) or "",
    pr_body ~= "" and string.format("- PR Body: %s", pr_body:sub(1, 500)) or "",
    "",
    "### Commits",
    commit_log ~= "" and commit_log or "(unavailable)",
    "",
    "### Changed Files",
    table.concat(file_list, "\n"),
    "",
    "## Important Notes",
    "- The Lua program MUST be self-contained — no external dependencies",
    "- Use only vim.api, vim.fn, vim.keymap, vim.cmd, vim.split, vim.bo, vim.wo",
    "- Handle errors gracefully (pcall around git commands, etc.)",
    "- Make all buffers nofile/scratch so nothing accidentally writes to disk",
    "- The report should be genuinely useful — not a template, but a real analysis",
    "- Include actual diff snippets in the report markdown",
    "- Reference specific line numbers",
    "- Be opinionated — give a real verdict",
    "",
    "## Begin",
    "Start Phase 1: research the changes. Read diffs, understand the code, then build the app.",
  }, "\n")

  return {
    description = string.format(
      "PR Review Report: %s → %s (%d files, %s focus)",
      target,
      current_branch,
      #changed_files,
      focus
    ),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
