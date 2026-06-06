# mcp-nvim

<p align="center">
  <a href="https://github.com/murphysean/mcp-nvim"><img src="https://img.shields.io/badge/github-murphysean/mcp--nvim-181717?style=flat&logo=github" alt="GitHub"></a>
  <a href="https://github.com/neovim/neovim/releases/tag/stable"><img src="https://img.shields.io/badge/Neovim-0.11-90E59A?style=flat&logo=neovim&logoColor=white" alt="Neovim"></a>
  <a href="https://github.com/murphysean/mcp-nvim/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="https://github.com/murphysean/mcp-nvim/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/murphysean/mcp-nvim/ci.yml?style=flat&logo=githubactions&label=stylua" alt="CI"></a>
</p>

A Neovim plugin that exposes a local MCP (Model Context Protocol) server over Streamable HTTP. External AI agents — Claude Code, Goose, Kiro CLI — connect to your running Neovim instance and get full access to buffers, LSP, navigation, diagnostics, and commands.

## Requirements

- **Neovim** ≥ 0.11

## Why

Instead of embedding an LLM inside Neovim, let external agents drive your editor. You stay in your terminal running Claude Code and say "trace the code path from `handleRequest` to the database layer and load it as a jump list" — the agent researches it, then pushes the results into your Neovim session for you to navigate with `Ctrl-I` / `Ctrl-O`.

## Install

### lazy.nvim

```lua
{
  "murphysean/mcp-nvim",
  lazy = false,
  config = function()
    require("mcp-nvim").setup({
      host = "127.0.0.1",
      port = 3000,
      auto_start = true,
    })
  end,
}
```

### Local development (lazy.nvim)

```lua
{
  dir = "~/path/to/mcp-nvim",
  name = "mcp-nvim",
  lazy = false,
  config = function()
    require("mcp-nvim").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "murphysean/mcp-nvim",
  config = function()
    require("mcp-nvim").setup()
  end,
}
```

## Configuration

```lua
require("mcp-nvim").setup({
  host = "127.0.0.1",           -- Listen address
  port = 3000,                  -- Listen port
  auto_start = true,            -- Start server when Neovim launches
  allow_code_execution = true,  -- Enable lua_exec, nvim_exec, nvim_eval, run (set false to disable)
  review_edits = true,          -- Show diff review UI before applying edit_file/write_file
  log_level = "info",           -- Event broadcast level: "debug", "info", "warning", "error"
})
```

## Commands

| Command       | Description                              |
|---------------|------------------------------------------|
| `:McpStart`   | Start the MCP server                     |
| `:McpStop`    | Stop the MCP server                      |
| `:McpStatus`  | Show server status and session count     |
| `:McpSample`  | Send a sampling/createMessage request    |

## Connecting Clients

### Claude Code

**Option A: CLI (recommended)**

```bash
claude mcp add --transport http neovim http://127.0.0.1:3000/mcp
```

This persists to `~/.claude.json` and is available across all projects.

**Option B: Project-scoped**

Add to `.claude/settings.json` in your project root:

```json
{
  "mcpServers": {
    "neovim": {
      "type": "url",
      "url": "http://127.0.0.1:3000/mcp"
    }
  }
}
```

**Verify it's connected:**

```bash
claude mcp list
```

You should see `neovim` with status "connected" and all 43 tools listed.

### Kiro CLI

Add to your Kiro MCP configuration (`~/.kiro/settings.json` or project-level):

```json
{
  "mcpServers": {
    "neovim": {
      "type": "url",
      "url": "http://127.0.0.1:3000/mcp"
    }
  }
}
```

Or use the CLI:

```bash
kiro mcp add neovim --url http://127.0.0.1:3000/mcp
```

### Goose

Add to your Goose configuration (`~/.config/goose/config.yaml`):

```yaml
extensions:
  neovim:
    type: streamable_http
    uri: http://127.0.0.1:3000/mcp
```

Or add via CLI:

```bash
goose configure
# Select "Add Extension" → "Streamable HTTP" → url: http://127.0.0.1:3000/mcp
```

### Any MCP Client (Generic)

The server speaks standard MCP over Streamable HTTP. Any client that supports the `http` transport can connect:

- **Endpoint:** `http://127.0.0.1:3000/mcp`
- **Transport:** Streamable HTTP (POST for JSON-RPC, GET for SSE notifications)
- **Protocol version:** 2025-03-26
- **No authentication required** (localhost only)

## MCP Capabilities

| Capability   | Status | Notes |
|-------------|--------|-------|
| Tools        | 43 tools | Full editor control |
| Resources    | 17 static + 3 templates | Live editor state with subscriptions |
| Prompts      | 5 prompts | Context-rich agent instructions |
| Completions  | Supported | Autocomplete for resource URIs and prompt args |
| Logging      | Supported | Editor events broadcast to connected clients |
| Roots        | Supported | Stores client-declared project roots |
| Sampling     | Stubbed | Ready for when clients support it |

## Tools

### Buffers
- `buffer_list` — List open buffers
- `buffer_get_content` — Read buffer contents (with optional line ranges)
- `buffer_open` — Open a file
- `buffer_close` — Close a buffer

