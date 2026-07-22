--- Backend selection for AI assist commands.
---
--- Two paths produce the same result (a string of generated text given a
--- system prompt):
---
---   1. MCP sampling — the original path. Requires a connected MCP client
---      that advertises sampling (Claude Code, Kiro). Sends a
---      sampling/createMessage request over the existing SSE stream.
---
---   2. ACP one-shot — when goose-acp is the configured agent. Spawns
---      `goose acp`, runs `initialize` + `session/new` + a single
---      `session/prompt`, accumulates streamed agent_message_chunks, and
---      stops. Higher startup cost (1-3s) but doesn't require a
---      sampling-capable MCP client.
---
--- Selection: prefer MCP sampling if a sampling-capable session exists.
--- Otherwise, fall back to ACP one-shot if config.acp is set. If neither is
--- available, the callback fires with an error.

local M = {}

--- Returns "sampling" | "acp" | nil.
function M.resolve()
  local protocol_ok, protocol = pcall(require, "mcp-nvim.mcp.protocol")
  if protocol_ok then
    local sessions_ok, mcp_sessions = pcall(require, "mcp-nvim.sessions")
    if sessions_ok and #mcp_sessions.list() > 0 and protocol.client_supports("sampling") then
      return "sampling"
    end
  end
  local cfg = require("mcp-nvim").config or {}
  if cfg.acp and cfg.acp.command and cfg.acp.command ~= "" then
    return "acp"
  end
  return nil
end

local function via_sampling(system_prompt, user_text, callback)
  local sessions = require("mcp-nvim.sessions")
  local sampling = require("mcp-nvim.mcp.sampling")
  local list = sessions.list()
  if #list == 0 then
    callback(nil, "no sampling session")
    return
  end
  local session_id = list[1].id
  local cfg = require("mcp-nvim").config or {}
  local max_tokens = cfg.assist_max_tokens or 4096
  sampling.create_message({
    messages = { { role = "user", content = { type = "text", text = user_text } } },
    systemPrompt = system_prompt,
    maxTokens = max_tokens,
  }, function(result, err)
    vim.schedule(function()
      if err then
        callback(nil, vim.inspect(err))
        return
      end
      local text = result and result.content and result.content.text or ""
      callback(text, nil)
    end)
  end, session_id)
end

local ACP_TIMEOUT_MS = 30000

local function via_acp(system_prompt, user_text, callback)
  local AcpSession = require("mcp-nvim.acp.session")
  local plugin = require("mcp-nvim")
  local cfg = plugin.config or {}
  local accumulated = {}
  local finished = false

  local sess
  sess = AcpSession.new({
    spawn = {
      command = cfg.acp.command,
      args = cfg.acp.args or { "acp" },
      env = cfg.acp.env or {},
    },
    cwd = vim.fn.getcwd(),
    plugin_dir = plugin.plugin_dir(),
    -- Skip the bridge for one-shot assist: the agent has its own builtin
    -- developer/editor extensions, and avoiding the bridge cuts startup.
    include_bridge = false,
    spawn_id = "assist-oneshot",
    client_info = { name = "mcp-nvim-assist", version = plugin.version },
    on_update = function(params)
      local update = params and params.update or {}
      if update.sessionUpdate == "agent_message_chunk" then
        local text = update.content and update.content.text or ""
        table.insert(accumulated, text)
      end
    end,
  })

  local function finish(err)
    if finished then
      return
    end
    finished = true
    pcall(function()
      sess:stop()
    end)
    if err then
      callback(nil, err.message or vim.inspect(err))
    else
      local out = table.concat(accumulated, "")
      out = out:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
      callback(out, nil)
    end
  end

  -- Hard timeout: a stuck or hung agent must not leave the user with
  -- spinning virt-text forever.
  vim.defer_fn(function()
    if not finished then
      finish({ message = "ACP assist timed out after " .. (ACP_TIMEOUT_MS / 1000) .. "s" })
    end
  end, ACP_TIMEOUT_MS)

  sess:start(function(err)
    if err then
      finish(err)
      return
    end
    sess:create(function(create_err)
      if create_err then
        finish(create_err)
        return
      end
      sess:prompt({
        { type = "text", text = "System: " .. system_prompt .. "\n\n" .. user_text },
      }, function(prompt_err)
        finish(prompt_err)
      end)
    end)
  end)
end

--- Generic entrypoint used by the assist module.
--- system_prompt: rendered template
--- user_text: short user-facing instruction (e.g. "Perform the task...")
--- callback(text, err)
function M.send(system_prompt, user_text, callback)
  local backend = M.resolve()
  if backend == "sampling" then
    via_sampling(system_prompt, user_text, callback)
  elseif backend == "acp" then
    via_acp(system_prompt, user_text, callback)
  else
    callback(nil, "no backend available (no sampling client connected and config.acp not set)")
  end
end

return M
