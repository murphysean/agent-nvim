local prompts = require("agent-nvim.mcp.prompts")

--- "context-switch" prompt: Helps the user understand and resume work context.
--- Reads editor state (open buffers, marks, jumplist, changes) to summarize
--- what was being worked on and help resume or transition.
prompts.register("context-switch", {
  description = "Resume or switch context. Reads your editor state (open buffers, jumplist, marks, git changes, quickfix) to understand what you were working on, summarize it, and help you resume or start something new.",
  arguments = {
    {
      name = "action",
      description = "Action: 'resume' (summarize current state and suggest next steps), 'save' (capture context to a note), or 'new' (clean up and set up for a new task)",
      required = false,
    },
    {
      name = "task",
      description = "If action is 'new', describe the new task to set up for.",
      required = false,
    },
  },
}, function(args)
  local action = args.action or "resume"
  local new_task = args.task or ""

  local buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(buf)
  local cwd = vim.fn.getcwd()

  -- Open buffers with modification status
  local buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local modified = vim.bo[b].modified and " [modified]" or ""
        local ft = vim.bo[b].filetype
        table.insert(buffers, string.format("  %s (%s)%s", vim.fn.fnamemodify(name, ":~:."), ft, modified))
      end
    end
  end

  -- Global marks (A-Z) — these are the user's bookmarks across files
  local marks = {}
  for _, mark in ipairs(vim.fn.getmarklist()) do
    local name = mark.mark:sub(2)
    if name:match("^%u$") then -- uppercase = global
      local mfile = vim.fn.fnamemodify(mark.file or "", ":~:.")
      table.insert(marks, string.format("  '%s → %s L%d", name, mfile, mark.pos[2]))
    end
  end

  -- Jumplist (recent navigation history)
  local jumps_raw = vim.fn.getjumplist()
  local jump_entries = {}
  if jumps_raw and jumps_raw[1] then
    local list = jumps_raw[1]
    local seen = {}
    for i = #list, math.max(1, #list - 19), -1 do
      local j = list[i]
      if vim.api.nvim_buf_is_valid(j.bufnr) then
        local jname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(j.bufnr), ":~:.")
        local key = jname .. ":" .. j.lnum
        if jname ~= "" and not seen[key] then
          seen[key] = true
          table.insert(jump_entries, string.format("  L%d %s", j.lnum, jname))
        end
      end
    end
  end

  -- Quickfix list (if populated — often represents a task in progress)
  local qf = vim.fn.getqflist()
  local qf_entries = {}
  if #qf > 0 then
    for i = 1, math.min(10, #qf) do
      local item = qf[i]
      local qf_file = ""
      if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
        qf_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(item.bufnr), ":~:.")
      end
      table.insert(qf_entries, string.format("  %s:%d %s", qf_file, item.lnum, item.text or ""))
    end
    if #qf > 10 then
      table.insert(qf_entries, string.format("  ... and %d more", #qf - 10))
    end
  end

  -- Git state
  local branch = vim.trim(vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null") or "")
  local git_status = vim.fn.system("git status --porcelain 2>/dev/null") or ""
  local changed_files = {}
  for line in git_status:gmatch("[^\n]+") do
    table.insert(changed_files, "  " .. line)
  end

  -- Recent commits
  local recent_log = vim.fn.system("git log --oneline -5 2>/dev/null") or ""

  local action_instruction = ({
    resume = table.concat({
      "## Task: Resume",
      "Analyze the editor state below and:",
      "1. Summarize what the user was working on (based on open files, changes, marks)",
      "2. Identify the likely next step (unfinished work, failing tests, TODO comments)",
      "3. Present this via `notify` as a concise status update",
      "4. Offer to jump to the most relevant location",
    }, "\n"),
    save = table.concat({
      "## Task: Save Context",
      "Capture the current work context to a note file:",
      "1. Summarize the current task based on editor state",
      "2. List the key files involved and what state they're in",
      "3. Note any marks, quickfix items, or breadcrumbs",
      "4. Write this to `.context-note.md` using `write_file`",
      "5. Notify the user it's saved",
    }, "\n"),
    new = table.concat({
      "## Task: Switch to New Work",
      "Help the user transition to a new task:",
      "1. Summarize what was being done (for later reference via `notify`)",
      "2. Clear marks that were task-specific",
      "3. Close buffers that aren't relevant to the new task",
      new_task ~= "" and ("4. Set up for the new task: " .. new_task) or "4. Ask what the new task is",
      "5. Open relevant files for the new task using `buffer_open`",
      "6. Set mark A at the starting point",
    }, "\n"),
  })[action] or "Summarize the current state."

  local system = table.concat({
    "# Context Switch Agent",
    "",
    "You are a context management agent connected to Neovim via MCP tools.",
    "You help the user understand, save, or transition their work context.",
    "",
    action_instruction,
    "",
    "## Current Editor State",
    string.format("Working directory: `%s`", cwd),
    string.format("Current file: `%s`", vim.fn.fnamemodify(filename, ":~:.")),
    string.format("Git branch: `%s`", branch),
    "",
    "### Open Buffers (" .. #buffers .. ")",
    #buffers > 0 and table.concat(buffers, "\n") or "  (none)",
    "",
    "### Global Marks",
    #marks > 0 and table.concat(marks, "\n") or "  (none set)",
    "",
    "### Recent Navigation (jumplist)",
    #jump_entries > 0 and table.concat(vim.list_slice(jump_entries, 1, math.min(15, #jump_entries)), "\n")
      or "  (empty)",
    "",
    "### Quickfix List",
    #qf_entries > 0 and table.concat(qf_entries, "\n") or "  (empty)",
    "",
    "### Git Changes",
    #changed_files > 0 and table.concat(changed_files, "\n") or "  Working tree clean",
    "",
    "### Recent Commits",
    recent_log ~= "" and recent_log or "  (no commits)",
  }, "\n")

  return {
    description = string.format("Context: %s", action),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
