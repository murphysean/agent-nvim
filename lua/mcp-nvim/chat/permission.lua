--- session/request_permission queue.
---
--- Per ACP, the agent may ask the editor to approve a tool call. The editor
--- responds with one of the offered options ({optionId, name, kind}), where
--- kind ∈ {allow_once, allow_always, reject_once, reject_always}.
---
--- We queue requests so only one approval prompt is on-screen at a time. If
--- a chat is closed (or the agent cancels), all pending requests resolve
--- with {outcome:"cancelled"} so the agent unblocks.

local M = {}

local queue = {}
local in_flight = nil

local function pick_default(options, kind_pref)
  for _, o in ipairs(options or {}) do
    if o.kind == kind_pref then
      return o
    end
  end
  return options and options[1] or nil
end

local function ui_choice(prompt, options, on_pick)
  local labels = {}
  for _, o in ipairs(options) do
    table.insert(labels, o.name or o.optionId or o.kind or "?")
  end
  vim.ui.select(labels, { prompt = prompt }, function(_, idx)
    if idx and options[idx] then
      on_pick(options[idx])
    else
      on_pick(nil)
    end
  end)
end

local function safe_respond(req, payload)
  if req.done then
    return
  end
  req.done = true
  pcall(req.respond, payload)
end

local function present(req)
  local params = req.params
  local tool_id = params.toolCall and params.toolCall.toolCallId or "?"
  local options = params.options or {}

  -- TODO: phase 5+: when chat.tool_lines[tool_id].last_update.content has a
  -- diff block, route through review.lua for an in-line accept/reject. For
  -- now, all permission prompts go through a simple choice UI.
  local prompt = "Tool call " .. tool_id .. ": approve?"
  ui_choice(prompt, options, function(picked)
    -- If a cancel beat us to the response, this is a no-op.
    if not picked then
      safe_respond(req, { outcome = { outcome = "cancelled" } })
    else
      safe_respond(req, { outcome = { outcome = "selected", optionId = picked.optionId } })
    end
    if in_flight == req then
      in_flight = nil
    end
    -- Drain the queue.
    M.pump()
  end)
end

function M.pump()
  if in_flight then
    return
  end
  while #queue > 0 do
    local req = table.remove(queue, 1)
    if req.cancelled or req.done then
      safe_respond(req, { outcome = { outcome = "cancelled" } })
    else
      in_flight = req
      present(req)
      return
    end
  end
end

--- Enqueue a request. Wraps the original respond fn so we can drop dupes
--- on cancel/close.
function M.enqueue(chat, params, respond)
  local req = {
    chat = chat,
    params = params,
    respond = respond,
    cancelled = false,
    done = false,
  }
  table.insert(queue, req)
  M.pump()
end

--- Cancel all pending requests for a chat (e.g. when the chat closes).
function M.cancel_for_chat(chat_id)
  if in_flight and in_flight.chat and in_flight.chat.id == chat_id then
    in_flight.cancelled = true
    safe_respond(in_flight, { outcome = { outcome = "cancelled" } })
    in_flight = nil
    -- Pump the next request so other chats' permissions aren't stalled.
    M.pump()
  end
  for _, req in ipairs(queue) do
    if req.chat and req.chat.id == chat_id then
      req.cancelled = true
    end
  end
end

--- Cancel everything (plugin teardown).
function M.cancel_all()
  if in_flight then
    safe_respond(in_flight, { outcome = { outcome = "cancelled" } })
    in_flight = nil
  end
  for _, req in ipairs(queue) do
    safe_respond(req, { outcome = { outcome = "cancelled" } })
  end
  queue = {}
end

return M
