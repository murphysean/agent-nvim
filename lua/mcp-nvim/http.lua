local uv = vim.loop

local M = {}

local MAX_REQUEST_SIZE = 10 * 1024 * 1024 -- 10MB

local function parse_request(raw)
  local request_line, rest = raw:match("^(.-)\r\n(.*)$")
  if not request_line then
    return nil
  end

  local method, path, version = request_line:match("^(%u+)%s+(%S+)%s+(HTTP/%d%.%d)$")
  if not method then
    return nil
  end

  local headers = {}
  local header_section, body = rest:match("^(.-)\r\n\r\n(.*)$")
  if not header_section then
    header_section = rest
    body = ""
  end

  for line in header_section:gmatch("([^\r\n]+)") do
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key then
      headers[key:lower()] = value
    end
  end

  return {
    method = method,
    path = path,
    version = version,
    headers = headers,
    body = body,
  }
end

local function status_text(code)
  local texts = {
    [200] = "OK",
    [202] = "Accepted",
    [204] = "No Content",
    [400] = "Bad Request",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [413] = "Content Too Large",
    [500] = "Internal Server Error",
  }
  return texts[code] or "Unknown"
end

local function format_response_head(status, headers)
  local lines = { string.format("HTTP/1.1 %d %s", status, status_text(status)) }
  for key, value in pairs(headers) do
    table.insert(lines, string.format("%s: %s", key, value))
  end
  table.insert(lines, "")
  table.insert(lines, "")
  return table.concat(lines, "\r\n")
end

--- Connection object wrapping a TCP client socket.
--- Provides methods for different response modes.
local Connection = {}
Connection.__index = Connection

function Connection.new(socket)
  return setmetatable({
    socket = socket,
    alive = true,
    mode = nil, -- "closed" | "sse"
  }, Connection)
end

function Connection:respond(status, headers, body)
  if not self.alive then
    return
  end
  headers["Content-Length"] = tostring(#(body or ""))
  headers["Connection"] = "close"
  local head = format_response_head(status, headers)
  self.socket:write(head .. (body or ""), function()
    self:close()
  end)
  self.mode = "closed"
end

function Connection:start_sse(headers)
  if not self.alive then
    return
  end
  headers["Content-Type"] = "text/event-stream"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "keep-alive"
  local head = format_response_head(200, headers)
  self.socket:write(head)
  self.mode = "sse"
end

function Connection:send_sse_event(event, data)
  if not self.alive or self.mode ~= "sse" then
    return
  end
  local payload = ""
  if event then
    payload = payload .. "event: " .. event .. "\n"
  end
  payload = payload .. "data: " .. data .. "\n\n"
  self.socket:write(payload, function(err)
    if err then
      self:close()
    end
  end)
end

function Connection:close()
  if not self.alive then
    return
  end
  self.alive = false
  self.socket:shutdown(function()
    if not self.socket:is_closing() then
      self.socket:close()
    end
  end)
end

function Connection:is_alive()
  return self.alive
end

M.Connection = Connection

--- Create an HTTP server.
--- handler(request, connection) is called for each complete request.
function M.create_server(host, port, handler)
  local server = uv.new_tcp()
  if not server then
    vim.schedule(function()
      vim.notify("MCP HTTP: failed to create TCP server", vim.log.levels.ERROR)
    end)
    return nil
  end

  server:bind(host, port)
  server:listen(128, function(listen_err)
    if listen_err then
      vim.schedule(function()
        vim.notify("MCP HTTP listen error: " .. listen_err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    if not client then
      return
    end
    server:accept(client)

    local buffer = ""
    local conn = Connection.new(client)

    client:read_start(function(read_err, chunk)
      if read_err then
        conn:close()
        return
      end

      if not chunk then
        conn:close()
        return
      end

      buffer = buffer .. chunk

      if #buffer > MAX_REQUEST_SIZE then
        conn:respond(413, { ["Content-Type"] = "application/json" }, '{"error":"Request too large"}')
        return
      end

      local header_end = buffer:find("\r\n\r\n")
      if not header_end then
        return
      end

      local content_length = nil
      local header_section = buffer:sub(1, header_end - 1)
      for line in header_section:gmatch("([^\r\n]+)") do
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key and key:lower() == "content-length" then
          content_length = tonumber(value)
          break
        end
      end

      local body_start = header_end + 4
      if content_length then
        local body_received = #buffer - body_start + 1
        if body_received < content_length then
          return
        end
      end

      local request = parse_request(buffer)
      buffer = ""

      if not request then
        conn:respond(400, { ["Content-Type"] = "application/json" }, "")
        return
      end

      vim.schedule(function()
        handler(request, conn)
      end)
    end)
  end)

  return server
end

return M
