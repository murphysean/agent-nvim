local json = require("mcp-nvim.json")

local M = {}

local sessions = {}
local next_id = 1
local ping_timer = nil
local PING_INTERVAL = 60000 -- 60 seconds

--- Create a new session for a connected client.
--- If `id` is provided, use it as the session key (e.g., from Mcp-Session-Id header).
--- Returns a session object with id and subscription tracking.
function M.create(connection, id)
  if not id then
    id = string.format("%08x", next_id)
    next_id = next_id + 1
  end

  local session = {
    id = id,
    connection = connection,
    subscriptions = {}, -- uri -> true
    client_session_id = nil, -- Goose's agent-session-id
  }

  sessions[id] = session
  return session
end

--- Attach (or replace) the SSE connection for an existing session.
--- Used when the client opens the SSE stream after initialize.
function M.attach_connection(id, connection)
  local session = sessions[id]
  if session then
    session.connection = connection
    return true
  end
  return false
end

function M.get(id)
  return sessions[id]
end

--- Set the Goose agent-session-id for an MCP session (extracted from _meta).
function M.set_client_session_id(id, client_session_id)
  local session = sessions[id]
  if session then
    session.client_session_id = client_session_id
  end
end

--- Get the Goose agent-session-id for an MCP session.
function M.get_client_session_id(id)
  local session = sessions[id]
  if session then
    return session.client_session_id
  end
  return nil
end

function M.remove(id)
  sessions[id] = nil

  -- Notify lifecycle that a session was lost
  vim.schedule(function()
    local lifecycle = require("mcp-nvim.sampling_lifecycle")
    lifecycle.on_session_lost()
  end)
end

--- Subscribe a session to a resource URI.
function M.subscribe(session_id, uri)
  local session = sessions[session_id]
  if session then
    session.subscriptions[uri] = true
  end
end

--- Unsubscribe a session from a resource URI.
function M.unsubscribe(session_id, uri)
  local session = sessions[session_id]
  if session then
    session.subscriptions[uri] = nil
  end
end

--- Helper: check if a session has a live SSE connection.
local function is_connected(session)
  return session.connection ~= nil and session.connection:is_alive()
end

--- Notify all sessions subscribed to a URI that the resource has changed.
function M.notify_resource_updated(uri)
  local notification = json.encode({
    jsonrpc = "2.0",
    method = "notifications/resources/updated",
    params = { uri = uri },
  })

  local dead = {}
  for id, session in pairs(sessions) do
    if is_connected(session) then
      session.connection:send_sse_event("message", notification)
    elseif session.connection then
      table.insert(dead, id)
    end
  end

  for _, id in ipairs(dead) do
    sessions[id] = nil
  end
end

--- Notify all sessions that the resource list has changed.
function M.notify_list_changed()
  local notification = json.encode({
    jsonrpc = "2.0",
    method = "notifications/resources/list_changed",
  })

  local dead = {}
  for id, session in pairs(sessions) do
    if is_connected(session) then
      session.connection:send_sse_event("message", notification)
    elseif session.connection then
      table.insert(dead, id)
    end
  end

  for _, id in ipairs(dead) do
    sessions[id] = nil
  end
end

--- Send a JSON-RPC notification to a specific session.
function M.send_notification(session_id, method, params)
  local session = sessions[session_id]
  if not session or not is_connected(session) then
    return false
  end

  local notification = json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params,
  })

  session.connection:send_sse_event("message", notification)
  return true
end

--- Broadcast a JSON-RPC notification to all active sessions.
function M.broadcast(method, params)
  local notification = json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params,
  })

  local dead = {}
  for id, session in pairs(sessions) do
    if is_connected(session) then
      session.connection:send_sse_event("message", notification)
    elseif session.connection then
      table.insert(dead, id)
    end
  end

  for _, id in ipairs(dead) do
    sessions[id] = nil
  end
end

--- Send a raw SSE event to a specific session.
function M.send_to(session_id, event, data)
  local session = sessions[session_id]
  if not session or not is_connected(session) then
    return false
  end
  session.connection:send_sse_event(event, data)
  return true
end

--- Broadcast a raw SSE event to all active sessions.
function M.broadcast_raw(event, data)
  local dead = {}
  for id, session in pairs(sessions) do
    if is_connected(session) then
      session.connection:send_sse_event(event, data)
    elseif session.connection then
      table.insert(dead, id)
    end
  end
  for _, id in ipairs(dead) do
    sessions[id] = nil
  end
end

--- Get count of active sessions.
function M.count()
  local n = 0
  for _, session in pairs(sessions) do
    if is_connected(session) then
      n = n + 1
    end
  end
  return n
end

--- List all active sessions (for debugging/status).
function M.list()
  local result = {}
  for id, session in pairs(sessions) do
    if is_connected(session) then
      local subs = {}
      for uri in pairs(session.subscriptions) do
        table.insert(subs, uri)
      end
      table.insert(result, {
        id = id,
        subscriptions = subs,
      })
    end
  end
  return result
end

function M.shutdown()
  for _, session in pairs(sessions) do
    if is_connected(session) and session.connection.mode == "sse" then
      local notification = json.encode({
        jsonrpc = "2.0",
        method = "notifications/cancelled",
        params = { reason = "server shutting down" },
      })
      session.connection:send_sse_event("message", notification)
    end
  end
end

function M.start_ping()
  if ping_timer then
    return
  end
  ping_timer = vim.loop.new_timer()
  if not ping_timer then
    return
  end
  ping_timer:start(
    PING_INTERVAL,
    PING_INTERVAL,
    vim.schedule_wrap(function()
      local dead = {}
      for id, session in pairs(sessions) do
        if is_connected(session) then
          session.connection.socket:write(": ping\n\n", function(err)
            if err then
              session.connection:close()
            end
          end)
        elseif session.connection then
          table.insert(dead, id)
        end
      end
      for _, id in ipairs(dead) do
        sessions[id] = nil
      end
    end)
  )
end

function M.stop_ping()
  if ping_timer then
    ping_timer:stop()
    ping_timer:close()
    ping_timer = nil
  end
end

function M.reset()
  M.stop_ping()
  for _, session in pairs(sessions) do
    if session.connection and session.connection:is_alive() then
      session.connection:close()
    end
  end
  sessions = {}
  next_id = 1
end

return M
