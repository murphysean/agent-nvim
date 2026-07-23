--- Shared security utilities.
---
--- Token generation used by lockfile.lua and bridge.lua. Centralized
--- here so both modules use the same implementation and error handling.

local uv = vim.uv or vim.loop

local M = {}

--- Generate a 128-bit auth token (32 hex chars) from cryptographically
--- secure random bytes. Errors if uv.random fails — never falls back
--- to a predictable token.
function M.gen_token()
  local bytes = uv.random(16)
  if not bytes then
    error("uv.random failed — cannot generate secure auth token")
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

--- Like gen_token, but returns (nil, err) instead of throwing.
function M.gen_token_safe()
  local ok, token = pcall(M.gen_token)
  if not ok then
    return nil, token
  end
  return token
end

return M
