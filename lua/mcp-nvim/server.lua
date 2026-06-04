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

    local session = sessions.create(conn)
    conn:start_sse(merge_headers(cors, {
      ["Mcp-Session-Id"] = session.id,
    }))
    return
  end

  -- DELETE /mcp — terminate session
  if request.method == "DELETE" then
    local session_id = request.headers["mcp-session-id"]
    if session_id then
      sessions.remove(session_id)
    end
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

  local response_body = protocol.handle_jsonrpc(request.body, registry, session_id)

  -- Notifications return nil — no response needed
  if not response_body then
    conn:respond(202, cors, "")
    return
  end

  -- Always respond with plain JSON for RPC calls.
  -- SSE is only used for the GET notification stream.
  local headers = merge_headers(cors, {
    ["Content-Type"] = "application/json",
  })

  if not session_id then
    local bytes = vim.loop.random(16) or string.rep("\0", 16)
    session_id = bytes:gsub(".", function(c)
      return string.format("%02x", c:byte())
    end)
  end
  headers["Mcp-Session-Id"] = session_id
  conn:respond(200, headers, response_body)
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
