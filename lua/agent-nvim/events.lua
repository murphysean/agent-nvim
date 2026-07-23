local sessions = require("agent-nvim.sessions")
local uv = vim.loop

local M = {}

local augroup = nil
local pending_notifications = {}
local debounce_timer = nil
local DEBOUNCE_MS = 500

local LEVEL_PRIORITY = {
  debug = 0,
  info = 1,
  warning = 2,
  error = 3,
}

local function log(level, message)
  local config = require("agent-nvim").config
  local min_level = LEVEL_PRIORITY[config.log_level] or 1
  local msg_level = LEVEL_PRIORITY[level] or 0
  if msg_level < min_level then
    return
  end
  sessions.broadcast("notifications/message", {
    level = level,
    logger = "neovim-mcp",
    data = message,
  })
end

local function flush_notifications()
  debounce_timer = nil
  for uri in pairs(pending_notifications) do
    sessions.notify_resource_updated(uri)
  end
  pending_notifications = {}
end

local function schedule_notification(uri)
  pending_notifications[uri] = true
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
  end
  debounce_timer = uv.new_timer()
  if not debounce_timer then
    return
  end
  debounce_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(flush_notifications))
end

function M.setup()
  if augroup then
    return
  end

  augroup = vim.api.nvim_create_augroup("McpNvimEvents", { clear = true })

  -- Buffer navigation
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufEnter: %s (buf %d)", name ~= "" and name or "[No Name]", ev.buf))
      sessions.notify_resource_updated("nvim://buffer/current")
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("debug", string.format("BufLeave: %s (buf %d)", name ~= "" and name or "[No Name]", ev.buf))
    end,
  })

  -- Text changes (debounced for resource updates, but log immediately)
  vim.api.nvim_create_autocmd("TextChanged", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("debug", string.format("TextChanged: %s (buf %d)", name ~= "" and name or "[No Name]", ev.buf))
      schedule_notification("nvim://buffer/current")
      schedule_notification("nvim://buffer/" .. ev.buf)
      if name ~= "" then
        schedule_notification("file://" .. name)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = augroup,
    callback = function(ev)
      schedule_notification("nvim://buffer/current")
      schedule_notification("nvim://buffer/" .. ev.buf)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" then
        schedule_notification("file://" .. name)
      end
    end,
  })

  -- File I/O
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufWritePre: saving %s", name))
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufWritePost: saved %s", name))
      sessions.notify_resource_updated("nvim://buffer/" .. ev.buf)
      if name ~= "" then
        sessions.notify_resource_updated("file://" .. name)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufReadPost: loaded %s (%d lines)", name, vim.api.nvim_buf_line_count(ev.buf)))
    end,
  })

  -- Buffer lifecycle
  vim.api.nvim_create_autocmd("BufAdd", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufAdd: %s (buf %d)", name ~= "" and name or "[No Name]", ev.buf))
      sessions.notify_list_changed()
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      log("info", string.format("BufDelete: %s (buf %d)", name ~= "" and name or "[No Name]", ev.buf))
      sessions.notify_list_changed()
    end,
  })

  -- Mode changes
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = augroup,
    callback = function(ev)
      local from_to = ev.match
      log("debug", string.format("ModeChanged: %s", from_to))
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    callback = function()
      log("debug", "InsertEnter")
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = function()
      log("debug", "InsertLeave")
    end,
  })

  -- Diagnostics
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = augroup,
    callback = function()
      local count = #vim.diagnostic.get()
      log("info", string.format("DiagnosticChanged: %d total diagnostics", count))
      sessions.notify_resource_updated("nvim://diagnostics")
    end,
  })

  -- Quickfix
  vim.api.nvim_create_autocmd("QuickFixCmdPost", {
    group = augroup,
    callback = function(ev)
      local qf = vim.fn.getqflist({ size = true })
      log("info", string.format("QuickFixCmdPost: %s (%d items)", ev.match or "", qf.size or 0))
      sessions.notify_resource_updated("nvim://quickfix")
    end,
  })

  -- Cursor (idle)
  vim.api.nvim_create_autocmd("CursorHold", {
    group = augroup,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local name = vim.api.nvim_buf_get_name(0)
      log("debug", string.format("CursorHold: %s:%d:%d", vim.fn.fnamemodify(name, ":t"), cursor[1], cursor[2] + 1))
      sessions.notify_resource_updated("nvim://cursor")
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function()
      -- Don't log every cursor move, just resource update (debounced by CursorHold)
    end,
  })

  -- Window events
  vim.api.nvim_create_autocmd("WinNew", {
    group = augroup,
    callback = function()
      log("info", string.format("WinNew: now %d windows", #vim.api.nvim_tabpage_list_wins(0)))
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      log("info", string.format("WinClosed: window %s", ev.match or "?"))
    end,
  })

  -- Tab events
  vim.api.nvim_create_autocmd("TabNew", {
    group = augroup,
    callback = function()
      log("info", string.format("TabNew: now %d tabs", #vim.api.nvim_list_tabpages()))
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      log("info", "TabClosed")
    end,
  })

  -- LSP
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    callback = function(ev)
      local clients = vim.lsp.get_clients({ id = ev.data.client_id })
      local name = clients[1] and clients[1].name or "unknown"
      log("info", string.format("LspAttach: %s attached to buf %d", name, ev.buf))
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = augroup,
    callback = function(ev)
      local clients = vim.lsp.get_clients({ id = ev.data.client_id })
      local name = clients[1] and clients[1].name or "unknown"
      log("info", string.format("LspDetach: %s detached from buf %d", name, ev.buf))
    end,
  })

  -- Terminal
  vim.api.nvim_create_autocmd("TermOpen", {
    group = augroup,
    callback = function(ev)
      log("info", string.format("TermOpen: buf %d", ev.buf))
    end,
  })

  vim.api.nvim_create_autocmd("TermClose", {
    group = augroup,
    callback = function(ev)
      log("info", string.format("TermClose: buf %d", ev.buf))
    end,
  })

  -- Focus
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      log("info", "FocusGained: Neovim regained focus")
    end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = function()
      log("info", "FocusLost: Neovim lost focus")
    end,
  })

  -- Vim lifecycle
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      log("info", string.format("VimResized: %dx%d", vim.o.columns, vim.o.lines))
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      log("warning", "VimLeavePre: Neovim is shutting down")
      local server = require("agent-nvim.server")
      server.stop()
    end,
  })

  -- FileType detection
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    callback = function(ev)
      if ev.match and ev.match ~= "" then
        log("debug", string.format("FileType: %s (buf %d)", ev.match, ev.buf))
      end
    end,
  })

  -- Search
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup,
    callback = function(ev)
      if ev.match == "/" or ev.match == "?" then
        log("debug", string.format("Search: %s", vim.fn.getreg("/")))
      end
    end,
  })
end

function M.teardown()
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end
  pending_notifications = {}
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
end

return M
