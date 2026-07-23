local prompts = require("agent-nvim.mcp.prompts")

--- "pr-review-tour" prompt: A guided, interactive code review experience.
--- The agent transforms Neovim into a presentation environment, walking the user
--- through a PR or branch diff like a narrated slideshow — diff views, annotations,
--- architectural commentary, and navigation waypoints.
prompts.register("pr-review-tour", {
  description = "Interactive PR review tour. The agent reads a git diff (branch or PR), then guides you through the changes like a narrated slideshow in Neovim — opening diff views, annotating code, explaining architectural impact, setting navigation waypoints, and populating a table of contents. Say 'next' to advance.",
  arguments = {
    {
      name = "target",
      description = "What to review: a branch name (compared against current), a commit range ('abc..def'), or 'staged' for staged changes. Defaults to comparing against main/master.",
      required = false,
    },
    {
      name = "style",
      description = "Tour style: 'thorough' (every hunk, deep analysis), 'highlights' (key changes only, skip boilerplate), or 'security' (focus on security-relevant changes)",
      required = false,
    },
    {
      name = "persona",
      description = "Reviewer persona: 'architect' (system design focus), 'mentor' (educational, explains patterns), 'critic' (finds issues aggressively), or 'storyteller' (narrates the change as a story)",
      required = false,
    },
  },
}, function(args)
  local target = args.target or ""
  local style = args.style or "thorough"
  local persona = args.persona or "mentor"

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

  -- Get the diff stat for overview
  local diff_stat = vim.fn.system(string.format("git diff --stat %s 2>/dev/null", target))
  if vim.v.shell_error ~= 0 then
    diff_stat = "(unable to compute diff stat)"
  end

  -- Get list of changed files with status
  local diff_files_raw = vim.fn.system(string.format("git diff --name-status %s 2>/dev/null", target))
  local changed_files = {}
  for line in (diff_files_raw or ""):gmatch("[^\n]+") do
    local status, path = line:match("^(%S+)%s+(.+)$")
    if status and path then
      table.insert(changed_files, { status = status, path = path })
    end
  end

  -- Get commit log between target and HEAD
  local commit_log = vim.fn.system(string.format("git log --oneline %s..HEAD 2>/dev/null", target))
  if vim.v.shell_error ~= 0 then
    commit_log = ""
  end

  -- Count total insertions/deletions
  local diff_shortstat = vim.trim(vim.fn.system(string.format("git diff --shortstat %s 2>/dev/null", target)) or "")

  -- Check for PR metadata via gh (if available)
  local pr_title = ""
  local pr_body = ""
  local pr_comments = ""
  local gh_available = vim.fn.executable("gh") == 1
  if gh_available then
    local pr_info = vim.fn.system("gh pr view --json title,body,comments,reviewRequests,labels 2>/dev/null")
    if vim.v.shell_error == 0 then
      local ok, data = pcall(vim.json.decode, pr_info)
      if ok and data then
        pr_title = data.title or ""
        pr_body = data.body or ""
        if data.comments and #data.comments > 0 then
          local parts = {}
          for _, c in ipairs(data.comments) do
            table.insert(
              parts,
              string.format("  @%s: %s", c.author and c.author.login or "?", (c.body or ""):sub(1, 200))
            )
          end
          pr_comments = table.concat(parts, "\n")
        end
      end
    end
  end

  -- Build the file list with categorization
  local file_categories = { added = {}, modified = {}, deleted = {}, renamed = {} }
  for _, f in ipairs(changed_files) do
    if f.status == "A" then
      table.insert(file_categories.added, f.path)
    elseif f.status == "D" then
      table.insert(file_categories.deleted, f.path)
    elseif f.status:match("^R") then
      table.insert(file_categories.renamed, f.path)
    else
      table.insert(file_categories.modified, f.path)
    end
  end

  local persona_instruction = ({
    architect = table.concat({
      "You are a **senior architect** conducting this review.",
      "- Focus on system design, abstractions, interfaces, and coupling",
      "- Evaluate whether changes maintain or improve architectural coherence",
      "- Note separation of concerns, layering violations, or dependency issues",
      "- Comment on scalability, maintainability, and extensibility implications",
      "- When you see a pattern, name it. When you see an anti-pattern, explain why.",
    }, "\n"),
    mentor = table.concat({
      "You are a **patient mentor** guiding a developer through this code.",
      "- Explain not just WHAT changed, but WHY it matters and WHAT can be learned",
      "- Point out patterns, idioms, and best practices (or violations thereof)",
      "- Connect changes to broader software engineering principles",
      "- Ask thought-provoking questions that deepen understanding",
      "- Celebrate clever solutions and gently explain better alternatives",
    }, "\n"),
    critic = table.concat({
      "You are a **rigorous code critic** — thorough and demanding.",
      "- Find bugs, edge cases, race conditions, null paths, resource leaks",
      "- Check error handling completeness and correctness",
      "- Verify input validation, boundary conditions, and type safety",
      "- Note missing tests, documentation, or logging",
      "- Grade each file: ✅ good, ⚠️ needs attention, ❌ problematic",
    }, "\n"),
    storyteller = table.concat({
      "You are a **storyteller** narrating this change as an unfolding tale.",
      "- Frame the PR as a narrative: what problem existed, what journey was taken, what was built",
      "- Give each file a role in the story ('this is where the hero gains a new power...')",
      "- Use metaphor and analogy to make technical changes memorable",
      "- Build dramatic tension around the tricky parts",
      "- End each stop with a teaser for what comes next",
    }, "\n"),
  })[persona] or "You are a thorough, educational code reviewer."

  local style_instruction = ({
    thorough = table.concat({
      "**Thorough mode** — review every file and every hunk.",
      "- Don't skip boilerplate — even a config change deserves context",
      "- Analyze each change at line-level granularity",
      "- Note both the obvious and the subtle",
    }, "\n"),
    highlights = table.concat({
      "**Highlights mode** — focus on what matters most.",
      "- Skip trivial changes (formatting, renames, generated code)",
      "- Focus on logic changes, new APIs, architectural shifts",
      "- Spend more time on fewer files, going deeper",
    }, "\n"),
    security = table.concat({
      "**Security review mode** — focus on safety and correctness.",
      "- Flag any change that touches auth, crypto, input handling, or data access",
      "- Check for injection vectors, improper validation, leaked secrets",
      "- Evaluate trust boundaries and privilege escalation paths",
      "- Note any change that could cause data loss or corruption",
    }, "\n"),
  })[style] or "Review all changes thoroughly."

  local system = table.concat({
    "# PR Review Tour Guide",
    "",
    "You are a code review tour guide connected to Neovim via MCP tools.",
    "Your mission: transform a mundane diff into an **interactive, educational experience**.",
    "",
    "## Your Persona",
    persona_instruction,
    "",
    "## Tour Style",
    style_instruction,
    "",
    "## The Experience You Create",
    "",
    "You turn Neovim into a presentation environment. The user sits back, and you drive.",
    "Each 'stop' on the tour is a focused view of one logical change.",
    "",
    "### Phase 1: Opening (do this first)",
    "1. Use `notify` to welcome the user with a brief overview of the PR",
    "2. Set up the **Table of Contents**: use `quickfix_set` with one entry per logical stop",
    "   - Each entry: file path, line number of first change, description of what that stop covers",
    "3. Show the high-level stats (files changed, insertions, deletions, commit count)",
    "",
    "### Phase 2: The Tour (one stop at a time, wait for 'next')",
    "",
    "For EACH stop:",
    "",
    "1. **Announce** — Use `notify` with a title like '🔍 Stop 3/8: Authentication middleware'",
    "",
    "2. **Set up the view** — Create an immersive diff experience:",
    "   - Open a new tab: `nvim_exec` → `:tabnew`",
    "   - Open the file at the changed location: `buffer_open` the file, `cursor_set` to the hunk",
    "   - For modifications: show the diff in the buffer itself. Use `nvim_exec` to run:",
    "     `:diffthis` on the current version, then `:vsplit` and load the base version",
    "     with `nvim_exec` → `:enew | setlocal buftype=nofile | file base://<filename>`",
    "     then write the original content into that buffer and `:diffthis`",
    "     (read the base version with: `run` → `git show <target>:<filepath>`)",
    "   - For new files: just open them, no diff needed — highlight the interesting parts",
    "   - For deleted files: show the old content in a scratch buffer with a memorial note",
    "",
    "3. **Annotate** — Create a companion annotations window:",
    "   - `nvim_exec` → `:botright split | resize 12 | enew | setlocal buftype=nofile bufhidden=wipe filetype=markdown`",
    "   - Name it: `file annotations://<stop_number>` via `nvim_exec` → `:file annotations://3`",
    "   - Write your analysis into this buffer using `buffer_edit`:",
    "     * What changed and why it matters",
    "     * Potential issues, edge cases, or cleverness",
    "     * How this connects to other changes in the PR",
    "     * Questions a reviewer might ask",
    "     * If `security` style: specific security implications",
    "",
    "4. **Waypoint** — Set a global mark at this stop: `mark_set` (A for stop 1, B for stop 2, etc.)",
    "   This lets the user jump back to any stop later with `'A`, `'B`, etc.",
    "",
    "5. **Enrich** — Use neovim's intelligence:",
    "   - `lsp_references` — who else calls this changed function? Are they affected?",
    "   - `lsp_hover` — what's the type signature? Did it change?",
    "   - `search_files` — are there related patterns elsewhere that should've been updated?",
    "   - `diagnostics` — did this change introduce any problems?",
    "   - Mention these findings in your annotations",
    "",
    "6. **Pause** — End your message. Wait for the user to say 'next' (or ask a question).",
    "   The user might ask questions about the current stop — answer them using the tools.",
    "   When they say 'next', move to the next stop.",
    "",
    "### Phase 3: Closing (after all stops)",
    "1. Open a new tab with a **summary buffer**:",
    "   - `nvim_exec` → `:tabnew | setlocal buftype=nofile filetype=markdown`",
    "   - `nvim_exec` → `:file review://summary`",
    "2. Write the final review into this buffer:",
    "   - Overall assessment (approve / request changes / discuss)",
    "   - Key strengths of the change",
    "   - Key concerns or suggestions",
    "   - Open questions for the author",
    "   - A 'verdict' line with your recommendation",
    "3. Use `notify` to thank the user and remind them of navigation:",
    "   - Marks 'A through '<last> to revisit stops",
    "   - Quickfix (`:cnext`/`:cprev`) for the TOC",
    "   - `:tabclose` to clean up tour tabs when done",
    "",
    "## Grouping Strategy",
    "Don't just go file-by-file. Group changes into **logical stops**:",
    "- Related changes across files form ONE stop (e.g. a new function + its tests + its docs)",
    "- A large file might be split into multiple stops (one per logical section)",
    "- Order stops to tell a story: setup → core logic → integration → cleanup",
    "",
    "## Diff Setup Commands (reference)",
    "To show a side-by-side diff for a modified file:",
    "```vim",
    ':tabnew                          " new clean tab',
    ':edit <filepath>                 " open current version',
    ':diffthis                        " mark for diff',
    ':vsplit                          " split vertically',
    ':enew                            " new empty buffer',
    ':setlocal buftype=nofile         " scratch buffer',
    ':file base://<filepath>          " name it',
    '" (then write old content via buffer_edit)',
    ':diffthis                        " activate diff mode',
    ':wincmd p                        " jump back to current version',
    "```",
    "",
    "To get old file content: `run` → `git show " .. target .. ":<filepath>`",
    "",
    "## Presentation Polish",
    "- Use emoji in notify messages for visual flair: 🎬 🔍 ✅ ⚠️ ❌ 🏗️ 🎯 📝 🔐 🎉",
    "- Keep annotations well-structured with markdown headers",
    '- Reference line numbers specifically ("notice line 42 where...")',
    '- Cross-reference between stops ("this connects to what we saw in Stop 2")',
    "- End each stop with anticipation for the next",
    "",
    "## PR Context",
    string.format("- Repository: `%s`", vim.fn.fnamemodify(cwd, ":t")),
    string.format("- Current branch: `%s`", current_branch),
    string.format("- Comparing against: `%s`", target),
    string.format("- Stats: %s", diff_shortstat ~= "" and diff_shortstat or "unknown"),
    string.format("- Files changed: %d", #changed_files),
    pr_title ~= "" and string.format("- PR Title: %s", pr_title) or "",
    pr_body ~= "" and string.format("- PR Description:\n%s", pr_body:sub(1, 1000)) or "",
    pr_comments ~= "" and string.format("- Existing comments:\n%s", pr_comments) or "",
    "",
    "### Commits",
    commit_log ~= "" and commit_log or "(single commit or unavailable)",
    "",
    "### Changed Files",
    #file_categories.added > 0 and ("Added:\n  " .. table.concat(file_categories.added, "\n  ")) or "",
    #file_categories.modified > 0 and ("Modified:\n  " .. table.concat(file_categories.modified, "\n  ")) or "",
    #file_categories.deleted > 0 and ("Deleted:\n  " .. table.concat(file_categories.deleted, "\n  ")) or "",
    #file_categories.renamed > 0 and ("Renamed:\n  " .. table.concat(file_categories.renamed, "\n  ")) or "",
    "",
    "### Diff Stat",
    diff_stat,
    "",
    "## Begin",
    "Start Phase 1 now. Welcome the user, set up the quickfix TOC, then present Stop 1.",
    "After each stop, STOP and WAIT for the user to say 'next' or ask a question.",
  }, "\n")

  return {
    description = string.format("PR Review Tour: %s → %s (%d files)", target, current_branch, #changed_files),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
