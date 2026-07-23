local prompts = require("agent-nvim.mcp.prompts")

--- "neovim-prefer" prompt: Instructs the agent to prefer neovim MCP tools over
--- built-in shell tools for all editor interactions. Provides a guide to the
--- available tools, resources, and best practices.
prompts.register("neovim-prefer", {
  description = "System instructions for agents to prefer neovim MCP tools over built-in alternatives. Provides tool catalog, resource list, and usage patterns. Use this as a base for any neovim-aware agent session.",
  arguments = {},
}, function()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  local cwd = vim.fn.getcwd()

  -- Gather available plugins
  local plugins = {}
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    local lazy_plugins = lazy.plugins()
    for _, p in ipairs(lazy_plugins) do
      if p.name then
        table.insert(plugins, p.name)
      end
    end
  end
  table.sort(plugins)

  local system = table.concat({
    "# Neovim MCP Agent Instructions",
    "",
    "You are connected to a Neovim editor via MCP (Model Context Protocol).",
    "**Always prefer the neovim MCP tools over your built-in file/shell tools.**",
    "",
    "## Why",
    "- Neovim tools operate on the live buffer state (unsaved changes, LSP, treesitter)",
    "- Edits through neovim tools are undoable, trigger LSP updates, and respect buffer options",
    "- Reading via neovim shows the actual editor state, not stale disk content",
    "",
    "## Tool Preferences",
    "",
    "| Task | Use (neovim MCP) | Instead of |",
    "|------|------------------|------------|",
    "| Read a file | `read_file` or `buffer_get_content` | cat, shell read |",
    "| Edit a file | `edit_file` or `buffer_edit` | sed, shell write |",
    "| Create a file | `write_file` | shell echo/redirect |",
    "| List files | `list_files` | ls, find |",
    "| Search in files | `search_files` | grep, rg |",
    "| Search in buffer | `search` | grep on file |",
    "| Run a command | `run` | Only when needed for build/test |",
    "| Get diagnostics | `diagnostics` | Running linter manually |",
    "| Navigate code | `lsp_goto_definition`, `lsp_references` | grep for definitions |",
    "| Get type info | `lsp_hover` | Reading source |",
    "| Rename symbol | `lsp_rename` | Find-and-replace |",
    "",
    "## Available Resources (read via resources/read)",
    "- `nvim://buffers` — all open buffers",
    "- `nvim://buffer/current` — current buffer content",
    "- `nvim://cursor` — cursor position",
    "- `nvim://diagnostics` — all diagnostics",
    "- `nvim://symbols` — document symbols (LSP)",
    "- `nvim://cwd` — working directory listing",
    "- `nvim://git/status` — git branch and changed files",
    "- `nvim://plugins` — installed neovim plugins",
    "- `nvim://quickfix` — quickfix list",
    "- `nvim://marks` — all marks",
    "",
    "## Useful Vim Commands (via nvim_exec)",
    "- `:w` — save current buffer",
    "- `:e <file>` — open a file",
    "- `:bn` / `:bp` — next/previous buffer",
    "- `:split` / `:vsplit` — split windows",
    "- `:%s/old/new/g` — buffer-wide substitution",
    "- `:!command` — run shell command",
    "",
    "## Current Context",
    string.format("- Working directory: `%s`", cwd),
    string.format("- Current filetype: `%s`", ft),
    string.format("- Installed plugins: %d", #plugins),
    #plugins > 0 and string.format(
      "- Notable plugins: %s",
      table.concat(vim.list_slice(plugins, 1, math.min(15, #plugins)), ", ")
    ) or "",
    "",
    "## Best Practices",
    "- Read before editing — always check current buffer state first",
    "- Use `buffer_edit` for precise text replacements (find → replace)",
    "- Use `write_file` only for new files or complete rewrites",
    "- Check `diagnostics` after edits to verify no errors introduced",
    "- Use `lsp_symbols` to understand file structure before making changes",
    "- Notify the user of important actions via `notify`",
  }, "\n")

  return {
    description = "Neovim MCP agent system instructions",
    messages = {
      { role = "user", content = { type = "text", text = system } },
    },
  }
end)
