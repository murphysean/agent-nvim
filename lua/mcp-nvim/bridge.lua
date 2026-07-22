--- Stdio-MCP-bridge dispatch surface (parent side).
---
--- The mcp-nvim plugin spawns external agents (e.g., goose acp) as child
--- processes and tells those agents about a "stdio" MCP server in their
--- session/new request. That stdio MCP server is `nvim --headless -l
--- bin/mcp-stdio-bridge.lua`, which proxies every JSON-RPC frame back into
--- this nvim instance via the regular --listen RPC socket.
---
--- This module exposes the global `_mcp_nvim_bridge_dispatch(token, body)`
--- function that the bridge calls into. It validates the auth token, runs
--- the request through the existing protocol handler, and synchronously
--- returns the response body (waiting for async tool callbacks if needed).
---
--- Tokens are minted per spawn via M.mint() and revoked via M.revoke() when
--- the agent process exits. Multiple bridges may be live concurrently.

local protocol = require("mcp-nvim.mcp.protocol")
local registry = require("mcp-nvim.mcp.registry")
local uv = vim.uv or vim.loop

local M = {}

-- Max time to wait for an async tool call (ms). Overridable via
-- config.bridge_timeout_ms. 120s default — long enough for most tools.
local BRIDGE_TIMEOUT_MS = 120000

-- token -> { spawn_id, bridge_session_id }
local active_tokens = {}

local function gen_token()
  local bytes = uv.random(16)
  if not bytes then
    error("bridge: uv.random failed — cannot generate secure auth token")
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

--- Mint a new bridge auth token tied to a logical spawn.
--- Caller passes spawn_id (e.g., chat session id) for reference.
--- Returns the token string.
function M.mint(spawn_id)
  local token_ok, token = pcall(gen_token)
  if not token_ok then
    return nil
  end
  -- Each bridge gets its own MCP session id so subscriptions/state
  -- don't leak between concurrent agents talking to the same nvim.
  local bridge_session_id = "bridge-" .. token:sub(1, 8)
  active_tokens[token] = {
    spawn_id = spawn_id,
    bridge_session_id = bridge_session_id,
  }
  return token
end

--- Revoke a token; subsequent dispatches with it will be rejected.
function M.revoke(token)
  if token then
    active_tokens[token] = nil
  end
end

--- Revoke all tokens (e.g., on plugin teardown).
function M.revoke_all()
  active_tokens = {}
end

--- Returns true if the token is currently active.
function M.is_active(token)
  return active_tokens[token] ~= nil
end

--- Bridge entrypoint: dispatch a JSON-RPC frame from a child stdio bridge.
--- Returns:
---   - response body string if the request expects a response,
---   - nil if it was a notification (no id),
---   - nil if the request was an unauthenticated/unknown token.
---
--- Async tool calls block via vim.wait until the response arrives or a
--- timeout fires. The parent's event loop continues to spin during the wait.
function _G._mcp_nvim_bridge_dispatch(token, body)
  local json = require("mcp-nvim.json")
  local entry = active_tokens[token]
  if not entry then
    -- Try to recover the original request id so the response is well-formed
    -- per JSON-RPC; fall back to null if the body is unparseable.
    local id = vim.NIL
    local ok, parsed = pcall(json.decode, body)
    if ok and type(parsed) == "table" and parsed.id ~= nil then
      id = parsed.id
    end
    return json.encode({
      jsonrpc = "2.0",
      id = id,
      error = { code = -32001, message = "bridge: invalid auth token" },
    })
  end

  local session_id = entry.bridge_session_id
  local pending = nil
  local function respond_fn(response_body)
    pending = response_body
  end

  local result = protocol.handle_jsonrpc(body, registry, session_id, respond_fn)

  if result == "async" then
    -- Allow config override of the timeout.
    local cfg = require("mcp-nvim").config or {}
    local timeout = cfg.bridge_timeout_ms or BRIDGE_TIMEOUT_MS
    -- Block the bridge call (not the nvim event loop) until the tool finishes.
    local ok = vim.wait(timeout, function()
      return pending ~= nil
    end, 10)
    if not ok then
      return json.encode({
        jsonrpc = "2.0",
        id = vim.NIL,
        error = { code = -32603, message = "bridge: tool call timed out (" .. (timeout / 1000) .. "s)" },
      })
    end
    return pending
  end

  -- For notifications (no id, no response body), result is nil — bridge
  -- skips writing to stdout.
  return result
end

return M