### Files
- `read_file` — Read a file with line numbers (workspace-scoped)
- `edit_file` — Find-and-replace edit with interactive review
- `write_file` — Create or overwrite a file
- `list_files` — List files and directories
- `search_files` — Search text across workspace (uses ripgrep)
- `run` — Execute a shell command
- `diagnostics` — Get LSP diagnostics for workspace or a file

### Editing
- `buffer_edit` — Find-and-replace within a buffer (in-memory)

### Navigation
- `cursor_get` / `cursor_set` — Read/move cursor
- `search` — Search current buffer
- `mark_set` / `mark_get` — Named marks (a-z local, A-Z global)

### LSP
- `lsp_goto_definition` — Jump to definition
- `lsp_references` — Find all references
- `lsp_hover` — Get type/doc info
- `lsp_symbols` — Document symbols
- `lsp_workspace_symbols` — Workspace symbol search
- `lsp_rename` — Rename across project
- `lsp_code_actions` — Get/apply code actions
- `lsp_get_clients` — List active LSP clients

### Quickfix & Location Lists
- `quickfix_set` / `quickfix_get` — Populate quickfix with results
- `loclist_set` — Populate location list

### Windows & Tabs
- `window_list` — List windows
- `window_split` — Split windows
- `window_close` — Close a window
- `tab_list` — List tabs

### Terminal
- `terminal_open` — Open an integrated terminal
- `terminal_send` — Send commands to a terminal

### Commands & Options
- `nvim_exec` — Run any Ex command
- `nvim_eval` — Evaluate Vimscript
- `lua_exec` — Execute Lua in Neovim's runtime
- `keymap_list` — List keymaps
- `user_command_list` — List user commands
- `option_get` / `option_set` — Read/write options
- `nvim_info` — Instance info, plugins, cwd

### Notifications
- `notify` — Show a message to the user

## Resources

Live editor state accessible via `resources/read`:

| URI | Description |
|-----|-------------|
| `nvim://buffers` | All open buffers with metadata |
| `nvim://buffer/current` | Current buffer contents |
| `nvim://buffer/{id}` | Specific buffer by number |
| `nvim://selection` | Current visual selection |
| `nvim://cursor` | Cursor position with surrounding context |
| `nvim://diagnostics` | All diagnostics across open buffers |
| `nvim://diagnostics/{bufnr}` | Diagnostics for a specific buffer |
| `nvim://symbols` | Document symbols in current buffer |
| `nvim://quickfix` | Quickfix list contents |
| `nvim://jumplist` | Jump list entries |
| `nvim://loclist` | Location list contents |
| `nvim://marks` | All marks |
| `nvim://changelist` | Change list |
| `nvim://autocmds` | Registered autocommands |
| `nvim://options` | Key editor options |
| `nvim://plugins` | Loaded plugins |
| `nvim://keymaps/{mode}` | Keymaps for a mode (n, i, v, x, etc.) |
| `nvim://cwd` | Working directory and file listing |
| `nvim://git/status` | Git branch and file status |
| `nvim://roots` | Client-declared project roots |

Resources support subscriptions — clients receive `notifications/resources/updated` via SSE when editor state changes.

## Prompts

Pre-built prompt templates with dynamic context gathering:

| Prompt | Description | Arguments |
|--------|-------------|-----------|
| `complete` | Code completion at cursor | `instructions` (optional) |
| `fix` | Fix diagnostics at cursor or in buffer | `scope`: line, buffer |
| `explain` | Explain selected code or function | `depth`: brief, normal, deep |
| `refactor` | Refactor selected region | `instructions` (optional) |
| `review` | Review buffer or git diff | `scope`: buffer, diff, staged; `focus`: bugs, security, performance, style, all |

Each prompt gathers relevant context (cursor position, surrounding code, diagnostics, file type) and returns messages instructing the agent to use only MCP tools for feedback.

## Example Workflows

**Research a code path, load as jump list:**
> "Trace how a request flows from the HTTP handler to the database in this project, then load the key locations into my Neovim jump list."

**Fix diagnostics:**
> "Check what LSP errors are in my current buffer and fix them."

**Generate code:**
> "Complete the struct definition at line 42 in main.go"

**Workspace search:**
> "Find all usages of `AuthMiddleware` and put them in my quickfix list"

**Code review with marks:**
> "Review the current file for security issues and set marks at each finding"

## Architecture

```
┌─────────────┐        HTTP POST /mcp        ┌─────────────┐
│ Claude Code │ ──────────────────────────────▶│   Neovim    │
│   / Goose   │ ◀──────────────────────────────│  mcp-nvim   │
│   / Kiro    │        JSON-RPC response       │   plugin    │
└─────────────┘                                └─────────────┘
       │                                             │
   GET /mcp                                    vim.api / vim.lsp
   (SSE stream)                                vim.fn / vim.loop
       │                                             │
  notifications:                              autocommands →
  resource updates,                           event broadcast
  log messages
```

The plugin uses Neovim's built-in libuv bindings (`vim.loop`) to run an HTTP server directly in the editor process. All tool handlers execute on the main Neovim thread via `vim.schedule`, ensuring safe access to the API.

## Security

- The server only listens on localhost by default
- CORS is restricted to localhost origins (no arbitrary web page access)
- `lua_exec`, `nvim_exec`, `nvim_eval`, and `run` execute arbitrary code — disable with `allow_code_execution = false`
- No authentication (any local process can connect) — suitable for single-user development machines

## License

MIT
