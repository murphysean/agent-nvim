--- Chat UI: a single bottom split that hosts whichever chat buffer is
--- currently active. The buffer holds:
---   1. Streamed chat history (read-only above the prompt marker).
---   2. A "> " prompt region at the bottom (multiline). <C-s> sends.
---
--- Tool-call rendering, two modes selected by the `chat.tool_output` option:
---
---   false (legacy): each tool_call notification appends a single status line
---   ("⏳ Edit: lua/foo.lua") and stashes its line number in
---   chat.tool_lines[toolCallId]. Subsequent tool_call_update notifications
---   rewrite that line with the new icon + title.
---
---   true (default): two lines per call — a stable "Tool Call:" line written
---   when the call starts, plus a "Tool Result:" line appended once the call
---   reaches a terminal status. This keeps the call/result order visible
---   instead of overwriting the request with its own outcome.
---
--- The chat winbar renders tabs for all open chats (e.g. "[1] [2*] [3]") so
--- the user can see and click between them.

local sessions = require("agent-nvim.chat.sessions")
local markdown = require("agent-nvim.chat.markdown")

local M = {}

local NS = vim.api.nvim_create_namespace("acp_chat_ui")
local PROMPT_PREFIX = "[C-s] > "

--- Highlight groups for the chat transcript. Linked (not hard-coded) so the
--- active colorscheme decides the actual colours, and `default = true` so a
--- user's own definition always wins.
---
---   AgentNvimMeta      status lines: spawning / session ready / turn end
---   AgentNvimUser      your prompt echo
---   AgentNvimToolCall  "Tool Call:" lines
---   AgentNvimToolResult "Tool Result:" lines
---   AgentNvimToolError failed tool results
---   AgentNvimSeparator the step separator rule
local CHAT_HL = {
  AgentNvimMeta = { link = "Comment" },
  AgentNvimUser = { link = "Title" },
  AgentNvimToolCall = { link = "Function" },
  AgentNvimToolResult = { link = "Comment" },
  AgentNvimToolError = { link = "DiagnosticError" },
  AgentNvimSeparator = { link = "NonText" },
}

local HL_NS = vim.api.nvim_create_namespace("acp_chat_hl")
local hl_ready = false

--- Define the chat highlight groups once. Called when a chat buffer is made.
local function setup_highlights()
  if hl_ready then
    return
  end
  hl_ready = true
  for name, spec in pairs(CHAT_HL) do
    spec.default = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

--- Highlight buffer rows [row, row + count) with a chat group.
local function hl_rows(buf, row, count, group)
  if not group or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  for r = row, math.min(row + count - 1, last - 1) do
    if r >= 0 then
      vim.api.nvim_buf_set_extmark(buf, HL_NS, r, 0, {
        end_row = r + 1,
        hl_group = group,
      })
    end
  end
end

local STATUS_ICON = {
  pending = "○",
  in_progress = "◐",
  completed = "●",
  failed = "✗",
}

local KIND_ICON = {
  read = "📖",
  edit = "✏️",
  delete = "🗑",
  move = "📦",
  search = "🔍",
  execute = "▶",
  think = "💭",
  fetch = "🌐",
  other = "•",
}

--- Resolve chat display options, honoring per-chat overrides.
function M.opts(chat)
  local cfg = require("agent-nvim").config.chat or {}
  if chat and chat.opts then
    return vim.tbl_extend("force", cfg, chat.opts)
  end
  return cfg
end

--- Record a block boundary. Blocks shift as lines are inserted above them,
--- so we store extmarks (which track through insertions) rather than raw
--- line numbers. The blocks list is ordered by creation time.
function M.add_block(chat, kind, row)
  chat.blocks = chat.blocks or {}
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Anchor the mark to the TOP of the block (left gravity) so lines inserted
  -- below it (as the block grows) don't push the mark down.
  local mark_id = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { right_gravity = false })
  table.insert(chat.blocks, { kind = kind, mark = mark_id })
  return #chat.blocks
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
local PROMPT_MARK_NS = vim.api.nvim_create_namespace("acp_chat_prompt")

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

--- Get the exclusive end row of a block: the start of the next block, or the
--- prompt start if this is the last block. Used so each block is rendered as
--- its own markdown document (see _render_agent_markdown), preventing an
--- unclosed construct in one block from swallowing the highlighting of the
--- blocks that follow it.
local function block_end_row(chat, idx)
  local next_row = block_line(chat, idx + 1)
  if next_row then
    return next_row
  end
  return prompt_start_index(chat.buf)
