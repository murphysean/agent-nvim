--- Chat UI: a single bottom split that hosts whichever chat buffer is
--- currently active. The buffer holds:
---   1. Streamed chat history (read-only above the prompt marker).
---   2. A "> " prompt region at the bottom (multiline). <C-s> sends.
---
--- Tool-call rendering: each tool_call notification appends a single status
--- line ("⏳ Edit: lua/foo.lua") and stashes its line number in
--- chat.tool_lines[toolCallId]. Subsequent tool_call_update notifications
--- rewrite that line with the new icon + title. Diff/output content blocks
--- are rendered as nested lines below the status line.
---
--- The chat winbar renders tabs for all open chats (e.g. "[1] [2*] [3]") so
--- the user can see and click between them.

local sessions = require("mcp-nvim.chat.sessions")

local M = {}

local NS = vim.api.nvim_create_namespace("mcp_chat_ui")
local PROMPT_PREFIX = "[C-s] > "

local STATUS_ICON = {
  pending = "○",
  in_progress = "◐",
  completed = "●",
  failed = "✗",
}

local KIND_ICON = {
  read = "",
  edit = "",
  delete = "",
  move = "",
  search = "",
  execute = "",
  think = "",
  fetch = "",
  other = "",
}

--- Record a block boundary. Blocks shift as lines are inserted above them,
--- so we store extmarks (which track through insertions) rather than raw
--- line numbers. The blocks list is ordered by creation time.
function M.add_block(chat, kind, row)
  chat.blocks = chat.blocks or {}
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local mark_id = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
  table.insert(chat.blocks, { kind = kind, mark = mark_id })
end

--- Get the (0-indexed) line of a block by index in chat.blocks.
local function block_line(chat, idx)
  local b = chat.blocks[idx]
  if not b then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(chat.buf, NS, b.mark, {})
  return pos[1]
end

--- Jump to the next block from the current cursor position.
function M.jump_next_block(chat)
  if not chat or not chat.blocks or #chat.blocks == 0 then
    return
  end
  local win = sessions.window()
  if not win then
    return
  end
  local cur_row = vim.api.nvim_win_get_cursor(win)[1] - 1
  for i = 1, #chat.blocks do
    local row = block_line(chat, i)
    if row and row > cur_row then
      vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
      return
    end
  end
end

--- Jump to the previous block from the current cursor position.
function M.jump_prev_block(chat)
  if not chat or not chat.blocks or #chat.blocks == 0 then
    return
  end
  local win = sessions.window()
  if not win then
    return
  end
  local cur_row = vim.api.nvim_win_get_cursor(win)[1] - 1
  for i = #chat.blocks, 1, -1 do
    local row = block_line(chat, i)
    if row and row < cur_row then
      vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
      return
    end
  end
end

--- Create a new chat buffer (not yet attached to a session).
local PROMPT_MARK_NS = vim.api.nvim_create_namespace("mcp_chat_prompt")

--- Get the 0-indexed line where the prompt region starts.
--- The prompt mark is set when the buffer is created and stays anchored
--- via extmark, so it shifts as content is inserted above it.
local function prompt_start_index(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, PROMPT_MARK_NS, 0, -1, {})
  if marks[1] then
    return marks[1][2]
  end
  -- Fallback: last line.
  return vim.api.nvim_buf_line_count(buf) - 1
end

function M.create_buffer(chat_id)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "mcp-chat://" .. chat_id)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "mcpchat", { buf = buf })

  -- Initial layout: a header line + a blank line + the prompt line.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# mcp-chat session " .. chat_id,
    "",
    PROMPT_PREFIX,
  })

  -- Mark the prompt start so we can find it as content is inserted above.
  vim.api.nvim_buf_set_extmark(buf, PROMPT_MARK_NS, 2, 0, {})

  return buf
end

--- Insert lines just above the prompt region. Returns the row of the first
--- inserted line (0-indexed).
function M.insert_above_prompt(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local plr = prompt_start_index(buf)
  vim.api.nvim_buf_set_lines(buf, plr, plr, false, lines)
  return plr
end

--- Replace a single line at `row` (0-indexed) with `text`.
function M.replace_line(buf, row, text)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { text })
end

--- Append streamed text from the agent. Chunks may arrive split across line
--- boundaries; we keep a cursor at chat.stream_line pointing to the "open"
--- line, and chat.stream_buffer holds whatever we've accumulated for THAT
--- LINE ONLY. Each chunk:
---   1. Finds any newlines in (stream_buffer + chunk).
---   2. The prefix up to the last \n becomes finalized lines (left in place).
---   3. The remainder after the last \n becomes the new open-line content.
---
--- The first time we stream after a non-stream event, we insert a fresh
--- header line ("" or "") and make it the open line.
local AGENT_PREFIX = "  "
local THOUGHT_PREFIX = "  "

