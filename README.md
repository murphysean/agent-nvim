# mcp-nvim

<p align="center">
  <a href="https://github.com/murphysean/mcp-nvim"><img src="https://img.shields.io/badge/github-murphysean/mcp--nvim-181717?style=flat&logo=github" alt="GitHub"></a>
  <a href="https://github.com/neovim/neovim/releases/tag/stable"><img src="https://img.shields.io/badge/Neovim-0.11-90E59A?style=flat&logo=neovim&logoColor=white" alt="Neovim"></a>
  <a href="https://github.com/murphysean/mcp-nvim/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="https://github.com/murphysean/mcp-nvim/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/murphysean/mcp-nvim/ci.yml?style=flat&logo=githubactions&label=stylua" alt="CI"></a>
</p>

A Neovim plugin that exposes a local MCP (Model Context Protocol) server over Streamable HTTP. External AI agents — Claude Code, Goose, Kiro CLI — connect to your running Neovim instance and get an LLM-friendly API to list directories, search files, read with line numbers, and edit with inline diffs that you review and accept before they're applied. Also exposes LSP, diagnostics, quickfix, terminals, and full Ex command access.

When a connected client supports **sampling**, the plugin activates AI-powered features directly in the editor: code completion, explain, fix, refactor, and review — all driven by the connected agent's LLM through MCP's `sampling/createMessage` protocol.

## Requirements

- **Neovim** ≥ 0.11

## Why

Instead of embedding an LLM inside Neovim, let external agents drive your editor. You stay in your terminal running Claude Code and say "find all usages of `AuthMiddleware` and put them in my quickfix list" — the agent researches it, then pushes the results into your Neovim session for you to navigate with `:cnext` / `:cprev`.

