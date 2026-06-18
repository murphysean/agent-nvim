--- AI assist commands via sampling/createMessage.
--- Provides <leader>ae (explain), <leader>af (fix), <leader>ar (refactor), <leader>av (review).
--- Each gathers context, renders a prompt template, fires sampling, and handles the result.

local M = {}

local ns = vim.api.nvim_create_namespace("mcp_nvim_assist")

--- Get the visual selection text and range, or fall back to current function/30 lines.
---@return string text The selected/contextual code
---@return number start_row 0-indexed start row
---@return number end_row 0-indexed end row (exclusive)
local function get_selection_or_context(buf)
  -- Check for visual selection marks
  local start_mark = vim.api.nvim_buf_get_mark(buf, "<")
  local end_mark = vim.api.nvim_buf_get_mark(buf, ">")

  if start_mark[1] > 0 and end_mark[1] > 0 and start_mark[1] <= end_mark[1] then
    local lines = vim.api.nvim_buf_get_lines(buf, start_mark[1] - 1, end_mark[1], false)
    return table.concat(lines, "\n"), start_mark[1] - 1, end_mark[1]
  end

  -- Fall back to ~30 lines around cursor
  local cursor = vim.api.nvim_win_get_cursor(0)
  local total = vim.api.nvim_buf_line_count(buf)
  local start_l = math.max(0, cursor[1] - 16)
  local end_l = math.min(total, cursor[1] + 15)
  local lines = vim.api.nvim_buf_get_lines(buf, start_l, end_l, false)
  return table.concat(lines, "\n"), start_l, end_l
end

--- Fire an assist request with the given template and context overrides.
--- Routes through the active backend (MCP sampling or one-shot ACP) — see
--- assist_backend.lua for selection rules.
---@param template_name string
---@param ctx_overrides table Additional context key/values
---@param callback fun(text: string|nil, err: string|nil)
local function fire_sampling(template_name, ctx_overrides, callback)
  local context_mod = require("mcp-nvim.prompts.context")
  local templates = require("mcp-nvim.prompts.template_engine")
  local backend = require("mcp-nvim.assist_backend")

  local ctx = context_mod.gather(ctx_overrides)
  for k, v in pairs(ctx_overrides) do
    ctx[k] = v
  end

  local system, err = templates.load_and_render(template_name, ctx)
  if not system then
    callback(nil, "Template error: " .. (err or "unknown"))
    return
  end

  local user_text = "Perform the task described in your instructions. Return only the requested output."

  backend.send(system, user_text, function(text, send_err)
    vim.schedule(function()
      if send_err then
        callback(nil, send_err)
        return
      end
      text = text or ""
      -- Strip markdown fences if wrapping the whole response.
      text = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
      callback(text, nil)
    end)
  end)
end

--- Show text in a new tab as a scratch markdown buffer.
--- Used for both explain and review output.
---@param title string Buffer name / tab label
---@param text string Markdown content
local function show_scratch_tab(title, text)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, title)

  -- q closes the tab and returns to previous
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, silent = true })
end

