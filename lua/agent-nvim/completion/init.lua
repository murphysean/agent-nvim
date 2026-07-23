--- Dynamic completion source registration for agent-nvim.
---
--- Lifecycle:
---   1. Always registers with blink.cmp if available (shows "✨ AI Complete" in menu)
---   2. Always claims omnifunc/completefunc on buffers where they're unclaimed
---   3. When a capable client connects → items appear / functions become active
---   4. When client disconnects / loses capability → items disappear / functions return empty
---
--- Users don't need to touch their config at all.

local M = {}

local blink_registered = false
local native_registered = false
local augroup = nil

--- Check if MCP sampling is currently available.
--- Used by both blink source and native completefuncs to gate themselves.
function M.sampling_available()
  local ok, sessions = pcall(require, "agent-nvim.sessions")
  if not ok or #sessions.list() == 0 then
    return false
  end
  local protocol = require("agent-nvim.mcp.protocol")
  return protocol.client_supports("sampling")
end

--- Register blink.cmp source (if blink is available).
local function register_blink()
  if blink_registered then
    return true
  end

  local blink_ok, blink = pcall(require, "blink.cmp")
  if not blink_ok or not blink.add_source_provider then
    return false
  end

  local ok, err = pcall(blink.add_source_provider, "mcp", {
    name = "MCP",
    module = "agent-nvim.completion.blink",
    score_offset = -5,
    async = true,
    min_keyword_length = 2,
    enabled = true,
  })

  if ok then
    pcall(function()
      local config = require("blink.cmp.config")
      if config.sources and type(config.sources.default) == "table" then
        if not vim.tbl_contains(config.sources.default, "mcp") then
          table.insert(config.sources.default, "mcp")
        end
      end
    end)
    blink_registered = true
    return true
  end

  if type(err) == "string" and err:find("already exists") then
    blink_registered = true
    return true
  end

  return false
end

--- Claim omnifunc/completefunc on a buffer if unclaimed.
local function claim_buffer_funcs(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return
  end

  local our_func = "v:lua.require'agent-nvim.completion.completefunc'.completefunc"

  local cf = vim.api.nvim_get_option_value("completefunc", { buf = buf })
  if cf == "" or cf == our_func then
    vim.api.nvim_set_option_value("completefunc", our_func, { buf = buf })
  end

  local of = vim.api.nvim_get_option_value("omnifunc", { buf = buf })
  if of == "" or of == our_func then
    vim.api.nvim_set_option_value("omnifunc", our_func, { buf = buf })
  end
end

--- Release our claims on a buffer.
local function release_buffer_funcs(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local our_func = "v:lua.require'agent-nvim.completion.completefunc'.completefunc"

  local cf = vim.api.nvim_get_option_value("completefunc", { buf = buf })
  if cf == our_func then
    vim.api.nvim_set_option_value("completefunc", "", { buf = buf })
  end

  local of = vim.api.nvim_get_option_value("omnifunc", { buf = buf })
  if of == our_func then
    vim.api.nvim_set_option_value("omnifunc", "", { buf = buf })
  end
end

--- Set up autocmds for dynamic claim/release.
local function register_native()
  if native_registered then
    return true
  end

  augroup = vim.api.nvim_create_augroup("agent_nvim_completion", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = augroup,
    callback = function(ev)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          claim_buffer_funcs(ev.buf)
        end
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = augroup,
    callback = function(ev)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          claim_buffer_funcs(ev.buf)
        end
      end, 200)
    end,
  })

  claim_buffer_funcs()
  native_registered = true
  return true
end

--- Main entry point. Registers ALL available integrations.
function M.register()
  register_blink()
  register_native()
  return blink_registered or native_registered
end

--- Re-claim all buffers (called when a client connects).
function M.on_client_connected()
  if not native_registered then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      claim_buffer_funcs(buf)
    end
  end
end

--- Release all buffers (called when all clients disconnect).
function M.on_client_disconnected()
  if not native_registered then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      release_buffer_funcs(buf)
    end
  end
end

function M.is_registered()
  return blink_registered or native_registered
end
function M.is_blink_registered()
  return blink_registered
end
function M.is_native_registered()
  return native_registered
end

return M
