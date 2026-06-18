--- JSON-RPC 2.0 framing helpers for ACP stdio transport.
---
--- ACP framing (per Zed's spec implementation): newline-delimited JSON over
--- stdin/stdout. Each frame is exactly one JSON object terminated by \n; no
--- embedded newlines. (Optional CR before the LF is tolerated.)

local json = require("mcp-nvim.json")

local M = {}

--- A line buffer that accumulates partial reads and yields complete frames.
--- Stream chunks may arrive split across frame boundaries, contain multiple
--- frames, or both — the buffer handles all three cases.
local LineBuffer = {}
LineBuffer.__index = LineBuffer

function M.new_line_buffer()
  return setmetatable({ buf = "" }, LineBuffer)
end

--- Append raw bytes from a stdout chunk and return any complete frames as
--- decoded JSON objects (in arrival order). Frames that fail to parse are
--- skipped silently — caller can install a logger via on_parse_error.
function LineBuffer:feed(chunk)
  if not chunk or chunk == "" then
    return {}
  end
  self.buf = self.buf .. chunk
  local frames = {}
  while true do
    local nl = self.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
    self.buf = self.buf:sub(nl + 1)
    if #line > 0 then
      local ok, msg = pcall(json.decode, line)
      if ok and type(msg) == "table" then
        table.insert(frames, msg)
      elseif self.on_parse_error then
        self.on_parse_error(line, msg)
      end
    end
  end
  return frames
end

--- Encode a JSON-RPC message to its on-the-wire string with trailing newline.
function M.encode_frame(msg)
  return json.encode(msg) .. "\n"
end

--- Build a request envelope. Caller supplies id; framing is uniform.
function M.request(id, method, params)
  return {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }
end

function M.notification(method, params)
  return {
    jsonrpc = "2.0",
    method = method,
    params = params,
  }
end

function M.success(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
end

function M.error(id, code, message, data)
  local err = { code = code, message = message }
  if data ~= nil then
    err.data = data
  end
  return {
    jsonrpc = "2.0",
    id = id,
    error = err,
  }
end

--- Monotonic id allocator scoped to a single connection.
local IdGen = {}
IdGen.__index = IdGen

function M.new_id_gen()
  return setmetatable({ next = 1 }, IdGen)
end

function IdGen:alloc()
  local id = self.next
  self.next = id + 1
  return id
end

return M
