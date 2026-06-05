# mcp-nvim TODO

## Features

### Claude Code keybinds (non-interactive agent triggers)
Use `claude -p` from Neovim autocommands/keymaps to trigger single-turn agent calls.
`<leader>a` prefix is available and unused — reserve as the MCP/agent namespace.

Planned mappings:
- `<leader>af` — "fix diagnostics on this line" (haiku, fast)
- `<leader>ae` — "explain this function" (response in floating window)
- `<leader>ar` — "refactor the selected region" (opus, edits in place)
- `<leader>as` — generate project-specific snippets
- `<leader>ag` — agent grep → quickfix

System prompt tells the agent to use the neovim MCP server for all feedback.
Flags: `-p`, `--system-prompt`, `--allowedTools`, `--model`

### Project-specific snippet generation
Have an agent analyze project patterns/conventions and generate LuaSnip snippets.
Write to a project-local `.luasnippets/` directory that LuaSnip auto-loads.
Could be triggered via `:McpGenSnippets` or a keybind that runs `claude -p`.
Agent regenerates as the project evolves — new patterns emerge, snippets update.

### Progress token support
Client includes `_meta.progressToken` in tool call requests.
Server sends `notifications/progress` with that token during long-running operations.
Useful for: grep_workspace, workspace-wide diagnostics, LSP operations.

