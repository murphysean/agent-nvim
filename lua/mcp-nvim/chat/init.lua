--- Chat orchestration: spawn an ACP session, render its events into a
--- chat buffer, route user prompts to the session.

local sessions = require("mcp-nvim.chat.sessions")
local ui = require("mcp-nvim.chat.ui")
local permission = require("mcp-nvim.chat.permission")
local AcpSession = require("mcp-nvim.acp.session")

local M = {}

--- Default agent spawn config. Overridable via setup({ acp = { ... } }).
local function default_spawn()
  local cfg = require("mcp-nvim").config or {}
  local acp_cfg = cfg.acp or {}
  return {
    command = acp_cfg.command or "goose",
    args = acp_cfg.args or { "acp", "--with-builtin", "developer,editor" },
    env = acp_cfg.env or {},
  }
end

local function on_status(chat, state, info)
  vim.schedule(function()
    if state == "connecting" then
      ui.append_status(chat, "spawning agent...")
    elseif state == "initialized" then
      ui.append_status(chat, "agent initialized, creating session...")
    elseif state == "ready" then
      ui.append_status(chat, "session ready (id=" .. tostring(info and info.sessionId or "?") .. ")")
      ui.focus_prompt()
    elseif state == "error" then
      ui.append_status(chat, "error: " .. vim.inspect(info))
    elseif state == "exited" then
      ui.append_status(chat, "agent exited (code=" .. tostring(info and info.code) .. ")")
    elseif state == "warning" then
      ui.append_status(chat, "warning: " .. tostring(info))
    end
  end)
end

local function on_update(chat, params)
  vim.schedule(function()
    local update = params and params.update or {}
    local kind = update.sessionUpdate
    if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
      local text = update.content and update.content.text or ""
      ui.stream_text(chat, kind, text)
    elseif kind == "user_message_chunk" then
      -- Echo from agent (e.g., on session/load replay) — already rendered.
    elseif kind == "tool_call" or kind == "tool_call_update" then
      ui.render_tool_call(chat, update)
    elseif kind == "plan" then
      ui.render_plan(chat, update.entries or {})
    elseif kind == "current_mode_update" then
      ui.append_status(chat, "mode: " .. tostring(update.currentModeId))
    elseif kind == "usage_update" then
      -- Optional: surface tokens/cost in winbar later.
    elseif kind == "available_commands_update" then
      -- Ignored for v1.
    end
  end)
end

local function on_permission(chat, params, respond)
  vim.schedule(function()
    ui.append_status(chat, "permission requested for tool " .. tostring(params.toolCall and params.toolCall.toolCallId))
  end)
  permission.enqueue(chat, params, respond)
end

--- Create a fresh chat (its own buffer + ACP session) and make it active.
function M.new()
  local plugin = require("mcp-nvim")
  local chat_id = sessions.new_id()
  local buf = ui.create_buffer(chat_id)
  local chat = {
    id = chat_id,
    buf = buf,
    session = nil,
    tool_lines = {},
    blocks = {},
  }
  sessions.add(chat)

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    M.submit()
  end, { buffer = buf, desc = "mcp-chat: send prompt" })

  vim.keymap.set("n", "<CR>", function()
    ui.focus_prompt()
  end, { buffer = buf, desc = "mcp-chat: focus prompt" })

  vim.keymap.set("n", "]b", function()
    ui.jump_next_block(chat)
  end, { buffer = buf, desc = "mcp-chat: next block" })

  vim.keymap.set("n", "[b", function()
    ui.jump_prev_block(chat)
  end, { buffer = buf, desc = "mcp-chat: previous block" })

  vim.keymap.set("n", "q", function()
    ui.hide()
  end, { buffer = buf, desc = "mcp-chat: hide window" })

  vim.keymap.set("n", "<C-c>", function()
    M.cancel()
  end, { buffer = buf, desc = "mcp-chat: cancel turn" })

  -- Build the ACP session.
  local sess = AcpSession.new({
    spawn = default_spawn(),
    cwd = vim.fn.getcwd(),
    plugin_dir = plugin.plugin_dir(),
    include_bridge = true,
    spawn_id = "chat-" .. chat_id,
    client_info = { name = "mcp-nvim", version = plugin.version },
    on_status = function(state, info)
      on_status(chat, state, info)
    end,
    on_update = function(params)
      on_update(chat, params)
    end,
    on_permission = function(params, respond)
      on_permission(chat, params, respond)
    end,
    on_stderr = function(line)
      -- Stash a few lines in the buffer for debugging; cap noise.
      if line:lower():match("error") or line:lower():match("panic") then
        vim.schedule(function()
          ui.append_status(chat, "[stderr] " .. line)
        end)
      end
    end,
  })
  chat.session = sess

  ui.show()

  sess:start(function(err)
    if err then
      return
    end
    sess:create(function(_)
      -- on_status("ready", ...) fires from the session module.
    end)
  end)

  return chat