end

function M.create_buffer(chat_id)
  setup_highlights()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "acp-chat://" .. chat_id)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "acpchat", { buf = buf })
  -- Disable completion in chat buffers — the prompt is for typing to the
  -- agent, not for code completion. These buffer variables are checked by
  -- blink.cmp (vim.b.completion) and nvim-cmp (vim.b.cmp_enabled).
  vim.b[buf].completion = false
  vim.b[buf].cmp_enabled = false

  -- Initial layout: a header line + a blank line + the prompt line.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# acp-chat session " .. chat_id,
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

--- Width of the text area inside the chat window: winwidth() minus the space
--- taken by line numbers and the sign column. Using the raw window width (or
--- the editor's column count) over-counts by textoff, so a rule sized to it
--- wraps onto a second screen line.
local function text_width()
  local win = sessions.window()
  local width
  if win then
    local ok, info = pcall(vim.fn.getwininfo, win)
    if ok and info[1] and info[1].width then
      width = info[1].width - (info[1].textoff or 0)
    else
      width = vim.fn.winwidth(win)
    end
  else
    width = vim.o.columns
  end
  return math.max(8, math.min(math.floor(width), 250))
end

local function separator_width()
  -- Leave one column of slack so a rule never sits flush against the edge.
  return math.max(8, text_width() - 1)
end

local function chat_opts(chat)
  return M.opts(chat)
end

--- True when a line is a rule (only rule characters, optionally indented).
---
--- Lua patterns operate on BYTES, so a character class like "^─+$" cannot match
--- a multi-byte rule — the `+` binds to the last byte only. Strip the rule
--- character and whitespace, then require the remainder to be empty.
---
--- `char` is the configured rule character; a single character may expand to
--- multiple bytes, so it is removed by plain (non-pattern) substitution.
local function is_rule_line(line, char)
  if line == nil or line == "" then
    return false
  end
  char = char or "─"
  if char == "" then
    return false
  end
  return (line:gsub(char, "", nil):gsub("%s", "")) == ""
end

--- True when the nearest non-blank line above the prompt is already a rule.
--- Rules come from several sources (step boundaries, card edges); without this
--- check two of them land back to back and read as noise.
local function prev_line_is_rule(buf, char)
  local plr = prompt_start_index(buf)
  for row = plr - 1, 0, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if line == nil then
      break
    end
    if not line:match("^%s*$") then
      return is_rule_line(line, char)
    end
  end
  return false
end

--- Drop trailing blank lines just above the prompt. Boundaries may have left
--- one behind; removing it keeps the transcript tight and lets a following rule
--- see the real previous line.
local function trim_trailing_blanks(buf)
  local plr = prompt_start_index(buf)
  local row = plr - 1
  while row >= 0 do
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if line and line:match("^%s*$") then
      vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
      row = row - 1
    else
      break
    end
  end
end

--- Draw a full-width rule, highlighting it as a block separator.
---
--- A blank line is inserted AFTER the rule so content that follows is visually
--- separated from the boundary. Skips when the line above is already a rule, so
--- adjacent boundaries (a step separator meeting a card edge) collapse into one.
--- Pass force to override. Returns ok, row (row is nil when collapsed away).
local function insert_rule(chat, force)
  trim_trailing_blanks(chat.buf)
  local opts = chat_opts(chat)
  local char = opts.rule_char
  if char == nil then
    char = "─"
  end
  if char == "" then
    return false, nil
  end
  if not force and prev_line_is_rule(chat.buf, char) then
    return true, nil
  end
  local width = opts.rule_width or 40
  local indent = opts.rule_indent or 2
  local line = string.rep(" ", indent) .. string.rep(char, math.max(1, width))
  local row = M.insert_above_prompt(chat.buf, { line })
  if row then
    hl_rows(chat.buf, row, 1, "AgentNvimSeparator")
    return true, row
  end
  return false, nil
end

--- Emoji prefix helper. When emojis are disabled, returns the (possibly empty)
--- plain marker so lines stay terse.
local function use_emoji(chat)
  return chat_opts(chat).emoji ~= false
end

--- Draw a rule separating one step of the conversation from the next.
---
--- The transcript is grouped by assistant messageId: each round of the agent
--- loop (reasoning, message, tool calls) arrives under one id, and a new id
--- means a new step.
---
--- With tool cards enabled this is a no-op: the card edges already mark where
--- each batch begins and ends, and a step rule on top of them just doubles the
--- rules. It remains useful with tool_cards = false, where nothing else
--- delineates the steps.
---
--- A rule is drawn only when a caller has requested one AND there is already
--- agent/tool content above to separate from — so a brand-new session does not
--- open with a stray rule, and repeated requests at the same point are
--- collapsed into one.
function M.ensure_separator(chat)
  if chat_opts(chat).tool_cards ~= false then
    chat.needs_sep = false
    return false
  end
  if not chat.needs_sep then
    return false
  end

  -- Anything above that is not the user's own prompt or a status line.
  local has_content = false
  for _, b in ipairs(chat.blocks or {}) do
    if b.kind ~= "user" and b.kind ~= "status" then
      has_content = true
      break
    end
  end
  if not has_content then
    chat.needs_sep = false
    return false
  end

  -- Collapse repeated requests with nothing added in between.
  if chat.last_sep_at and chat.last_sep_at == #chat.blocks then
    chat.needs_sep = false
    return false
  end

  chat.needs_sep = false
  if (chat_opts(chat).step_separator or "─") == "" then
    return false
  end

  -- insert_rule() collapses against an existing rule and trims stray blanks.
  local ok, row = insert_rule(chat)
  if not ok then
    return false
  end
  if row then
    M.add_block(chat, "separator", row)
  end
  chat.last_sep_at = #chat.blocks
  return true
end

--- Request a separator before the next content is added.
function M.request_separator(chat)
  chat.needs_sep = true
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
--- header line and make it the open line. The agent message body is raw
--- markdown, so the prefix is dropped from the open line and the whole block
--- is highlighted by the markdown renderer.
local AGENT_PREFIX = "🤖 "
local THOUGHT_PREFIX = "💭 "

local function stream_prefix(chat, kind)
  local opts = chat_opts(chat)
  -- When markdown rendering is on, the message body is parsed as raw markdown,
  -- so prepending an emoji prefix would corrupt headings/code. No prefix then.
  if opts.markdown ~= false then
    return ""
  end
  if kind == "agent_thought_chunk" then
    return opts.emoji ~= false and THOUGHT_PREFIX or ""
  end
  return opts.emoji ~= false and AGENT_PREFIX or ""
end

--- Set the chat window's conceal options so markdown delimiters (**, `, ...)
--- hide when markdown rendering is on.
function M._apply_conceal(win, chat)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local level = M.opts(chat).markdown == false and 0 or 2
  pcall(vim.api.nvim_set_option_value, "conceallevel", level, { win = win })
  pcall(vim.api.nvim_set_option_value, "concealcursor", "nc", { win = win })
end

--- Re-render a streamed agent block's markdown, if enabled. The block spans
--- rows [block_line, prompt_start). Throttled so we don't re-parse on every
--- tiny chunk.
function M._render_agent_markdown(chat, block_idx)
  local opts = chat_opts(chat)
  if opts.markdown == false then
    return
  end
  if not chat.blocks or not block_idx then
    return
  end
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local start_row = block_line(chat, block_idx)
  if not start_row then
    return
  end
  -- Render ONLY this block's rows as its own markdown document. Rendering from
  -- the block start all the way to the prompt would span multiple blocks; an
  -- unclosed code fence (or other construct) in an earlier block would then
  -- swallow the highlighting of every block after it.
  local end_row = block_end_row(chat, block_idx)
  if end_row <= start_row then
    return
  end
  markdown.apply(buf, start_row, end_row)
end

--- In markdown mode, rewrite the open agent block with the accumulated message.
--- The block is a single contiguous region [block_line, prompt_start); we
--- replace its current lines with the message split into lines.
function M._rewrite_agent_block(chat)
  local block_idx = chat.stream_block_idx
  if not block_idx then
    return
  end
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local start_row = block_line(chat, block_idx)
  if not start_row then
    return
  end
  local end_row = prompt_start_index(buf)
  if start_row >= end_row then
    return
  end
  local lines = vim.split(chat.stream_buffer or "", "\n", { plain = true })
  -- A trailing newline yields a trailing empty line; drop it so the message
  -- ends cleanly at the prompt / next block.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, lines)
