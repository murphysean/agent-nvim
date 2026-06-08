local M = {}

M.config = {
  host = "127.0.0.1",
  port = 3000,
  auto_start = true,
  allow_code_execution = true,
  review_edits = true,
  log_level = "info",
}

function M.setup(opts)
  if M._initialized then
    return
  end
  M._initialized = true

  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("McpStart", function()
    M.start()
  end, { desc = "Start the MCP server" })

  vim.api.nvim_create_user_command("McpStop", function()
    M.stop()
  end, { desc = "Stop the MCP server" })

  vim.api.nvim_create_user_command("McpStatus", function()
    local server = require("mcp-nvim.server")
    if server.is_running() then
      local sess = require("mcp-nvim.sessions")
      vim.notify(
        string.format(
          "MCP server running on http://%s:%d (%d active sessions)",
          M.config.host,
          M.config.port,
          sess.count()
        ),
        vim.log.levels.INFO
      )
    else
      vim.notify("MCP server is not running", vim.log.levels.WARN)
    end
  end, { desc = "Show MCP server status" })

  vim.api.nvim_create_user_command("McpSample", function(cmd_opts)
    local sampling = require("mcp-nvim.mcp.sampling")
    local prompt = cmd_opts.args ~= "" and cmd_opts.args or "Hello from Neovim!"
    sampling.create_message({
      messages = {
        { role = "user", content = { type = "text", text = prompt } },
      },
      maxTokens = 256,
    }, function(result, err)
      vim.schedule(function()
        if err then
          vim.notify("Sampling error: " .. vim.inspect(err), vim.log.levels.ERROR)
        elseif result then
          local text = result.content and result.content.text or vim.inspect(result)
          vim.notify("Sampling response: " .. text, vim.log.levels.INFO)
        end
      end)
    end)
    vim.notify("Sampling request sent (waiting for client response...)", vim.log.levels.INFO)
  end, { desc = "Send a sampling/createMessage request to the MCP client", nargs = "?" })

  vim.api.nvim_create_user_command("McpAutoComplete", function(cmd_opts)
    local hint = cmd_opts.args ~= "" and cmd_opts.args or nil
    local visual = cmd_opts.range > 0
    require("mcp-nvim.autocomplete").complete(hint, visual)
  end, { desc = "AI-powered code completion at cursor via sampling", nargs = "?", range = true })

  vim.keymap.set("n", "<leader>ac", function()
    require("mcp-nvim.autocomplete").complete()
  end, { desc = "AI code completion" })
  vim.keymap.set("v", "<leader>ac", function()
    vim.cmd("'<,'>McpAutoComplete")
  end, { desc = "AI code completion (replace selection)" })

  if M.config.auto_start then
    vim.defer_fn(function()
      M.start()
    end, 100)
  end

  -- Dynamically register with blink.cmp if available (no user config needed)
  vim.defer_fn(function()
    local completion = require("mcp-nvim.completion")
    completion.register()
  end, 200)
end

function M.start()
  local server = require("mcp-nvim.server")
  server.start(M.config.host, M.config.port)
end

function M.stop()
  local server = require("mcp-nvim.server")
  server.stop()
end

return M
