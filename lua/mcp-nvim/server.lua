local http = require("mcp-nvim.http")
local json = require("mcp-nvim.json")
local protocol = require("mcp-nvim.mcp.protocol")
local registry = require("mcp-nvim.mcp.registry")
local sessions = require("mcp-nvim.sessions")
local events = require("mcp-nvim.events")

local M = {}

local server_handle = nil

local function get_cors_headers(request)
  local origin = request and request.headers and request.headers["origin"] or ""
  local allowed = origin == ""
    or origin:find("^https?://localhost[:/]") ~= nil
    or origin:find("^https?://127%.0%.0%.1[:/]") ~= nil

  return {
    ["Access-Control-Allow-Origin"] = allowed and (origin ~= "" and origin or "http://localhost") or "http://localhost",
    ["Access-Control-Allow-Methods"] = "POST, GET, DELETE, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type, Mcp-Session-Id",
    ["Access-Control-Expose-Headers"] = "Mcp-Session-Id",
    ["Vary"] = "Origin",
  }
end

local function merge_headers(base, extra)
  local merged = {}
  for k, v in pairs(base) do
    merged[k] = v
  end
  for k, v in pairs(extra or {}) do
    merged[k] = v
  end
  return merged
end

local function handle_request(request, conn)
  local cors = get_cors_headers(request)

  if request.method == "OPTIONS" then
    conn:respond(204, cors, "")
    return
  end

  if request.path ~= "/mcp" then
    conn:respond(
      404,
      merge_headers(cors, {
        ["Content-Type"] = "application/json",
      }),
      json.encode({ error = "Not found" })
    )
    return
  end

  -- GET /mcp — open an SSE stream for server-initiated notifications
  if request.method == "GET" then
    local accept = request.headers["accept"] or ""
    if not accept:find("text/event%-stream") then
      conn:respond(
        405,
        merge_headers(cors, {
          ["Content-Type"] = "application/json",
        }),
        json.encode({ error = "GET requires Accept: text/event-stream" })
      )
      return
    end

    local session_id = request.headers["mcp-session-id"]
    local session

    if session_id then
      -- Client claims an existing session — validate it.
      session = sessions.get(session_id)
      if not session then
        conn:respond(
          404,
          merge_headers(cors, { ["Content-Type"] = "application/json" }),
          json.encode({ error = "Session not found — please re-initialize" })
        )
        return
      end
      -- Attach (or re-attach) the SSE connection to the existing session.
      sessions.attach_connection(session_id, conn)
    else
      -- No session header — create a fresh session with the SSE connection.
      -- This supports clients that open SSE before or without POST initialize.
      session = sessions.create(conn)
    end

    conn:start_sse(merge_headers(cors, {
      ["Mcp-Session-Id"] = session.id,
    }))
    return
  end

  -- DELETE /mcp — terminate session
  if request.method == "DELETE" then
    local session_id = request.headers["mcp-session-id"]
    if not session_id or not sessions.get(session_id) then
      conn:respond(
        404,
        merge_headers(cors, { ["Content-Type"] = "application/json" }),
        json.encode({ error = "Session not found" })
      )
      return
    end
    sessions.remove(session_id)
    conn:respond(
      200,
      merge_headers(cors, {
        ["Content-Type"] = "application/json",
      }),
      json.encode({ message = "Session terminated" })
    )
    return
  end

  if request.method ~= "POST" then
    conn:respond(
      405,
      merge_headers(cors, {
        ["Content-Type"] = "application/json",
      }),
      json.encode({ error = "Method not allowed" })
    )
    return
  end

  -- POST /mcp — JSON-RPC request
  local session_id = request.headers["mcp-session-id"]

  if session_id then
    -- Client claims an existing session — validate it.
    if not sessions.get(session_id) then
      conn:respond(
        404,
        merge_headers(cors, { ["Content-Type"] = "application/json" }),
        json.encode({ error = "Session not found — please re-initialize" })
      )
      return
    end
  else
    -- First request (initialize) — generate the session ID and register it.
    -- The SSE connection will be attached later via GET.
    local bytes = vim.loop.random(16) or string.rep("\0", 16)
    session_id = bytes:gsub(".", function(c)
      return string.format("%02x", c:byte())
    end)
    sessions.create(nil, session_id)
  end

  local function send_response(response_body)
    if not conn:is_alive() then
      return
    end
    local headers = merge_headers(cors, {
      ["Content-Type"] = "application/json",
      ["Mcp-Session-Id"] = session_id,
    })
    conn:respond(200, headers, response_body)
  end

  local response_body = protocol.handle_jsonrpc(request.body, registry, session_id, send_response)

  if response_body == "async" then
    return
  end

  if not response_body then
    conn:respond(202, cors, "")
    return
  end

  send_response(response_body)
end

function M.start(host, port)
  if server_handle then
    vim.notify("MCP server already running", vim.log.levels.WARN)
    return
  end

  require("mcp-nvim.tools").register_all()
  require("mcp-nvim.resources").register_all()
  require("mcp-nvim.prompts").register_all()

  local completion = require("mcp-nvim.mcp.completion")
  completion.reset()
  completion.register_defaults()

  events.setup()
  sessions.start_ping()

  server_handle = http.create_server(host, port, handle_request)
  vim.notify(string.format("MCP server started on http://%s:%d/mcp", host, port), vim.log.levels.INFO)
end

function M.stop()
  if server_handle then
    events.teardown()
    sessions.shutdown()
    sessions.reset()
    server_handle:close()
    server_handle = nil
    vim.notify("MCP server stopped", vim.log.levels.INFO)
  end
end

function M.is_running()
  return server_handle ~= nil
end

return M