end

--- Throttle live markdown re-rendering while text keeps streaming.
function M._schedule_markdown_render(chat)
  local block_idx = chat.stream_block_idx
  if not block_idx or chat._md_timer then
    return
  end
  local now = vim.loop.hrtime() / 1e6 -- ms
  if (chat._md_last or 0) > now - 150 then
    return
  end
  chat._md_last = now
  chat._md_timer = vim.fn.timer_start(120, function()
    chat._md_timer = nil
    -- Skip if the stream moved on (a fresh block or the final render).
    if chat.stream_block_idx == block_idx then
      M._render_agent_markdown(chat, block_idx)
    end
  end)
end

function M.stream_text(chat, kind, text, message_id)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- A step boundary: a new assistant messageId means the agent started
  -- another round of its loop (fresh reasoning + a new batch of tool calls).
  -- Close any open tool card so each batch gets its own.
  --
  -- Tracked separately from stream_msg_id because end_stream() clears that
  -- whenever a tool call interrupts the stream, so it would be nil exactly
  -- when we need it (a thought arriving after tool calls).
  if message_id ~= nil and chat.last_msg_id ~= nil and chat.last_msg_id ~= message_id then
    if chat.card then
      chat.card = nil
      local ok, row = insert_rule(chat)
      if ok and row then
        M.add_block(chat, "card_bottom", row)
      end
    end
    M.request_separator(chat)
    M.ensure_separator(chat)
  end
  if message_id ~= nil then
    chat.last_msg_id = message_id
  end

  -- A new message starts when the stream kind OR the message id changes.
  if chat.stream_kind ~= kind or (message_id ~= nil and chat.stream_msg_id ~= message_id) then
    -- Finalize the previous message's markdown before starting a new block.
    if chat.stream_kind ~= nil and chat.stream_kind ~= "agent_thought_chunk" then
      M._render_agent_markdown(chat, chat.stream_block_idx)
    end
    -- Start a new streamed block.
    local row = M.insert_above_prompt(buf, { "" })
    chat.stream_kind = kind
    chat.stream_msg_id = message_id
    chat.stream_line = prompt_start_index(buf) - 1
    chat.stream_buffer = ""
    chat.stream_prefix = stream_prefix(chat, kind)
    chat.stream_block_idx = nil
    if row then
      local block_type = kind == "agent_thought_chunk" and "thought" or "agent"
      chat.stream_block_idx = M.add_block(chat, block_type, row)
    end
  end

  if text == "" then
    -- A boundary-only chunk (new messageId, no text): nothing to append.
    return
  end

  if chat_opts(chat).markdown ~= false and kind ~= "agent_thought_chunk" then
    -- Markdown mode: accumulate the WHOLE message and rewrite the block region
    -- in place (throttled). This keeps code fences and structure intact across
    -- arbitrary chunk boundaries.
    --
    -- Text goes in raw; markdown is applied by extmarks on top of it. When
    -- live_markdown is disabled we skip the in-flight highlight pass entirely
    -- and let end_stream() apply it once, when the message is complete.
    chat.stream_buffer = (chat.stream_buffer or "") .. text
    M._rewrite_agent_block(chat)
    if chat_opts(chat).live_markdown ~= false then
      M._schedule_markdown_render(chat)
    end
    return
  end

  -- Non-markdown mode: incremental per-line streaming with emoji prefix.
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
  if chat._md_timer then
    vim.fn.timer_stop(chat._md_timer)
    chat._md_timer = nil
  end
  -- Finalize markdown for the just-finished agent block.
  if chat.stream_kind ~= "agent_thought_chunk" then
    M._render_agent_markdown(chat, chat.stream_block_idx)
  end
  chat.stream_kind = nil
  chat.stream_line = nil
  chat.stream_buffer = nil
  chat.stream_block_idx = nil
  chat.stream_msg_id = nil