function M.stream_text(chat, kind, text)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) or text == "" then
    return
  end

  if chat.stream_kind ~= kind then
    -- Start a new streamed block.
    local header = kind == "agent_thought_chunk" and "" or ""
    local row = M.insert_above_prompt(buf, { header })
    chat.stream_kind = kind
    chat.stream_line = prompt_start_index(buf) - 1
    chat.stream_buffer = ""
    chat.stream_prefix = kind == "agent_thought_chunk" and THOUGHT_PREFIX or AGENT_PREFIX
    if row then
      local block_type = kind == "agent_thought_chunk" and "thought" or "agent"
      M.add_block(chat, block_type, row)
    end
  end

  local combined = (chat.stream_buffer or "") .. text
  local last_nl = nil
  -- Find the last newline in the combined string.
  for i = #combined, 1, -1 do
    if combined:sub(i, i) == "\n" then
      last_nl = i
      break
    end
  end

  local pre_lines, open_text
  if last_nl then
    pre_lines = vim.split(combined:sub(1, last_nl - 1), "\n", { plain = true })
    open_text = combined:sub(last_nl + 1)
  else
    pre_lines = nil
    open_text = combined
  end

  -- Rewrite the open line with everything up to (and not including) the last \n.
  if pre_lines and #pre_lines > 0 then
    local first = pre_lines[1]
    M.replace_line(buf, chat.stream_line, chat.stream_prefix .. first)
    if #pre_lines > 1 then
      local rest = {}
      for i = 2, #pre_lines do
        table.insert(rest, chat.stream_prefix .. pre_lines[i])
      end
      M.insert_above_prompt(buf, rest)
    end
    -- Open a fresh line for what's still flowing — but only if there IS
    -- still content beyond the last \n. Otherwise, end the stream so the
    -- next chunk starts a fresh block (avoids a trailing blank prefix line).
    if open_text ~= "" then
      M.insert_above_prompt(buf, { chat.stream_prefix .. open_text })
      chat.stream_line = prompt_start_index(buf) - 1
      chat.stream_buffer = open_text
    else
      M.end_stream(chat)
    end
  else
    -- All within the open line: rewrite it.
    M.replace_line(buf, chat.stream_line, chat.stream_prefix .. open_text)
    chat.stream_buffer = open_text
  end
end

--- End the current streamed block so the next chunk starts fresh.
function M.end_stream(chat)
  chat.stream_kind = nil
  chat.stream_line = nil
  chat.stream_buffer = nil
end

local function format_tool_label(update)
  -- ACP tool_call may include title, kind, and locations.
  local kind = update.kind or "other"
  local kicon = KIND_ICON[kind] or KIND_ICON.other
  local sicon = STATUS_ICON[update.status or "pending"] or "?"
  local title = update.title or "tool call"
  -- Prefer location path or first diff path if title is generic.
  if update.locations and #update.locations > 0 and update.locations[1].path then
    title = title .. " " .. update.locations[1].path
  elseif update.content then
    for _, c in ipairs(update.content) do
      if c.type == "diff" and c.path then
        title = title .. " " .. c.path
        break
      end
    end
  end
  return string.format("%s %s %s", sicon, kicon, title)
end

--- Render or update a tool_call card.
function M.render_tool_call(chat, update)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local id = update.toolCallId
  if not id then
    return
  end

  chat.tool_lines = chat.tool_lines or {}
  local label = format_tool_label(update)

  if not chat.tool_lines[id] then
    -- First sighting: append a single line above the prompt.
    -- Per CodeCompanion's rule, skip pure 'pending' renders to avoid flicker
    -- when an in_progress update is imminent. But we always render the first
    -- *non-pending* update.
    if (update.status or "pending") == "pending" then
      -- Stash data for when we do render.
      chat.tool_lines[id] = { line = nil, last_label = label, last_update = update }
      return
    end
    local row = M.insert_above_prompt(buf, { label }) or 0
    chat.tool_lines[id] = { line = row, last_label = label, last_update = update }
    M.add_block(chat, "tool", row)
  else
    local entry = chat.tool_lines[id]
    -- Merge new fields onto last_update so partial tool_call_update payloads
    -- preserve title/kind/etc.
    for k, v in pairs(update) do
      entry.last_update[k] = v
    end
    label = format_tool_label(entry.last_update)
    if entry.line then
      M.replace_line(buf, entry.line, label)
    else
      -- Was deferred (pending stash): now render.
      local row = M.insert_above_prompt(buf, { label }) or 0
      entry.line = row
      M.add_block(chat, "tool", row)
    end
    entry.last_label = label
  end
end