--- Show virtual text while waiting.
local function show_working(buf, row, msg)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { msg or "-- working...", "Comment" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

local function clear_working(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

---------------------------------------------------------------------------
-- EXPLAIN
---------------------------------------------------------------------------

function M.explain()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local selection = get_selection_or_context(buf)

  show_working(buf, cursor[1] - 1, "-- explaining...")

  fire_sampling("explain", {
    mode = "explain",
    selection = selection,
  }, function(text, err)
    clear_working(buf)
    if err then
      vim.notify("Explain error: " .. err, vim.log.levels.ERROR)
      return
    end
    if not text or text == "" then
      vim.notify("Explain returned empty", vim.log.levels.WARN)
      return
    end
    show_scratch_tab("AI Explain", text)
  end)
end

---------------------------------------------------------------------------
-- FIX
---------------------------------------------------------------------------

function M.fix()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  -- Check if there are diagnostics to fix
  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    vim.notify("No diagnostics to fix", vim.log.levels.INFO)
    return
  end

  show_working(buf, cursor[1] - 1, "-- fixing...")

  fire_sampling("fix", {
    mode = "fix",
    selection = "",
  }, function(text, err)
    clear_working(buf)
    if err then
      vim.notify("Fix error: " .. err, vim.log.levels.ERROR)
      return
    end
    if not text or text == "" then
      vim.notify("Fix returned empty", vim.log.levels.WARN)
      return
    end

    -- The fix returns code for the affected region.
    -- We need to figure out what to replace. Strategy:
    -- Find the diagnostic range and replace those lines.
    local diag_lines = {}
    for _, d in ipairs(diagnostics) do
      for l = d.lnum, (d.end_lnum or d.lnum) do
        diag_lines[l] = true
      end
    end

    -- Find contiguous range
    local sorted = {}
    for l in pairs(diag_lines) do
      table.insert(sorted, l)
    end
    table.sort(sorted)

    local start_row, end_row
    if #sorted > 0 then
      -- Expand to include context (5 lines padding)
      start_row = math.max(0, sorted[1] - 5)
      end_row = math.min(vim.api.nvim_buf_line_count(buf), sorted[#sorted] + 6)
    else
      start_row = math.max(0, cursor[1] - 16)
      end_row = math.min(vim.api.nvim_buf_line_count(buf), cursor[1] + 15)
    end

    -- Replace the region
    local new_lines = vim.split(text, "\n", { plain = true })
    -- Strip leading/trailing blank lines
    while #new_lines > 0 and new_lines[1]:match("^%s*$") do
      table.remove(new_lines, 1)
    end
    while #new_lines > 0 and new_lines[#new_lines]:match("^%s*$") do
      table.remove(new_lines)
    end

    vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, new_lines)
    vim.notify(string.format("Fix applied (%d lines replaced)", #new_lines), vim.log.levels.INFO)
  end)
end

---------------------------------------------------------------------------
-- REFACTOR
---------------------------------------------------------------------------

function M.refactor()
  local buf = vim.api.nvim_get_current_buf()
  local selection, start_row, end_row = get_selection_or_context(buf)

  vim.ui.input({ prompt = "Refactor instruction: " }, function(input)
    if not input or input == "" then
      return
    end

    show_working(buf, start_row, "-- refactoring...")

    fire_sampling("refactor", {
      mode = "refactor",
      selection = selection,
      instructions = input,
    }, function(text, err)
      clear_working(buf)
      if err then
        vim.notify("Refactor error: " .. err, vim.log.levels.ERROR)
        return
      end
      if not text or text == "" then
        vim.notify("Refactor returned empty", vim.log.levels.WARN)
        return
      end

      -- Check if there's an IMPORTS section
      local imports_block = ""
      local code_block = text
      if text:find("^%-%- IMPORTS:") then
        local parts = vim.split(text, "\n\n", { plain = true })
        if #parts >= 2 then
          imports_block = parts[1]:gsub("^%-%- IMPORTS:\n?", "")
          code_block = table.concat(vim.list_slice(parts, 2), "\n\n")
        end
      end

      -- Replace the selection with the refactored code
      local new_lines = vim.split(code_block, "\n", { plain = true })
      -- Strip leading/trailing blank lines
      while #new_lines > 0 and new_lines[1]:match("^%s*$") do
        table.remove(new_lines, 1)
      end
      while #new_lines > 0 and new_lines[#new_lines]:match("^%s*$") do
        table.remove(new_lines)
      end

      vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, new_lines)

      -- If there are imports to add, prepend them at the top of the file
      if imports_block ~= "" then
        local import_lines = vim.split(imports_block, "\n", { plain = true })
        table.insert(import_lines, "")
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, import_lines)
        vim.notify(string.format("Refactored (%d lines) + added imports", #new_lines), vim.log.levels.INFO)
      else
        vim.notify(string.format("Refactored (%d lines replaced)", #new_lines), vim.log.levels.INFO)
      end
    end)
  end)
end

---------------------------------------------------------------------------
-- REVIEW
---------------------------------------------------------------------------

function M.review()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local selection = get_selection_or_context(buf)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")

  show_working(buf, cursor[1] - 1, "-- reviewing...")

  fire_sampling("review", {
    mode = "review",
    selection = selection,
  }, function(text, err)
    clear_working(buf)
    if err then
      vim.notify("Review error: " .. err, vim.log.levels.ERROR)
      return
    end
    if not text or text == "" then
      vim.notify("Review returned empty", vim.log.levels.WARN)
      return
    end
    show_scratch_tab(string.format("[AI Review] %s", filename), text)
  end)
end

return M