end

--- Keys worth surfacing in an argument summary, in display order. Anything
--- else is appended afterwards only if it is a short scalar.
local ARG_KEYS = {
  "path",
  "file",
  "query",
  "pattern",
  "command",
  "url",
  "uri",
  "name",
  "source",
  "line",
}

--- Args holding source text rather than an identifier. They are never worth
--- one line, so they are skipped when summarizing.
local ARG_SKIP = {
  old_string = true,
  new_string = true,
  content = true,
  text = true,
  new_text = true,
  old_text = true,
  lines = true,
  edits = true,
  _meta = true,
}

--- Max characters for one summarized value; summaries must never wrap.
local MAX_VALUE_CHARS = 44

--- Flatten a value onto a single clipped line. Tool results routinely contain
--- whole files, so take the first line before clipping.
local function clip(value, limit)
  local text = tostring(value)
  local nl = text:find("\n", 1, true)
  if nl then
    text = text:sub(1, nl - 1)
  end
  text = vim.trim((text:gsub("%s+", " ")))
  limit = limit or MAX_VALUE_CHARS
  if vim.fn.strchars(text) > limit then
    text = vim.fn.strcharpart(text, 0, limit - 1) .. "…"
  end
  return text
end

--- Pull a displayable scalar out of a JSON value, or nil when it is a
--- structure (which has no meaningful one-line form).
local function scalar(value)
  if type(value) == "string" then
    return value ~= "" and value or nil
  elseif type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  end
  return nil
