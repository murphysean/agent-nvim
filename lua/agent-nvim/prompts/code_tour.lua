local prompts = require("agent-nvim.mcp.prompts")

--- "code-tour" prompt: Instructs the agent to explore a codebase and produce
--- a structured code tour document. The agent uses neovim tools to navigate,
--- read, and understand the project structure.
prompts.register("code-tour", {
  description = "Explore and document a codebase as a structured code tour. The agent navigates the project using neovim MCP tools, reads key files, traces call paths, and produces a walkthrough document.",
  arguments = {
    {
      name = "focus",
      description = "What to focus the tour on (e.g. 'authentication flow', 'plugin architecture', 'data model'). If empty, produces a general overview.",
      required = false,
    },
    {
      name = "depth",
      description = "Tour depth: 'overview' (high-level structure), 'moderate' (key files + relationships), or 'deep' (trace call paths, explain algorithms)",
      required = false,
    },
    {
      name = "output",
      description = "Where to write the tour: 'notify' (floating window), 'buffer' (new buffer), or 'file' (write to CODE_TOUR.md)",
      required = false,
    },
  },
}, function(args)
  local focus = args.focus or ""
  local depth = args.depth or "moderate"
  local output = args.output or "buffer"

  local cwd = vim.fn.getcwd()
  local project_name = vim.fn.fnamemodify(cwd, ":t")

  -- Gather directory listing for initial context
  local entries = vim.fn.readdir(cwd)
  local dirs, files = {}, {}
  for _, entry in ipairs(entries) do
    if entry:sub(1, 1) ~= "." then
      local full = cwd .. "/" .. entry
      if vim.fn.isdirectory(full) == 1 then
        table.insert(dirs, entry .. "/")
      else
        table.insert(files, entry)
      end
    end
  end
  table.sort(dirs)
  table.sort(files)

  -- Check for common entry points
  local entry_points = {}
  local common = { "init.lua", "main.lua", "init.vim", "plugin/", "src/", "lib/", "lua/", "app/", "cmd/" }
  for _, name in ipairs(common) do
    for _, e in ipairs(entries) do
      if e == name or e == name:gsub("/$", "") then
        table.insert(entry_points, e)
      end
    end
  end

  local depth_instruction = ({
    overview = "Produce a high-level overview: directory structure, main modules, and their purpose. Don't read deeply into files.",
    moderate = "Read key files, understand relationships between modules, document the architecture and main flows.",
    deep = "Trace call paths end-to-end, explain algorithms, document interfaces between modules, note design patterns and potential issues.",
  })[depth] or "Read key files, understand relationships between modules, document the architecture and main flows."

  local output_instruction = ({
    notify = "Present the tour in a notify message (keep it concise).",
    buffer = "Create a new buffer with `nvim_exec('enew')` and write the tour there using `buffer_edit` or `write_file`.",
    file = "Write the tour to `CODE_TOUR.md` in the project root using `write_file`.",
  })[output] or "Create a new buffer and write the tour there."

  local system = table.concat({
    "# Code Tour Agent",
    "",
    "You are a code exploration agent connected to Neovim via MCP tools.",
    "Your job is to explore this project and produce a structured code tour.",
    "",
    "## Approach",
    "1. Start by using `list_files` (recursive) to understand the project structure",
    "2. Read key files to understand architecture: entry points, configs, main modules",
    "3. Use `lsp_symbols` and `lsp_goto_definition` to trace relationships",
    "4. Use `search_files` to find patterns, imports, and connections between modules",
    "5. Build a mental model, then write the tour document",
    "",
    "## Tour Format",
    "Structure your tour as:",
    "```markdown",
    "# Code Tour: [Project Name]",
    "",
    "## Overview",
    "[1-2 paragraph summary]",
    "",
    "## Architecture",
    "[Diagram or description of major components and their relationships]",
    "",
    "## Key Files",
    "### [file path]",
    "- Purpose: ...",
    "- Key exports: ...",
    "- Depends on: ...",
    "",
    "## Flows",
    "### [Flow Name]",
    "[Step-by-step trace of a key operation through the codebase]",
    "",
    "## Notes",
    "[Design decisions, patterns, gotchas, areas of complexity]",
    "```",
    "",
    "## Rules",
    "- " .. depth_instruction,
    "- " .. output_instruction,
    "- Use neovim MCP tools (read_file, list_files, lsp_symbols, search_files) to explore.",
    "- Don't guess — read the actual code.",
    focus ~= "" and ("- Focus area: " .. focus) or "- Cover the project broadly.",
    "",
    "## Project Context",
    string.format("- Project: `%s`", project_name),
    string.format("- Root: `%s`", cwd),
    string.format("- Directories: %s", table.concat(dirs, ", ")),
    string.format("- Top-level files: %s", table.concat(vim.list_slice(files, 1, math.min(20, #files)), ", ")),
    #entry_points > 0 and string.format("- Likely entry points: %s", table.concat(entry_points, ", ")) or "",
  }, "\n")

  return {
    description = string.format("Code tour: %s", focus ~= "" and focus or project_name),
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