--- Render a plan update as a checklist block above the prompt. The agent
--- always sends the *complete* plan list per ACP, so we replace the previous
--- block in place if we know its location.
function M.render_plan(chat, plan_entries)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = { " Plan:" }
  for _, e in ipairs(plan_entries or {}) do
    local mark = "○"
    if e.status == "completed" then
      mark = "●"
    elseif e.status == "in_progress" then
      mark = "◐"
    end
    table.insert(lines, "  " .. mark .. " " .. (e.content or ""))
  end
  if chat.plan_range then
    local s, e = chat.plan_range[1], chat.plan_range[2]
    vim.api.nvim_buf_set_lines(buf, s, e, false, lines)
    chat.plan_range = { s, s + #lines }
  else
    local row = M.insert_above_prompt(buf, lines) or 0
    chat.plan_range = { row, row + #lines }
  end
end

--- Append a user prompt line above the prompt marker, formatted as input echo.
function M.append_user_prompt(chat, text)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = { " you:" }
  for _, t in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, "  " .. t)
  end
  local row = M.insert_above_prompt(buf, lines)
  if row then
    M.add_block(chat, "user", row)
  end
end

--- Append a status / system line.
function M.append_status(chat, text)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local row = M.insert_above_prompt(buf, { " " .. text })
  if row then
    M.add_block(chat, "status", row)
  end
end

local function chat_winbar()
  local list = sessions.list()
  local active = sessions.active()
  if #list == 0 then
    return "%#WinBar# mcp-chat %*"
  end
  local parts = { "%#WinBar# mcp-chat " }
  for _, c in ipairs(list) do
    if active and c.id == active.id then
      table.insert(parts, "%#WinBarNC#[%*%#WinBar#" .. c.id .. "*%#WinBarNC#]%* ")
    else
      table.insert(parts, "%#WinBarNC#[" .. c.id .. "]%* ")
    end
  end
  table.insert(parts, "%*")
  return table.concat(parts, "")
end

--- Open or focus the bottom split with the active chat's buffer.
function M.show()
  local active = sessions.active()
  if not active then
    return
  end
  local win = sessions.window()
  if win then
    vim.api.nvim_win_set_buf(win, active.buf)
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_set_option_value, "winbar", chat_winbar(), { win = win })
    return
  end
  -- Open a new bottom split (15 lines tall by default).
  vim.cmd("botright " .. (require("mcp-nvim").config.chat_height or 15) .. "split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, active.buf)
  pcall(vim.api.nvim_set_option_value, "winbar", chat_winbar(), { win = win })
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
  sessions.set_window(win)
end

--- Hide the chat window (keeps buffer + session alive).
function M.hide()
  local win = sessions.window()
  if win then
    pcall(vim.api.nvim_win_close, win, false)
    sessions.set_window(nil)
  end
end

--- Refresh the winbar of the chat window (after tab switch).
function M.refresh_winbar()
  local win = sessions.window()
  if win then
    pcall(vim.api.nvim_set_option_value, "winbar", chat_winbar(), { win = win })
  end
end

--- Move cursor to the prompt line and enter insert mode at the end.
function M.focus_prompt()
  local active = sessions.active()
  if not active then
    return
  end
  local win = sessions.window()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local prompt_row = prompt_start_index(active.buf)
  local line = vim.api.nvim_buf_get_lines(active.buf, prompt_row, prompt_row + 1, false)[1] or ""
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { prompt_row + 1, #line })
  vim.cmd("startinsert!")
end

--- Read the user's typed prompt (possibly multiline) from the prompt region,
--- clear it back to a single prompt line, return the text.
--- If the prompt is empty, the buffer is left untouched.
function M.consume_prompt(chat)
  if not vim.api.nvim_buf_is_valid(chat.buf) then
    return ""
  end
  local start = prompt_start_index(chat.buf)
  local total = vim.api.nvim_buf_line_count(chat.buf)
  local lines = vim.api.nvim_buf_get_lines(chat.buf, start, total, false)
  -- Strip the prompt prefix from the first line.
  if lines[1] then
    lines[1] = lines[1]:sub(#PROMPT_PREFIX + 1)
  end
  -- Trim empty trailing lines.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  local text = table.concat(lines, "\n")
  -- Don't clear the prompt if it's empty — preserve the user's partial input.
  if text == "" then
    return ""
  end
  -- Reset to a single empty prompt line.
  vim.api.nvim_buf_set_lines(chat.buf, start, total, false, { PROMPT_PREFIX })
  -- Re-anchor the prompt extmark at the new prompt line.
  vim.api.nvim_buf_clear_namespace(chat.buf, PROMPT_MARK_NS, 0, -1)
  local new_prompt_row = vim.api.nvim_buf_line_count(chat.buf) - 1
  vim.api.nvim_buf_set_extmark(chat.buf, PROMPT_MARK_NS, new_prompt_row, 0, {})
  return text
end

--- Returns true if cursor is within the prompt region.
function M.in_prompt_region(buf)
  local start = prompt_start_index(buf)
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  return cur >= start
end

M.PROMPT_PREFIX = PROMPT_PREFIX
M.NS = NS

return M