With sampling support, the flow also works in reverse: you press `<leader>ac` in the editor, and the plugin sends a completion request *through* the connected agent's LLM — giving you AI-assisted coding without leaving Neovim or configuring a separate API key.

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
  port = 0,                     -- 0 = kernel picks a free port (per-instance isolation)
  auto_start = true,            -- Start server when Neovim launches
  allow_code_execution = true,  -- Enable lua_exec, nvim_exec, nvim_eval, run (set false to disable)
  review_edits = true,          -- Show diff review UI before applying edit_file/write_file
  log_level = "info",           -- Event broadcast level: "debug", "info", "warning", "error"
})
```

By default `port = 0` lets the OS pick a free port so multiple Neovim
instances don't collide. Discover the URL for the current instance with
`:McpStatus`, copy it with `:McpUrl!`, or read the per-instance lockfile at
`$XDG_RUNTIME_DIR/mcp-nvim/<pid>.json` (falls back to `stdpath('state')`).
Set `port = 3000` for a fixed port if you need a stable URL for legacy
single-instance setups.

## Commands

| Command            | Description                              |
|--------------------|------------------------------------------|
| `:McpStart`        | Start the MCP server                     |
| `:McpStop`         | Stop the MCP server                      |
| `:McpStatus`       | Show server status and session count     |
| `:McpSample`       | Send a sampling/createMessage request    |
| `:McpAutoComplete` | AI code completion at cursor (normal/visual) |

## AI Assist (Sampling)

When a connected client supports `sampling/createMessage`, the plugin dynamically activates AI-powered keybindings. These are **only available** when a capable client is connected — they disappear when the client disconnects.

| Keybind | Mode | Action |
|---------|------|--------|
| `<leader>ac` | n, v | **Code completion** — generates code at cursor or replaces selection |
| `<leader>ae` | n, v | **Explain** — explains the selection or function in a new tab |
| `<leader>af` | n, v | **Fix** — repairs diagnostics (errors/warnings) in the buffer |
| `<leader>ar` | n, v | **Refactor** — prompts for instructions, then rewrites the selection |
| `<leader>av` | n, v | **Review** — opens a code review in a new scratch tab |

### How it works

1. Each command gathers rich context: cursor position, surrounding code, LSP symbols, treesitter scope, diagnostics, imports, git diff
2. A prompt template (`prompts/templates/*.md`) is rendered with the context
3. The rendered prompt is sent to the connected client via `sampling/createMessage`
4. The client's LLM generates a response
5. The response is applied: inserted (complete), shown in a tab (explain/review), or applied to the buffer (fix/refactor)

### blink.cmp Integration

If [blink.cmp](https://github.com/saghen/blink.cmp) is installed, the plugin **automatically registers** as a completion source — no configuration needed. Type a few characters and "✨ AI Complete" appears in your completion menu. Accept it to trigger AI completion.

Trigger keywords: `ai`, `llm`, `gen`, `complete`, `autocomplete`, `fillmein`, `helpme`

### completefunc/omnifunc Fallback

For users without blink.cmp, the plugin claims `completefunc` and/or `omnifunc` on buffers where they're unclaimed:

- `<C-x><C-u>` — triggers AI completion via completefunc
- `<C-x><C-o>` — triggers AI completion via omnifunc (only if no LSP is attached)

These are claimed dynamically per-buffer and released when the client disconnects.

## Connecting Clients

### Claude Code

```bash
claude mcp add --transport http neovim http://127.0.0.1:3000/mcp
```

Or add to `.claude/settings.json`:

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

Add to `~/.config/goose/config.yaml`:

```yaml
extensions:
  neovim:
    type: streamable_http
    uri: http://127.0.0.1:3000/mcp
```

Or via CLI:

```bash
goose configure
# Select "Add Extension" → "Streamable HTTP" → url: http://127.0.0.1:3000/mcp
```

### Any MCP Client

- **Endpoint:** `http://127.0.0.1:3000/mcp`
- **Transport:** Streamable HTTP (POST for JSON-RPC, GET for SSE notifications)
- **Protocol version:** 2025-03-26
- **No authentication required** (localhost only)

## MCP Capabilities

| Capability   | Status | Notes |
|-------------|--------|-------|
| Tools        | 43 tools | Full editor control |
| Resources    | 17 static + 3 templates | Live editor state with auto-subscriptions |
| Prompts      | 8 prompts | Neovim-specific agent workflows |
| Completions  | Supported | Autocomplete for resource URIs and prompt args |
| Logging      | Supported | Editor events broadcast to connected clients |
| Progress     | Supported | Real-time status during edit review (awaiting, reviewing, editing) |
| Roots        | Supported | Stores client-declared project roots |
| Sampling     | Supported | AI completion, explain, fix, refactor, review |

## Prompts

Agent workflow templates exposed via `prompts/list`. These provide rich, context-aware instructions for clients to use as starting points for neovim-integrated AI tasks:

| Prompt | Description |
|--------|-------------|
| `neovim-prefer` | System instructions to prefer neovim MCP tools over built-in alternatives. Tool catalog, resources, vim commands, best practices. |
| `code-tour` | Explore and document a codebase as a structured tour using neovim navigation tools. |
| `pair-program` | Pair programming mode — agent observes editor state and assists contextually. |
| `diagnostic-repair` | Systematic diagnostic resolution — dependency-ordered, with verification. |
| `navigate` | Guided code exploration — traces paths via LSP, sets marks, populates quickfix. |
| `context-switch` | Resume or transition work context — reads buffers, marks, jumplist, git state. |

## Tools

### Buffers
- `buffer_list` — List open buffers
- `buffer_get_content` — Read buffer contents (with optional line ranges)
- `buffer_open` — Open a file
- `buffer_close` — Close a buffer
- `buffer_edit` — Find-and-replace within a buffer (in-memory)

### Files
- `read_file` — Read a file with line numbers (workspace-scoped)
- `edit_file` — Find-and-replace edit with interactive review
- `write_file` — Create or overwrite a file
- `list_files` — List files and directories
- `search_files` — Search text across workspace (uses ripgrep)
- `run` — Execute a shell command
- `diagnostics` — Get LSP diagnostics for workspace or a file

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

## Prompt Templates

The prompt templates used by AI assist commands live in `prompts/templates/` as Markdown files with `{placeholder}` variables. You can customize them:

```
prompts/templates/
├── autocomplete.md   — System prompt for code completion
├── explain.md        — System prompt for explain
├── fix.md            — System prompt for diagnostic repair
├── refactor.md       — System prompt for refactoring
└── review.md         — System prompt for code review
```

Available placeholders include: `{filepath}`, `{filetype}`, `{cursor_line}`, `{cursor_col}`, `{lines_before}`, `{lines_after}`, `{current_line}`, `{selection}`, `{diagnostics}`, `{document_symbols}`, `{imports}`, `{enclosing_function}`, `{scope_chain}`, `{node_type}`, `{workspace_root}`, `{open_buffers}`, `{git_diff}`, `{mode}`, `{instructions}`.

## Architecture

```
┌─────────────┐        HTTP POST /mcp        ┌─────────────┐
│ Claude Code │ ──────────────────────────────▶│   Neovim    │
│   / Goose   │ ◀──────────────────────────────│  mcp-nvim   │
│   / Kiro    │        JSON-RPC response       │   plugin    │
└─────────────┘                                └─────────────┘
       │                                             │
   GET /mcp (SSE)                              vim.api / vim.lsp
   ◀── notifications                           vim.fn / vim.loop
       │                                             │
  sampling/createMessage ──▶ LLM ──▶ response  autocommands →
  (AI assist features)                         event broadcast
```

The plugin uses Neovim's built-in libuv bindings (`vim.loop`) to run an HTTP server directly in the editor process. All tool handlers execute on the main Neovim thread via `vim.schedule`, ensuring safe access to the API.

**Sampling flow:** When you trigger an AI assist command (`<leader>ac`, etc.), the plugin sends a `sampling/createMessage` request over the existing SSE connection to the client. The client routes it to its LLM provider and returns the response. This means you get AI features using whatever model/provider the client is configured with — no separate API key needed in Neovim.

## Security

- The server only listens on localhost by default
- CORS is restricted to localhost origins (no arbitrary web page access)
- `lua_exec`, `nvim_exec`, `nvim_eval`, and `run` execute arbitrary code — disable with `allow_code_execution = false`
- No authentication (any local process can connect) — suitable for single-user development machines
- Sampling requests only go to already-connected clients (never to external services)

## License

MIT
