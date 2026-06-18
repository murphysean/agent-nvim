--- ACP session: glue between the raw JSON-RPC connection and the editor's
--- chat UI. Wraps initialize + session/new + session/prompt; routes
--- session/update notifications to subscribers; answers fs/* and
--- session/request_permission via pluggable handlers.
---
--- One Session instance corresponds to one ACP `sessionId` (one chat tab).
--- Multiple Sessions can share a single Connection, but for now we use one
--- Connection per Session to keep cancellation and lifecycle simple — the
--- Chat layer can promote to shared connections later if perf demands it.

local Connection = require("mcp-nvim.acp.connection").Connection
local bridge = require("mcp-nvim.bridge")

local M = {}

local PROTOCOL_VERSION = 1

local Session = {}
Session.__index = Session

--- opts:
---   spawn         { command, args, env }    — how to launch the agent (server-side)
---   cwd           string                    — working directory for the session
---   include_bridge boolean (default true)   — pass mcp-nvim stdio bridge in mcpServers
---   plugin_dir    string                    — path to plugin root (for bin/...)
---   client_info   { name, version }         — sent in initialize.clientInfo
---   on_update     fn(update_obj)            — session/update notification stream
---   on_status     fn(state, info)           — connecting | ready | error | exited
---   on_permission fn(params, respond)       — session/request_permission handler
function M.new(opts)
  assert(opts and opts.spawn and opts.spawn.command, "Session.new: spawn.command required")
  assert(opts.plugin_dir, "Session.new: plugin_dir required (for bridge script path)")
  return setmetatable({
    _opts = opts,
    _conn = nil,
    _session_id = nil,
    _bridge_token = nil,
    _agent_capabilities = nil,
    _state = "idle", -- idle | connecting | initialized | ready | exited | error
    _current_turn = nil, -- per-turn data while a session/prompt is in flight
  }, Session)
end

function Session:_set_state(state, info)
  self._state = state
  if self._opts.on_status then
    pcall(self._opts.on_status, state, info)
  end
end

function Session:_build_mcp_servers()
  local servers = {}
  if self._opts.include_bridge ~= false then
    local servername = vim.v.servername
    if not servername or servername == "" then
      -- Without a servername the bridge can't proxy back — skip.
      if self._opts.on_status then
        pcall(
          self._opts.on_status,
          "warning",
          "v:servername is empty; mcp-nvim bridge skipped (start nvim with --listen)"
        )
      end
    else
      local token = bridge.mint(self._opts.spawn_id or "acp-session")
      self._bridge_token = token
      local script = self._opts.plugin_dir .. "/bin/mcp-stdio-bridge.lua"
      table.insert(servers, {
        name = "mcp-nvim",
        command = vim.v.progpath,
        args = { "--headless", "-l", script },
        env = {
          { name = "MCP_NVIM_TARGET", value = servername },
          { name = "MCP_NVIM_AUTH", value = token },
        },
      })
    end
  end
  for _, extra in ipairs(self._opts.extra_mcp_servers or {}) do
    table.insert(servers, extra)
  end
  return servers
end

local function dispatch_inbound_request(self, method, params, respond)
  if method == "fs/read_text_file" then
    require("mcp-nvim.acp.fs").read_text_file(params, respond)
    return
  end
  if method == "fs/write_text_file" then
    require("mcp-nvim.acp.fs").write_text_file(params, respond)
    return
  end
  if method == "session/request_permission" then
    if self._opts.on_permission then
      self._opts.on_permission(params, respond)
    else
      -- Default: reject. Safer than auto-allowing destructive ops.
      respond({ outcome = { outcome = "selected", optionId = "reject-once" } })
    end
    return
  end
  -- Unknown method: respond with method-not-found.
  respond({ code = -32601, message = "Method not found: " .. method }, true)
end

local function dispatch_notification(self, method, params)
  if method == "session/update" then
    if self._opts.on_update then
      pcall(self._opts.on_update, params)
    end
    return
  end
  -- Other notifications are silently ignored per ACP guidance.
end

--- Spawn the agent and run initialize. Calls cb(err) on completion.
function Session:start(cb)
  if self._conn then
    if cb then
      cb({ code = -32000, message = "session already started" })
    end
    return
  end
  self:_set_state("connecting")

  self._conn = Connection.new({
    command = self._opts.spawn.command,
    args = self._opts.spawn.args or {},
    env = self._opts.spawn.env or {},
    cwd = self._opts.cwd,
    on_notification = function(method, params)
      dispatch_notification(self, method, params)
    end,
    on_request = function(method, params, respond)
      dispatch_inbound_request(self, method, params, respond)
    end,
    on_exit = function(code, signal)
      if self._bridge_token then
        bridge.revoke(self._bridge_token)
        self._bridge_token = nil
      end
      self:_set_state("exited", { code = code, signal = signal })
      -- Fail an in-flight turn.
      if self._current_turn and self._current_turn.cb then
        local turn_cb = self._current_turn.cb
        self._current_turn = nil
        turn_cb(nil, { code = -32099, message = "agent exited mid-turn" })
      end
    end,
    on_stderr = self._opts.on_stderr,
  })

  if not self._conn:start() then
    self:_set_state("error", "spawn failed")
    if cb then
      cb({ code = -32099, message = "spawn failed" })
    end
    return
  end

  -- initialize
  self._conn:request("initialize", {
    protocolVersion = PROTOCOL_VERSION,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
      terminal = false,
    },
    clientInfo = self._opts.client_info or { name = "mcp-nvim", version = "1.0.0" },
  }, function(result, err)
    if err then
      self:_set_state("error", err)
      if cb then
        cb(err)
      end
      return
    end
    self._agent_capabilities = result and result.agentCapabilities or {}
    self:_set_state("initialized", result)
    if cb then
      cb(nil, result)
    end
  end)
end

--- Create the ACP session (after start). Calls cb(err, session_id).
function Session:create(cb)
  if not self._conn or not self._conn:is_alive() then
    if cb then
      cb({ code = -32000, message = "not started" })
    end
    return
  end
  if self._session_id then
    if cb then
      cb(nil, self._session_id)
    end
    return
  end
  self._conn:request("session/new", {
    cwd = self._opts.cwd,
    mcpServers = self:_build_mcp_servers(),
  }, function(result, err)
    if err then
      self:_set_state("error", err)
      if cb then
        cb(err)
      end
      return
    end
    self._session_id = result and result.sessionId
    self:_set_state("ready", { sessionId = self._session_id })
    if cb then
      cb(nil, self._session_id)
    end
  end)
end

--- Send a user prompt. content_blocks: array of { type="text", text=... } or
--- richer ACP ContentBlocks. cb(err, stop_reason) fires on turn end.
function Session:prompt(content_blocks, cb)
  if not self._session_id then
    if cb then
      cb({ code = -32000, message = "session not created" })
    end
    return
  end
  if self._current_turn then
    if cb then
      cb({ code = -32000, message = "turn already in flight" })
    end
    return
  end
  self._current_turn = { cb = cb }
  self._conn:request("session/prompt", {
    sessionId = self._session_id,
    prompt = content_blocks,
  }, function(result, err)
    self._current_turn = nil
    if err then
      if cb then
        cb(err)
      end
      return
    end
    if cb then
      cb(nil, result and result.stopReason)
    end
  end)
end

--- Cancel the in-flight turn. Per ACP, this is a notification; the agent
--- replies to the outstanding session/prompt with stop_reason=cancelled.
function Session:cancel()
  if not self._session_id or not self._conn then
    return
  end
  self._conn:notify("session/cancel", { sessionId = self._session_id })
end

function Session:state()
  return self._state
end

function Session:session_id()
  return self._session_id
end

function Session:agent_capabilities()
  return self._agent_capabilities
end

--- Tear down the session and the underlying process.
--- opts.sync — passed through to Connection:stop (see comment there).
function Session:stop(opts)
  if self._bridge_token then
    bridge.revoke(self._bridge_token)
    self._bridge_token = nil
  end
  if self._conn then
    self._conn:stop(opts)
  end
end

M.Session = Session

return M
