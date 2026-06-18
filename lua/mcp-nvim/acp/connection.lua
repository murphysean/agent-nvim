--- ACP connection: spawn-and-wire-up an ACP agent (e.g. `goose acp`) and
--- expose a request/notification API.
---
--- The connection is bidirectional: both sides may send requests. We track
--- pending outbound requests by id, and dispatch inbound requests to a
--- handler table keyed by method name (`fs/read_text_file`,
--- `session/request_permission`, ...). Notifications (`session/update`,
--- `session/cancel`, ...) are delivered to a single on_notification callback.
---
--- Lifecycle:
---   conn = Connection.new({ command, args, env, on_notification, on_request,
---                            on_exit, on_stderr })
---   conn:start()                         -- spawn or attach
---   conn:request(method, params, cb)     -- async, cb(result, err)
---   conn:notify(method, params)
---   conn:respond(id, result_or_err)      -- reply to inbound request
---   conn:stop()                          -- graceful: close stdin, then SIGTERM, then SIGKILL

local jsonrpc = require("mcp-nvim.acp.jsonrpc")

local M = {}

local Connection = {}
Connection.__index = Connection

--- opts:
---   command (string)              required: executable path or name
---   args (table of strings)       optional, defaults to {}
---   env (table)                   optional, env vars to merge over inherited
---   cwd (string)                  optional, defaults to vim.fn.getcwd()
---   on_notification(method, params)   optional
---   on_request(method, params, respond)   optional, respond(result_or_err, is_error)
---   on_exit(code, signal)         optional
---   on_stderr(line)               optional
function M.new(opts)
  assert(opts and opts.command, "Connection.new: command required")
  return setmetatable({
    command = opts.command,
    args = opts.args or {},
    env = opts.env or {},
    cwd = opts.cwd or vim.fn.getcwd(),
    on_notification = opts.on_notification,
    on_request = opts.on_request,
    on_exit = opts.on_exit,
    on_stderr = opts.on_stderr,

    _job = nil,
    _stopped = false,
    _line_buffer = jsonrpc.new_line_buffer(),
    _stderr_buffer = "",
    _id_gen = jsonrpc.new_id_gen(),
    _pending = {}, -- id -> callback(result, err)
  }, Connection)
end

function Connection:_dispatch_frame(msg)
  -- Inbound responses (to our outbound requests).
  if msg.id ~= nil and msg.method == nil then
    local cb = self._pending[msg.id]
    if cb then
      self._pending[msg.id] = nil
      if msg.error then
        cb(nil, msg.error)
      else
        cb(msg.result, nil)
      end
    end
    return
  end

  -- Inbound notifications (no id).
  if msg.id == nil and msg.method ~= nil then
    if self.on_notification then
      pcall(self.on_notification, msg.method, msg.params or {})
    end
    return
  end

  -- Inbound requests: agent → editor (e.g., fs/read_text_file).
  if msg.id ~= nil and msg.method ~= nil then
    if not self.on_request then
      -- No handler registered: respond with method-not-found.
      self:_send_frame(jsonrpc.error(msg.id, -32601, "Method not found: " .. msg.method))
      return
    end
    local responded = false
    local function respond(result_or_err, is_error)
      if responded then
        return
      end
      responded = true
      if is_error then
        local err = result_or_err
        if type(err) == "string" then
          err = { code = -32000, message = err }
        end
        self:_send_frame(jsonrpc.error(msg.id, err.code or -32000, err.message or "error", err.data))
      else
        self:_send_frame(jsonrpc.success(msg.id, result_or_err))
      end
    end
    local ok, handler_err = pcall(self.on_request, msg.method, msg.params or {}, respond)
    if not ok and not responded then
      respond({ code = -32603, message = "handler error: " .. tostring(handler_err) }, true)
    end
    return
  end
end

function Connection:_send_frame(msg)
  if self._stopped or not self._job then
    return false
  end
  local ok = pcall(function()
    self._job:write(jsonrpc.encode_frame(msg))
  end)
  return ok
end

function Connection:_handle_stdout(data)
  if not data then
    return
  end
  -- Surface parse errors as stderr so debug output of an agent that's emitting
  -- non-JSON banners is visible (instead of silently dropping the line).
  if not self._line_buffer.on_parse_error then
    local on_stderr = self.on_stderr
    self._line_buffer.on_parse_error = function(line, err)
      if on_stderr then
        vim.schedule(function()
          pcall(on_stderr, "[parse error] " .. tostring(err) .. ": " .. line)
        end)
      end
    end
  end
  local frames = self._line_buffer:feed(data)
  for _, msg in ipairs(frames) do
    -- Dispatch on the main thread to keep all editor calls on the API thread.
    vim.schedule(function()
      self:_dispatch_frame(msg)
    end)
  end
