--- Chat session registry. One chat = one ACP session = one buffer.
---
--- Multiple chats may be open concurrently; the active chat is the one
--- whose tab is selected in the chat winbar (rendered by chat/ui.lua).
---
--- A chat owns:
---   - an acp.Session (its own goose process for now; multi-session-per-process
---     is a phase-6 optimization)
---   - a buffer (chat history + prompt line)
---   - a UI state map { tool_id -> {line, status} } for in-place updates
---
--- The plugin holds a single shared `state` table here; everything else
--- (UI rendering, command handlers) reads/writes through these helpers.

local M = {}

local state = {
  chats = {}, -- chat_id -> Chat
  order = {}, -- ordered list of chat_ids for tab navigation
  active = nil, -- currently active chat_id
  next_id = 1,
  win = nil, -- the bottom-split window holding the active chat buffer
}

function M.state()
  return state
end

function M.new_id()
  local id = state.next_id
  state.next_id = id + 1
  return tostring(id)
end

function M.add(chat)
  state.chats[chat.id] = chat
  table.insert(state.order, chat.id)
  if not state.active then
    state.active = chat.id
  end
end

function M.remove(chat_id)
  state.chats[chat_id] = nil
  for i, id in ipairs(state.order) do
    if id == chat_id then
      table.remove(state.order, i)
      break
    end
  end
  if state.active == chat_id then
    state.active = state.order[1] or nil
  end
end

function M.get(chat_id)
  return state.chats[chat_id]
end

function M.active()
  return state.chats[state.active]
end

function M.set_active(chat_id)
  if state.chats[chat_id] then
    state.active = chat_id
  end
end

function M.list()
  local out = {}
  for _, id in ipairs(state.order) do
    table.insert(out, state.chats[id])
  end
  return out
end

function M.next()
  if #state.order < 2 then
    return state.active
  end
  for i, id in ipairs(state.order) do
    if id == state.active then
      state.active = state.order[i + 1] or state.order[1]
      return state.active
    end
  end
end

function M.prev()
  if #state.order < 2 then
    return state.active
  end
  for i, id in ipairs(state.order) do
    if id == state.active then
      state.active = state.order[i - 1] or state.order[#state.order]
      return state.active
    end
  end
end

function M.set_window(win)
  state.win = win
end

--- Returns the chat window if valid, nil otherwise.
--- Does NOT mutate state — use clear_window() to clean up stale references.
function M.window()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
  return nil
end

--- Clear the stored window handle if it's no longer valid.
function M.clear_window()
  if state.win and not vim.api.nvim_win_is_valid(state.win) then
    state.win = nil
  end
end

function M.shutdown_all(opts)
  for _, chat in pairs(state.chats) do
    if chat.session then
      pcall(function()
        chat.session:stop(opts)
      end)
    end
  end
  state.chats = {}
  state.order = {}
  state.active = nil
end

return M
