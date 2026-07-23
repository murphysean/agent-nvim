--- Stdio MCP bridge for mcp-nvim.
---
--- This is a standalone script run as a child of an ACP agent (e.g. goose):
---     nvim --headless -l <plugin>/bin/mcp-stdio-bridge.lua
---
--- The agent passes JSON-RPC messages on stdin, expects responses on stdout.
--- This bridge proxies each frame back to the spawning nvim instance via the
--- nvim RPC socket pointed to by env MCP_NVIM_TARGET, authenticated with
--- MCP_NVIM_AUTH.
---
--- Per the MCP stdio transport spec, framing is newline-delimited JSON: each
--- complete JSON object is on a single line terminated by \n. Messages must
--- not contain embedded newlines.
---
--- Stdout is reserved exclusively for JSON-RPC frames. All logging goes to
--- stderr (visible to goose / parent process).
---
--- Implementation note: under `nvim --headless -l`, Lua's `io.read("*l")` is
--- not reliable for blocking on a real pipe — Neovim does not wire stdin to
--- the C `io` module the way a standalone Lua interpreter does. We use libuv
--- pipes via vim.loop / vim.uv directly, which give us proper async stdin
--- reads and lets the event loop service vim.rpcrequest concurrently.

local uv = vim.uv or vim.loop

local target = os.getenv("MCP_NVIM_TARGET")
local auth = os.getenv("MCP_NVIM_AUTH")

if not target or target == "" then
  io.stderr:write("[mcp-stdio-bridge] MCP_NVIM_TARGET not set\n")
  os.exit(1)
end
if not auth or auth == "" then
  io.stderr:write("[mcp-stdio-bridge] MCP_NVIM_AUTH not set\n")
  os.exit(1)
end

local ok, ch = pcall(vim.fn.sockconnect, "pipe", target, { rpc = true })
if not ok or not ch or ch == 0 then
  io.stderr:write(string.format("[mcp-stdio-bridge] cannot connect to %s: %s\n", target, tostring(ch)))
  os.exit(1)
end

io.stderr:write(string.format("[mcp-stdio-bridge] connected to %s (channel %d)\n", target, ch))

local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
stdin:open(0)
stdout:open(1)

local buf = ""
local exiting = false

local function write_frame(line)
  -- libuv pipe writes are async; queue and let the loop flush. We don't
  -- wait for completion because the next read won't happen until the loop
  -- ticks anyway.
  local payload = line
  if not payload:match("\n$") then
    payload = payload .. "\n"
  end
  stdout:write(payload, function(err)
    if err then
      io.stderr:write("[mcp-stdio-bridge] stdout write error: " .. tostring(err) .. "\n")
    end
  end)
end

local function dispatch(line)
  -- vim.rpcrequest is synchronous: it pumps the libuv loop until the response
  -- arrives, so other in-flight callbacks (stdin reads, stderr logs, the
  -- channel's own keepalive) keep working. The parent's _mcp_nvim_bridge_dispatch
  -- runs to completion (possibly via vim.wait for async tools) and returns
  -- the JSON-RPC response body string (or nil for notifications).
  local rok, response =
    pcall(vim.rpcrequest, ch, "nvim_exec_lua", "return _G._mcp_nvim_bridge_dispatch(...)", { auth, line })
  if not rok then
    io.stderr:write("[mcp-stdio-bridge] rpc error: " .. tostring(response) .. "\n")
    write_frame('{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"bridge: parent rpc failure"}}')
    return
  end
  if type(response) == "string" and #response > 0 then
    write_frame(response)
  end
  -- response == nil → notification; nothing to write.
end

stdin:read_start(function(err, chunk)
  if err then
    io.stderr:write("[mcp-stdio-bridge] stdin error: " .. tostring(err) .. "\n")
    exiting = true
    return
  end
  if not chunk then
    -- EOF: parent closed stdin (agent shutting down).
    exiting = true
    return
  end
  buf = buf .. chunk
  -- Buffer-bound runaway protection.
  if #buf > 16 * 1024 * 1024 then
    io.stderr:write("[mcp-stdio-bridge] buffer overflow, dropping\n")
    buf = ""
    return
  end
  while true do
    local nl = buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = buf:sub(1, nl - 1):gsub("\r$", "")
    buf = buf:sub(nl + 1)
    if #line > 0 then
      dispatch(line)
    end
  end
end)

-- Pump the libuv loop until stdin closes. Use vim.wait with a poll so the
-- loop services pipe reads and rpcrequest replies simultaneously.
while not exiting do
  vim.wait(200, function()
    return exiting
  end, 20)
end

io.stderr:write("[mcp-stdio-bridge] shutting down\n")
pcall(function()
  stdin:close()
end)
pcall(function()
  stdout:close()
end)
pcall(vim.fn.chanclose, ch)
os.exit(0)