end

function Connection:_handle_stderr(data)
  if not data or not self.on_stderr then
    return
  end
  self._stderr_buffer = self._stderr_buffer .. data
  while true do
    local nl = self._stderr_buffer:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._stderr_buffer:sub(1, nl - 1):gsub("\r$", "")
    self._stderr_buffer = self._stderr_buffer:sub(nl + 1)
    if #line > 0 then
      vim.schedule(function()
        pcall(self.on_stderr, line)
      end)
    end
  end
end

--- Spawn the agent process. Returns true on success, false on spawn error.
function Connection:start()
  if self._job then
    return true
  end

  local cmd = { self.command }
  for _, a in ipairs(self.args) do
    table.insert(cmd, a)
  end

  -- Merge env over inherited (vim.system replaces by default; provide a
  -- merged table so the child still gets PATH etc.).
  local merged_env = {}
  for k, v in pairs(vim.fn.environ()) do
    merged_env[k] = v
  end
  for k, v in pairs(self.env) do
    merged_env[k] = v
  end

  local ok, job_or_err = pcall(vim.system, cmd, {
    cwd = self.cwd,
    env = merged_env,
    stdin = true,
    stdout = function(_, data)
      self:_handle_stdout(data)
    end,
    stderr = function(_, data)
      self:_handle_stderr(data)
    end,
    text = true,
  }, function(result)
    self._stopped = true
    -- Fail any pending requests so callers don't hang.
    local pending = self._pending
    self._pending = {}
    for _, cb in pairs(pending) do
      vim.schedule(function()
        cb(nil, { code = -32099, message = "agent process exited" })
      end)
    end
    if self.on_exit then
      vim.schedule(function()
        pcall(self.on_exit, result.code, result.signal)
      end)
    end
  end)

  if not ok then
    if self.on_exit then
      vim.schedule(function()
        pcall(self.on_exit, -1, "spawn failed: " .. tostring(job_or_err))
      end)
    end
    return false
  end

  self._job = job_or_err
  return true
end

--- Send a JSON-RPC request. callback(result, err) fires when the agent
--- responds (or with err if the connection dies / a remote error returns).
function Connection:request(method, params, callback)
  if self._stopped then
    if callback then
      vim.schedule(function()
        callback(nil, { code = -32099, message = "connection closed" })
      end)
    end
    return
  end
  local id = self._id_gen:alloc()
  if callback then
    self._pending[id] = callback
  end
  local sent = self:_send_frame(jsonrpc.request(id, method, params))
  if not sent and callback then
    self._pending[id] = nil
    vim.schedule(function()
      callback(nil, { code = -32099, message = "send failed" })
    end)
  end
end

--- Send a JSON-RPC notification.
function Connection:notify(method, params)
  if self._stopped then
    return
  end
  self:_send_frame(jsonrpc.notification(method, params))
end

--- Reply to an inbound request. Use this only outside on_request (for example
--- when you queued the request and answer later); inside on_request, prefer
--- the `respond` callback supplied to the handler.
function Connection:respond(id, result_or_err, is_error)
  if is_error then
    local err = result_or_err
    if type(err) == "string" then
      err = { code = -32000, message = err }
    end
    self:_send_frame(jsonrpc.error(id, err.code or -32000, err.message or "error", err.data))
  else
    self:_send_frame(jsonrpc.success(id, result_or_err))
  end
end

--- Graceful shutdown. Closes stdin so the agent sees EOF and exits cleanly,
--- then escalates to SIGTERM / SIGKILL if it doesn't.
---
--- opts.sync = true: skip the deferred-timer escalation and SIGTERM
--- immediately. Use this from VimLeavePre, where deferred timers never
--- fire because nvim exits before they tick.
function Connection:stop(opts)
  opts = opts or {}
  if not self._job or self._stopped then
    return
  end
  pcall(function()
    self._job:write(nil)
  end) -- close stdin

  if opts.sync then
    pcall(function()
      self._job:kill("sigterm")
    end)
    return
  end

  -- Give the agent a moment to clean up; then SIGTERM, then SIGKILL.
  local term_ms = opts.term_ms or 1500
  local kill_ms = opts.kill_ms or 500
  local job = self._job
  vim.defer_fn(function()
    if not self._stopped then
      pcall(function()
        job:kill("sigterm")
      end)
    end
  end, term_ms)
  vim.defer_fn(function()
    if not self._stopped then
      pcall(function()
        job:kill("sigkill")
      end)
    end
  end, term_ms + kill_ms)
end

function Connection:is_alive()
  return self._job ~= nil and not self._stopped
end

M.Connection = Connection

return M
