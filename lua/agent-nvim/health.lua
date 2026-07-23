local M = {}

function M.check()
  vim.health.start("agent-nvim")

  -- Plugin version
  local plugin = require("agent-nvim")
  vim.health.info("Version: " .. plugin.version)

  -- Server status
  local server = require("agent-nvim.server")
  if server.is_running() then
    vim.health.ok("MCP server running at " .. server.url())
    vim.health.info("Port: " .. tostring(server.port()))
  else
    vim.health.warn("MCP server is not running (use :McpStart)")
  end

  -- Active sessions
  local ok_sessions, sessions = pcall(require, "agent-nvim.sessions")
  if ok_sessions then
    local count = sessions.count()
    if count > 0 then
      vim.health.ok(count .. " active MCP session(s)")
      for _, s in ipairs(sessions.list()) do
        local sub_count = s.subscriptions and #s.subscriptions or 0
        vim.health.info("  Session " .. s.id .. " (" .. sub_count .. " subscriptions)")
      end
    else
      vim.health.info("No MCP clients connected")
    end
  else
    vim.health.warn("Could not load session module")
  end

  -- Sampling / AI assist
  local lifecycle = require("agent-nvim.sampling_lifecycle")
  if lifecycle.is_active() then
    vim.health.ok("AI assist features active (sampling available)")
  else
    vim.health.info("AI assist features inactive (no sampling-capable client)")
  end

  -- ACP agent
  local cfg = plugin.config or {}
  if cfg.acp and cfg.acp.command then
    local cmd = cfg.acp.command
    if vim.fn.executable(cmd) == 1 then
      vim.health.ok("ACP agent found: " .. cmd)
      local version = vim.fn.system({ cmd, "--version" }):gsub("\n", "")
      if vim.v.shell_error == 0 then
        vim.health.info("  " .. version)
      end
    else
      vim.health.error("ACP agent not found: " .. cmd, {
        "Install goose: https://github.com/block/goose",
        "Or set config.acp.command to your agent binary",
      })
    end
  else
    vim.health.info("ACP chat disabled (config.acp not set)")
  end

  -- Chat sessions
  local chat_sessions = require("agent-nvim.chat.sessions")
  local chat_list = chat_sessions.list()
  if #chat_list > 0 then
    vim.health.ok(#chat_list .. " chat session(s)")
    for _, c in ipairs(chat_list) do
      local state = c.session and c.session:state() or "?"
      vim.health.info("  Chat " .. c.id .. " [" .. state .. "]")
    end
  else
    vim.health.info("No chat sessions")
  end

  -- Neovim servername (needed for stdio bridge fallback)
  local servername = vim.v.servername
  if servername and servername ~= "" then
    vim.health.ok("Neovim RPC socket: " .. servername)
  else
    vim.health.info("No RPC servername (stdio bridge fallback unavailable)")
  end

  -- Lockfile
  local ok_lf, lockfile = pcall(require, "agent-nvim.lockfile")
  if ok_lf then
    local lf_path = lockfile.path()
    if lf_path and vim.fn.filereadable(lf_path) == 1 then
      vim.health.info("Lockfile: " .. lf_path)
    end
  end
end

return M