end

--- Summarize a tool call's raw input as "key: value, …", preferring the keys
--- that identify what the call touches so long payloads stay readable.
local function format_args(raw_input)
  if type(raw_input) ~= "table" then
    return nil
  end

  local parts, seen = {}, {}

  -- read_file's range reads better as one "lines: 12-40" than as two keys.
  local from, to = scalar(raw_input.start_line), scalar(raw_input.end_line)
  local range_text
  if from or to then
    seen.start_line, seen.end_line = true, true
    range_text = "lines: " .. (from and to and (from .. "-" .. to) or from or to)
  end

  local function add(key, value, limit)
    if seen[key] then
      return
    end
    local text = scalar(value)
    if not text then
      return
    end
    seen[key] = true
    parts[#parts + 1] = string.format("%s: %s", key, clip(text, limit))
  end

  for _, key in ipairs(ARG_KEYS) do
    add(key, raw_input[key])
  end

  -- Keep the range next to the path it applies to, mirroring how the caller
  -- spells the request ("main.rs, lines: 3-5").
  if range_text and #parts > 0 then
    table.insert(parts, 2, range_text)
  elseif range_text then
    table.insert(parts, range_text)
  end

  -- Remaining scalar args, sorted so the line is stable across updates.
  local rest = {}
  for key in pairs(raw_input) do
    if not seen[key] and not ARG_SKIP[key] then
      rest[#rest + 1] = key
    end
  end
  table.sort(rest)
  for _, key in ipairs(rest) do
    if #parts >= 3 then
      break
    end
    add(key, raw_input[key], 24)
  end

  if #parts == 0 then
    return nil
  end
  return table.concat(parts, ", ")
end

--- First text block of a tool-call content list.
local function content_text(update)
  for _, block in ipairs(update.content or {}) do
    if block.type == "content" and type(block.content) == "table" and block.content.type == "text" then
      return block.content.text
    end
  end
  return nil
end

--- Path of the first diff block, when the call reported a file modification.
local function content_diff_path(update)
  for _, block in ipairs(update.content or {}) do
    if block.type == "diff" and block.path then
      return block.path
    end
  end
  return nil
end

--- Resolve the tool's short name. goose puts the raw name (e.g. "read_file")
--- under _meta.goose.toolCall.toolName; otherwise reverse the human title
--- ("Read File · main.rs" -> "read_file").
---
--- Returns nil when the update carries no naming information at all — many
--- tool_call_update payloads contain only a status, and the caller must fall
--- back to the name captured from the opening tool_call.
local function tool_name(update)
  local meta = update._meta
  local raw = meta and meta.goose and meta.goose.toolCall and meta.goose.toolCall.toolName
  if type(raw) == "string" and raw ~= "" then
    return raw:match("__(.+)$") or raw
  end
  local title = update.title
  if type(title) ~= "string" or title == "" then
    return nil
  end
  local base = vim.trim(title:match("^(.-)%s+·") or title)
  if base == "" then
    return nil
  end
  return (base:gsub("%s+", "_"):lower())
end

--- Parenthetical summary for the result line. Prefers structured output when
--- the agent reports it, then file diffs, then the first text block.
local function format_result(update)
  local status = update.status or "completed"
  if status == "failed" then
    local err = content_text(update) or scalar(update.rawOutput)
    return err and ("failed: " .. clip(err)) or "failed"
  end

  -- Structured output is the tool's own machine-readable summary.
  local raw = update.rawOutput
  if type(raw) == "string" and raw ~= "" then
    return "result: " .. clip(raw)
  elseif type(raw) == "table" then
    -- Show the human-readable payload when there is one, so a JSON blob's
    -- escaped newlines do not dominate the line.
    for _, key in ipairs({ "output", "stdout", "text" }) do
      local v = raw[key]
      if type(v) == "string" and vim.trim(v) ~= "" then
        return "result: " .. clip(v)
      end
    end
    local keys = {}
    for key in pairs(raw) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      if #parts >= 3 then
        break
      end
      local text = scalar(raw[key])
      if text then
        parts[#parts + 1] = string.format("%s: %s", key, clip(text, 30))
      end
    end
    if #parts > 0 then
      return "result: " .. table.concat(parts, ", ")
    end
  end

  local path = content_diff_path(update)
  if path then
    return "diff: " .. clip(path)
  end

  local text = content_text(update)
  if text and vim.trim(text) ~= "" then
    return "result: " .. clip(text)
  end

  return status
end

--- The stable request line, e.g. "  ▸ read_file (path: main.rs, lines: 3)".
--- The arrow points away from the agent, marking the outgoing call. In plain
--- (non-card) mode a "Tool Call:" label is used instead.
local function format_call_line(chat, name, update)
  local args = format_args(update.rawInput)
  local body = args and string.format("%s (%s)", name, args) or name
  local opts = chat_opts(chat)
  if opts.tool_cards == false then
    return "Tool Call: " .. body
  end
  local arrow = opts.card_arrows ~= false and "▸ " or ""
  if not use_emoji(chat) then
    return "  " .. arrow .. body
  end
  local icon = KIND_ICON[update.kind or "other"] or KIND_ICON.other
  return string.format("  %s%s %s", arrow, icon, body)
end

--- Clip a single line to `limit` characters (no newline handling).
local function clip_line(text, limit)
  if vim.fn.strchars(text) > limit then
    return vim.fn.strcharpart(text, 0, limit - 1) .. "…"
  end
  return text
end

--- Best displayable body for a result's preview block.
---
--- Structured output is preferred only for its human-readable payload: the raw
--- structured form is a JSON blob whose newlines are escaped, so it renders as
--- one unreadable line. The tool's own text body generally reads better and is
--- usually the richer of the two.
local function result_body(update)
  local raw = update.rawOutput
  if type(raw) == "table" then
    for _, key in ipairs({ "output", "stdout", "text" }) do
      local v = raw[key]
      if type(v) == "string" and vim.trim(v) ~= "" then
        return v
      end
    end
  end
  local text = content_text(update)
  if text and vim.trim(text) ~= "" then
    return text
  end
  if type(raw) == "string" and vim.trim(raw) ~= "" then
    return raw
  end
  return nil
end

--- Preview lines shown inside a card: up to `max` lines of the result body,
--- indented and clipped to the window so they never wrap, followed by an
--- elision marker when the body was longer.
local function preview_lines(update, max)
  local body = result_body(update)
  if not body then
    return {}
  end
  local raw = vim.split((body:gsub("%s+$", "")), "\n", { plain = true })
  local avail = math.max(20, text_width() - 6)
  local out = {}
  for i = 1, math.min(#raw, max) do
    out[#out + 1] = "    " .. clip_line(vim.trim(raw[i], " "), avail)
  end
  if #raw > max then
    local more = #raw - max
    out[#out + 1] = string.format("    … (%d more line%s)", more, more == 1 and "" or "s")
  end
  return out
end

--- The closing line of a card, e.g. "  ◂ read_file (result: 3 lines read)".
--- The arrow points back toward the agent, marking the returning result. In
--- plain (non-card) mode a "Tool Result:" label is used instead.
--- The summary is clipped to the window so the line never wraps.
local function format_close_line(chat, name, update, summary)
  local opts = chat_opts(chat)
  if opts.tool_cards == false then
    return string.format("Tool Result: %s (%s)", name, clip_line(summary, math.max(16, text_width() - 16)))
  end
  local arrow = opts.card_arrows ~= false and "◂ " or ""
  local prefix = ""
  if use_emoji(chat) then
    prefix = (STATUS_ICON[update.status or "completed"] or "?") .. " "
  end
  local head = string.format("  %s%s%s", prefix, arrow, name)
  local avail = math.max(16, text_width() - vim.fn.strchars(head) - 3)
  return string.format("%s (%s)", head, clip_line(summary, avail))
end

local function format_tool_label(chat, update)
  -- ACP tool_call may include title, kind, and locations.
  local kind = update.kind or "other"
  local title = update.title or "tool call"
  -- Prefer location path or first diff path if title is generic. goose already
  -- folds the path into the title ("Read File · main.rs"), so only append it
  -- when the title does not already carry it.
  local path
  if update.locations and #update.locations > 0 and update.locations[1].path then
    path = update.locations[1].path
  else
    path = content_diff_path(update)
  end
  if path and not title:find(path, 1, true) then
    title = title .. " " .. path
  end

  if not use_emoji(chat) then
    -- Terse plain line: a single status glyph followed by the title.
    local sicon = STATUS_ICON[update.status or "pending"] or "?"
    return string.format("%s %s", sicon, title)
  end
  local kicon = KIND_ICON[kind] or KIND_ICON.other
  local sicon = STATUS_ICON[update.status or "pending"] or "?"
  return string.format("%s %s %s", sicon, kicon, title)
end

--- Render a tool call as part of a bordered card:
---
---   ─────────────────────────────────────────────
---     ▸ read_file (path: src/main.rs, lines: 12-40)
---     ▸ run (command: cargo test)
---     ◂ run (result: exit_code: 0, stdout: ok)
---         test result: ok. 412 passed
---     ◂ read_file (result: 3 lines read)
---         File: src/main.rs (562 lines total)
---   ─────────────────────────────────────────────
---
--- Calls are grouped: the opening rule is drawn when a call starts and no card
--- is already open, so calls issued together (one batch of the agent's loop)
--- share a card. Results append inside the card as they arrive, and the closing
--- rule is drawn once every call in the group has finished — which also marks
--- the block's full extent, for editing it after the fact.
local function render_tool_call_lines(chat, update)
  local buf = chat.buf
  local id = update.toolCallId
  if not id then
    return
  end
  local opts = chat_opts(chat)
  local cards = opts.tool_cards ~= false

  chat.tool_lines = chat.tool_lines or {}
  local entry = chat.tool_lines[id]
  local status = update.status or "pending"

  if not entry then
    entry = { call_line = nil, close_line = nil }
    chat.tool_lines[id] = entry
  end

  -- goose's tool_call_update carries only the *changed* fields. The args and
  -- the title typically arrive ONCE, on the opening tool_call, which may be
  -- followed by bare status-only updates — so cache everything needed to draw
  -- the card later rather than re-deriving it from each update.
  if update.rawInput ~= nil then
    entry.rawInput = update.rawInput
  end
  if update.kind ~= nil then
    entry.kind = update.kind
  end
  -- tool_name() returns nil for status-only updates, so the label captured
  -- from the opening tool_call survives rather than degrading to "tool".
  entry.name = tool_name(update) or entry.name or "tool"
  local name = entry.name

  -- Draw from the cached view of the call, not just this update: the args may
  -- have arrived several updates ago.
  local view = {
    rawInput = entry.rawInput,
    kind = entry.kind,
  }

  -- Defer pure 'pending' renders: an in_progress update usually follows
  -- immediately, which is when the call actually starts.
  if not entry.call_line and status ~= "pending" then
    M.ensure_separator(chat)
    if cards then
      -- Open the card if this is the first call in the current batch. Close
      -- any open content/turn card first: the agent's prose up to this point
      -- is its own framed block, and the batch belongs in its own card.
      if not chat.card then
        M.close_card(chat)
        chat.card = { ids = {} }
        insert_rule(chat)
      end
      chat.card.ids[id] = true
    end
    trim_trailing_blanks(buf)
    entry.call_line = M.insert_above_prompt(buf, { format_call_line(chat, name, view) }) or 0
    hl_rows(buf, entry.call_line, 1, "AgentNvimToolCall")
    M.add_block(chat, "tool", entry.call_line)
  end

  local terminal = status == "completed" or status == "failed"
  if not terminal then
    return
  end
  if entry.close_line then
    -- Already reported (duplicate terminal update).
    return
  end

  local is_err = status == "failed"
  local previews = is_err and {} or preview_lines(update, opts.tool_preview_lines or 3)
  local summary = format_result(update)

  if not cards then
    -- Plain mode: a single result line, no card rules.
    local row = M.insert_above_prompt(buf, { format_close_line(chat, name, update, summary) }) or 0
    entry.close_line = row
    hl_rows(buf, row, 1, is_err and "AgentNvimToolError" or "AgentNvimToolResult")
    M.add_block(chat, "tool_result", row)
    return
  end

  -- Inside a card: the result line, then its preview lines.
  local block = { format_close_line(chat, name, update, summary) }
  for _, p in ipairs(previews) do
    block[#block + 1] = p
  end
  local row = M.insert_above_prompt(buf, block)
  if row then
    entry.close_line = row
    hl_rows(buf, row, 1, is_err and "AgentNvimToolError" or "AgentNvimToolResult")
    if #previews > 0 then
      hl_rows(buf, row + 1, #previews, "AgentNvimToolResult")
    end
    M.add_block(chat, "tool_result", row)
  end

  -- Close the card once every call in the batch has reported.
  if chat.card and chat.card.ids[id] then
    chat.card.ids[id] = nil
    local remaining = 0
    for _ in pairs(chat.card.ids) do
      remaining = remaining + 1
    end
    if remaining == 0 then
      chat.card = nil
      local ok, last_row = insert_rule(chat)
      if ok and last_row then
        M.add_block(chat, "card_bottom", last_row)
      end
    end
  end
end

--- Render or update a tool_call card.
function M.render_tool_call(chat, update)
  M.end_stream(chat)
  if chat_opts(chat).tool_output ~= false then
    return render_tool_call_lines(chat, update)
  end

  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local id = update.toolCallId
  if not id then
    return
  end

  chat.tool_lines = chat.tool_lines or {}
  local label = format_tool_label(chat, update)

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
    label = format_tool_label(chat, entry.last_update)
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
  local header = use_emoji(chat) and "📋 Plan:" or "Plan:"
  local lines = { header }
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
--- Append the user's prompt as the opening content of the turn's card.
---
--- The turn card spans the whole exchange: its top rule is drawn here and its
--- bottom rule when the turn ends, so the agent's reply (reasoning, message,
--- tool cards) is framed together with the prompt that caused it.
---
--- The prompt itself is marked with a left gutter bar. That distinguishes it
--- from the agent's prose at a glance without adding separator lines, and the
--- bar sits at a fixed column so it survives a window resize.
function M.append_user_prompt(chat, text)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Close any card left open by a previous turn.
  M.close_card(chat)
  insert_rule(chat)

  local gutter = chat_opts(chat).prompt_gutter
  if gutter == nil then
    gutter = "│"
  end
  local bar = gutter == "" and "" or (gutter .. " ")
  local header = use_emoji(chat) and " you:" or "you:"
  local lines = { bar .. header }
  for _, t in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, bar .. t)
  end
  local row = M.insert_above_prompt(buf, lines)
  if row then
    hl_rows(buf, row, #lines, "AgentNvimUser")
    M.add_block(chat, "user", row)
  end
  -- The turn stays open until the turn-end event draws its closing rule.
  chat.open_card = { kind = "turn" }
end

--- Close the currently open section/card by drawing its bottom rule.
--- Safe to call when nothing is open.
function M.close_card(chat)
  if not chat.open_card then
    return false
  end
  chat.open_card = nil
  local ok, row = insert_rule(chat)
  if ok and row then
    M.add_block(chat, "card_bottom", row)
    return true
  end
  return false
end

--- Close the turn: draw the closing rule unless one is already the last line.
---
--- The turn's card may have been closed earlier (the first tool batch closes it
--- so the batch gets its own card), so this cannot rely on open_card — it has
--- to guarantee the turn ends with a rule regardless of what came last.
function M.end_turn(chat)
  chat.open_card = nil
  if chat.card then
    chat.card = nil
  end
  local ok, row = insert_rule(chat)
  if ok and row then
    M.add_block(chat, "turn_bottom", row)
    return true
  end
  return false
end

--- Append a status / system line.
function M.append_status(chat, text)
  M.end_stream(chat)
  local buf = chat.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local prefix = use_emoji(chat) and "ℹ " or ""
  local row = M.insert_above_prompt(buf, { prefix .. text })
  if row then
    hl_rows(buf, row, 1, "AgentNvimMeta")
    M.add_block(chat, "status", row)
  end
end

local function chat_winbar()
  local list = sessions.list()
  local active = sessions.active()
  if #list == 0 then
    return "%#WinBar# acp-chat %*"
  end
  local parts = { "%#WinBar# acp-chat " }
  for _, c in ipairs(list) do
    if not c then
      -- skip stale entry
    elseif active and c.id == active.id then
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
  sessions.clear_window()
  local win = sessions.window()
  if win then
    vim.api.nvim_win_set_buf(win, active.buf)
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_set_option_value, "winbar", chat_winbar(), { win = win })
    M._apply_conceal(win, active)
    return
  end
  -- Open a new bottom split (15 lines tall by default).
  vim.cmd("botright " .. (require("agent-nvim").config.chat_height or 15) .. "split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, active.buf)
  pcall(vim.api.nvim_set_option_value, "winbar", chat_winbar(), { win = win })
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
  M._apply_conceal(win, active)
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
