local sessions = require("agent-nvim.sessions")
local json = require("agent-nvim.json")

local M = {}

local pending_requests = {}
local next_id = 1

--- Build the _meta extension for sampling requests, including the Goose
--- session ID so the client can resolve the correct provider session.
function M._build_meta(session_id)
  if not session_id then
    return nil
  end
  local client_sid = sessions.get_client_session_id(session_id)
  if client_sid then
    return { ["agent-session-id"] = client_sid }
  end
  return nil
end

function M.create_message(params, callback, session_id)
  local request = {
    jsonrpc = "2.0",
    id = "srv_" .. next_id,
    method = "sampling/createMessage",
    params = {
      _meta = M._build_meta(session_id),
      messages = params.messages or {},
      modelPreferences = params.modelPreferences,
      systemPrompt = params.systemPrompt,
      includeContext = params.includeContext or "none",
      temperature = params.temperature,
      maxTokens = params.maxTokens or 1024,
    },
  }
  next_id = next_id + 1

  pending_requests[request.id] = callback

  if session_id then
    sessions.send_to(session_id, "message", json.encode(request))
  else
    sessions.broadcast_raw("message", json.encode(request))
  end

  return request.id
end

function M.handle_response(msg)
  local id = msg.id
  if not id or not pending_requests[id] then
    return false
  end

  local callback = pending_requests[id]
  pending_requests[id] = nil

  if msg.error then
    callback(nil, msg.error)
  else
    callback(msg.result, nil)
  end

  return true
end

function M.is_pending(id)
  return pending_requests[id] ~= nil
end

function M.cancel(id)
  pending_requests[id] = nil
end

function M.reset()
  pending_requests = {}
  next_id = 1
end

return M
