local M = {}
M.version = "1.1.0"

M.config = {
  host = "127.0.0.1",
  -- Default 0: kernel picks a free port, lockfile records it. Each running
  -- nvim gets its own endpoint, so multiple instances don't collide.
  -- Set to a fixed port (e.g. 3000) for legacy single-instance setups.
  port = 0,
  auto_start = true,
  allow_code_execution = true,
  review_edits = true,
  log_level = "info",
  -- ACP chat: spawn config for the agent. Set to nil to disable.
  acp = {
    command = "goose",
    args = { "acp", "--with-builtin", "developer,editor" },
    env = {},
  },
  chat_height = 15,
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
    local server = require("agent-nvim.server")
    if server.is_running() then
      local sess = require("agent-nvim.sessions")
      vim.notify(
        string.format("MCP v%s server running on %s (%d active sessions)", M.version, server.url(), sess.count()),
        vim.log.levels.INFO
      )
    else
      vim.notify("MCP server is not running", vim.log.levels.WARN)
    end
  end, { desc = "Show MCP server status" })

  vim.api.nvim_create_user_command("McpUrl", function(cmd_opts)
    local server = require("agent-nvim.server")
    local url = server.url()
    if not url then
      vim.notify("MCP server is not running", vim.log.levels.WARN)
      return
    end
    if cmd_opts.bang then
      vim.fn.setreg("+", url)
      vim.notify("MCP URL copied to clipboard: " .. url, vim.log.levels.INFO)
    else
      vim.notify(url, vim.log.levels.INFO)
    end
  end, { desc = "Print the MCP server URL (use :McpUrl! to copy to clipboard)", bang = true })

  vim.api.nvim_create_user_command("McpSample", function(cmd_opts)
    local sampling = require("agent-nvim.mcp.sampling")
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
    require("agent-nvim.autocomplete").complete(hint, visual)
  end, { desc = "AI-powered code completion at cursor via sampling", nargs = "?", range = true })

  -- ACP chat commands.
  vim.api.nvim_create_user_command("McpChat", function()
    require("agent-nvim.chat").open()
  end, { desc = "Open the mcp-chat window (creates a session if none exist)" })

  vim.api.nvim_create_user_command("McpChatToggle", function()
    require("agent-nvim.chat").toggle()
  end, { desc = "Toggle the mcp-chat window (keeps session alive when hidden)" })

  vim.api.nvim_create_user_command("McpChatNew", function()
    require("agent-nvim.chat").new()
  end, { desc = "Start a new mcp-chat session in a new buffer/process" })

  vim.api.nvim_create_user_command("McpChatNext", function()
    require("agent-nvim.chat").next()
  end, { desc = "Switch to the next mcp-chat session" })

  vim.api.nvim_create_user_command("McpChatPrev", function()
    require("agent-nvim.chat").prev()
  end, { desc = "Switch to the previous mcp-chat session" })

  vim.api.nvim_create_user_command("McpChatSwitch", function(cmd_opts)
    require("agent-nvim.chat").switch(cmd_opts.args)
  end, { desc = "Switch to a specific mcp-chat session by id", nargs = 1 })

  vim.api.nvim_create_user_command("McpChatList", function()
    vim.notify(require("agent-nvim.chat").list(), vim.log.levels.INFO)
  end, { desc = "List active mcp-chat sessions" })

  vim.api.nvim_create_user_command("McpChatCancel", function()
    require("agent-nvim.chat").cancel()
  end, { desc = "Cancel the in-flight turn of the active mcp-chat session" })

  vim.api.nvim_create_user_command("McpChatClose", function()
    require("agent-nvim.chat").close()
  end, { desc = "Close the active mcp-chat session and terminate its agent process" })

  vim.keymap.set("n", "<leader>aa", function()
    require("agent-nvim.chat").open()
  end, { desc = "Open mcp-chat" })
  vim.keymap.set("n", "<leader>at", function()
    require("agent-nvim.chat").toggle()
  end, { desc = "Toggle mcp-chat" })

  -- Spawn `goose acp` and run a single end-to-end turn:
  -- initialize -> session/new -> session/prompt -> dump streamed updates.
  -- Verification only; the real chat UI lives in agent-nvim.chat.
  vim.api.nvim_create_user_command("McpAcpTest", function(cmd_opts)
    local AcpSession = require("agent-nvim.acp.session")
    local prompt = cmd_opts.args ~= "" and cmd_opts.args or "Say hello in one short sentence."
    local sess = AcpSession.new({
      spawn = {
        command = "goose",
        args = { "acp", "--with-builtin", "developer,editor" },
      },
      cwd = vim.fn.getcwd(),
      plugin_dir = M.plugin_dir(),
      include_bridge = true,
      client_info = { name = "agent-nvim", version = M.version },
      on_status = function(state, info)
        vim.notify(string.format("[acp] %s: %s", state, vim.inspect(info)), vim.log.levels.INFO)
      end,
      on_update = function(params)
        local update = params and params.update or {}
        local kind = update.sessionUpdate or "?"
        if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
          local text = update.content and update.content.text or ""
          vim.notify(string.format("[acp:%s] %s", kind, text), vim.log.levels.INFO)
        else
          vim.notify(string.format("[acp:%s] %s", kind, vim.inspect(update)), vim.log.levels.INFO)
        end
      end,
      on_stderr = function(line)
        vim.notify("[acp:stderr] " .. line, vim.log.levels.DEBUG)
      end,
    })
    sess:start(function(err)
      if err then
        sess:stop()
        return
      end
      sess:create(function(create_err)
        if create_err then
          sess:stop()
          return
        end
        sess:prompt({ { type = "text", text = prompt } }, function(prompt_err, stop_reason)
          vim.notify(
            string.format(
              "[acp] turn done: stop_reason=%s err=%s",
              tostring(stop_reason),
              tostring(prompt_err and prompt_err.message)
            ),
            vim.log.levels.INFO
          )
          vim.defer_fn(function()
            sess:stop()
          end, 200)
        end)
      end)
    end)
  end, { desc = "Spawn goose acp and run one turn end-to-end (verification)", nargs = "?" })

  -- Spawn the stdio bridge as a child process and run a single initialize
  -- round-trip. Useful for verifying the bridge wire-up without involving
  -- a real ACP agent.
  vim.api.nvim_create_user_command("McpBridgeTest", function()
    local bridge = require("agent-nvim.bridge")
    local plugin_dir = M.plugin_dir()
    local script = plugin_dir .. "/bin/agent-stdio-bridge.lua"
    local servername = vim.v.servername
    if not servername or servername == "" then
      vim.notify(
        "McpBridgeTest: nvim has no RPC servername (start with --listen or in a regular UI)",
        vim.log.levels.ERROR
      )
      return
    end
    local token = bridge.mint("test-spawn")
    local cmd = { vim.v.progpath, "--headless", "-l", script }
    local stdout_buf, stderr_buf = "", ""
    local job = vim.system(cmd, {
      env = {
        AGENT_NVIM_TARGET = servername,
        AGENT_NVIM_AUTH = token,
        PATH = vim.env.PATH,
        HOME = vim.env.HOME,
      },
      stdin = true,
      stdout = function(_, data)
        if data then
          stdout_buf = stdout_buf .. data
        end
      end,
      stderr = function(_, data)
        if data then
          stderr_buf = stderr_buf .. data
        end
      end,
    }, function(result)
      vim.schedule(function()
        bridge.revoke(token)
        vim.notify(
          string.format(
            "McpBridgeTest done (exit=%d)\nstdout:\n%s\nstderr:\n%s",
            result.code or -1,
            stdout_buf,
            stderr_buf
          ),
          vim.log.levels.INFO
        )
      end)
    end)
    -- Send an initialize frame, then close stdin so the bridge exits.
    local frame = require("agent-nvim.json").encode({
      jsonrpc = "2.0",
      id = 1,
      method = "initialize",
      params = {
        protocolVersion = "2025-03-26",
        capabilities = {},
        clientInfo = { name = "mcp-bridge-test", version = "1" },
      },
    }) .. "\n"
    job:write(frame)
    job:write(nil) -- close stdin
  end, { desc = "Spawn the stdio MCP bridge and run an initialize round-trip" })

  -- Clean up lockfile and stop server on nvim exit. Without this, a kill -9
  -- or unclean shutdown leaves the lockfile behind; gc_stale on next startup
  -- handles that, but graceful shutdown should clean up immediately.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("agent_nvim_shutdown", { clear = true }),
    callback = function()
      pcall(function()
        require("agent-nvim.chat").shutdown()
      end)
      pcall(M.stop)
    end,
  })

  if M.config.auto_start then
    vim.defer_fn(function()
      M.start()
    end, 100)
  end

  -- Sampling-dependent features (keymaps, completion) are managed by the lifecycle module.
  -- They register when a capable client connects, deregister when it disconnects.
  -- We kick a check after a short delay to handle clients that connect immediately.
  vim.defer_fn(function()
    local lifecycle = require("agent-nvim.sampling_lifecycle")
    lifecycle.on_session_ready()
  end, 500)
end

function M.start()
  local server = require("agent-nvim.server")
  server.start(M.config.host, M.config.port)
end

function M.stop()
  local server = require("agent-nvim.server")
  server.stop()
end

--- Returns the plugin's root directory (parent of lua/).
--- Used to locate bin/agent-stdio-bridge.lua and prompts/templates.
function M.plugin_dir()
  -- debug.getinfo gives us the path of this file: <root>/lua/agent-nvim/init.lua
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  -- Walk up: init.lua -> agent-nvim -> lua -> <plugin-root>
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

return M