end

--- Submit whatever is on the prompt line of the active chat.
function M.submit()
  local chat = sessions.active()
  if not chat or not chat.session then
    return
  end
  local text = ui.consume_prompt(chat)
  if not text or text == "" then
    return
  end
  -- Drop out of insert mode.
  vim.cmd("stopinsert")
  ui.append_user_prompt(chat, text)
  chat.session:prompt({ { type = "text", text = text } }, function(err, stop_reason)
    vim.schedule(function()
      if err then
        ui.append_status(chat, "turn error: " .. (err.message or vim.inspect(err)))
      else
        ui.append_status(chat, "[turn end: " .. tostring(stop_reason) .. "]")
      end
      ui.focus_prompt()
    end)
  end)
end

--- Open the chat window. If no chats exist yet, create the first one.
function M.open()
  if not sessions.active() then
    M.new()
    return
  end
  ui.show()
  ui.focus_prompt()
end

--- Toggle the chat window (hide if visible, show otherwise). Keeps session
--- and process alive when hidden.
function M.toggle()
  sessions.clear_window()
  if sessions.window() then
    ui.hide()
  else
    M.open()
  end
end

function M.next()
  sessions.next()
  ui.show()
  ui.refresh_winbar()
end

function M.prev()
  sessions.prev()
  ui.show()
  ui.refresh_winbar()
end

function M.switch(chat_id)
  if not sessions.get(chat_id) then
    vim.notify("mcp-chat: no session " .. tostring(chat_id), vim.log.levels.WARN)
    return
  end
  sessions.set_active(chat_id)
  ui.show()
  ui.refresh_winbar()
end

function M.list()
  local out = {}
  for _, c in ipairs(sessions.list()) do
    table.insert(out, string.format("[%s] state=%s", c.id, c.session and c.session:state() or "?"))
  end
  return table.concat(out, "\n")
end

--- Cancel the in-flight turn of the active chat.
function M.cancel()
  local chat = sessions.active()
  if chat and chat.session then
    chat.session:cancel()
  end
end

--- Close the active chat, terminating its session.
function M.close()
  local chat = sessions.active()
  if not chat then
    return
  end
  permission.cancel_for_chat(chat.id)
  if chat.session then
    pcall(function()
      chat.session:stop()
    end)
  end
  if vim.api.nvim_buf_is_valid(chat.buf) then
    pcall(vim.api.nvim_buf_delete, chat.buf, { force = true })
  end
  sessions.remove(chat.id)
  if sessions.active() then
    ui.show()
    ui.refresh_winbar()
  else
    ui.hide()
  end
end

function M.shutdown()
  permission.cancel_all()
  -- Sync kill: VimLeavePre runs synchronously then nvim exits, so deferred
  -- timers never fire. SIGTERM immediately and let the kernel reap.
  sessions.shutdown_all({ sync = true })
end

return M
