local M = {}

local ns = vim.api.nvim_create_namespace("mcp_review")

local pending_review = nil

local function setup_highlights()
  local ok, base46_colors = pcall(require, "base46.colors")
  local palette_ok, palette = pcall(function()
    return require("base46").get_theme_tb("base_30")
  end)

  if ok and palette_ok and palette then
    local mix = base46_colors.mix
    local green = palette.green or "#a3be8c"
    local vibrant_green = palette.vibrant_green or green
    local red = palette.red or "#cc6666"
    local baby_pink = palette.baby_pink or red
    local grey = palette.grey or "#888888"
    local bg = palette.black or "#1e1e1e"

    vim.api.nvim_set_hl(0, "McpReviewAdd", { bg = mix(green, bg, 80), fg = green })
    vim.api.nvim_set_hl(0, "McpReviewAddEmph", { bg = mix(green, bg, 65), fg = vibrant_green, bold = true })
    vim.api.nvim_set_hl(0, "McpReviewDel", { bg = mix(red, bg, 80) })
    vim.api.nvim_set_hl(0, "McpReviewDelEmph", { bg = mix(red, bg, 65), fg = baby_pink, bold = true })
    vim.api.nvim_set_hl(0, "McpReviewDelText", { fg = red })
    vim.api.nvim_set_hl(0, "McpReviewInfo", { fg = grey, italic = true })
    vim.api.nvim_set_hl(0, "McpReviewContext", { fg = mix(grey, bg, 50) })
  else
    vim.api.nvim_set_hl(0, "McpReviewAdd", { bg = "#1a3a1a", fg = "#a3be8c", default = true })
    vim.api.nvim_set_hl(0, "McpReviewAddEmph", { bg = "#2e5c2e", fg = "#b5cea8", bold = true, default = true })
    vim.api.nvim_set_hl(0, "McpReviewDel", { bg = "#3a1a1a", default = true })
    vim.api.nvim_set_hl(0, "McpReviewDelEmph", { bg = "#5a2d2d", fg = "#e8a3a3", bold = true, default = true })
    vim.api.nvim_set_hl(0, "McpReviewDelText", { fg = "#cc6666", default = true })
    vim.api.nvim_set_hl(0, "McpReviewInfo", { fg = "#888888", italic = true, default = true })
    vim.api.nvim_set_hl(0, "McpReviewContext", { fg = "#666666", default = true })
  end
end

setup_highlights()

local function intra_line_chunks(line, old_line, hl_base, hl_emph)
  if not old_line then
    return { { line, hl_emph } }
  end

  local min_len = math.min(#line, #old_line)
  local prefix_end = 0
  for i = 1, min_len do
    if line:sub(i, i) == old_line:sub(i, i) then
      prefix_end = i
    else
      break
    end
  end

  local suffix_start_line = #line + 1
  local suffix_start_old = #old_line + 1
  for i = 0, min_len - prefix_end - 1 do
    if line:sub(#line - i, #line - i) == old_line:sub(#old_line - i, #old_line - i) then
      suffix_start_line = #line - i
      suffix_start_old = #old_line - i
    else
      break
    end
  end

  if prefix_end >= suffix_start_line - 1 then
    return { { line, hl_base } }
  end

  local chunks = {}
  if prefix_end > 0 then
    table.insert(chunks, { line:sub(1, prefix_end), hl_base })
  end
  table.insert(chunks, { line:sub(prefix_end + 1, suffix_start_line - 1), hl_emph })
  if suffix_start_line <= #line then
    table.insert(chunks, { line:sub(suffix_start_line), hl_base })
  end
  return chunks
end

local function wrap_chunks(chunks, width)
  if width <= 0 then
    return { chunks }
  end
  local rows = {}
  local cur_row = {}
  local col = 0
  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    while #text > 0 do
      local remaining = width - col
      if remaining <= 0 then
        table.insert(rows, cur_row)
        cur_row = {}
        col = 0
        remaining = width
      end
      if #text <= remaining then
        table.insert(cur_row, { text, hl })
        col = col + #text
        text = ""
      else
        table.insert(cur_row, { text:sub(1, remaining), hl })
        text = text:sub(remaining + 1)
        table.insert(rows, cur_row)
        cur_row = {}
        col = 0
      end
    end
  end
  if #cur_row > 0 then
    table.insert(rows, cur_row)
  end
  return rows
end

local function lcs(a, b)
  local m, n = #a, #b
  local dp = {}
  for i = 0, m do
    dp[i] = {}
    for j = 0, n do
      dp[i][j] = 0
    end
  end
  for i = 1, m do
    for j = 1, n do
      if a[i] == b[j] then
        dp[i][j] = dp[i - 1][j - 1] + 1
      else
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
      end
    end
  end
  local result = {}
  local i, j = m, n
  while i > 0 and j > 0 do
    if a[i] == b[j] then
      table.insert(result, 1, { old_idx = i, new_idx = j })
      i = i - 1
      j = j - 1
    elseif dp[i - 1][j] >= dp[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end
  return result
end

local function compute_diff(old_lines, new_lines)
  local common = lcs(old_lines, new_lines)
  local hunks = {}
  local old_pos, new_pos = 1, 1

  for _, match in ipairs(common) do
    local oi, ni = match.old_idx, match.new_idx
    if oi > old_pos or ni > new_pos then
      table.insert(hunks, {
        type = "change",
        old_start = old_pos,
        old_lines = { unpack(old_lines, old_pos, oi - 1) },
        new_lines = { unpack(new_lines, new_pos, ni - 1) },
      })
    end
    table.insert(hunks, {
      type = "context",
      old_start = oi,
      line = old_lines[oi],
    })
    old_pos = oi + 1
    new_pos = ni + 1
  end

  if old_pos <= #old_lines or new_pos <= #new_lines then
    table.insert(hunks, {
      type = "change",
      old_start = old_pos,
      old_lines = { unpack(old_lines, old_pos) },
      new_lines = { unpack(new_lines, new_pos) },
    })
  end

  return hunks
end

function M.show_diff(bufnr, start_line, old_lines, new_lines, on_decision, progress_fn)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })

  local extmark_ids = {}
  local hunks = compute_diff(old_lines, new_lines)

  local removed_count = 0
  local added_count = 0
  for _, hunk in ipairs(hunks) do
    if hunk.type == "change" then
      removed_count = removed_count + #hunk.old_lines
      added_count = added_count + #hunk.new_lines
    end
  end

  local header_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0, {
    virt_lines = {
      {
        {
          string.format("─── MCP Edit: %d removed, %d added ───", removed_count, added_count),
          "McpReviewInfo",
        },
      },
    },
    virt_lines_above = true,
  })
  table.insert(extmark_ids, header_id)

  for _, hunk in ipairs(hunks) do
    if hunk.type == "context" then
      local lnum = start_line + hunk.old_start - 2
      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        sign_text = " ",
        sign_hl_group = "McpReviewContext",
      })
      table.insert(extmark_ids, id)
    elseif hunk.type == "change" then
      for i, line in ipairs(hunk.old_lines) do
        local lnum = start_line + hunk.old_start + i - 3
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
          sign_text = "−",
          sign_hl_group = "McpReviewDelText",
          line_hl_group = "McpReviewDel",
        })
        table.insert(extmark_ids, id)

        local new_counterpart = hunk.new_lines[i]
        if new_counterpart then
          local buf_line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
          local min_len = math.min(#buf_line, #new_counterpart)
          local prefix_end = 0
          for ci = 1, min_len do
            if buf_line:sub(ci, ci) == new_counterpart:sub(ci, ci) then
              prefix_end = ci
            else
              break
            end
          end
          local suffix_start_buf = #buf_line + 1
          for ci = 0, min_len - prefix_end - 1 do
            if
              buf_line:sub(#buf_line - ci, #buf_line - ci)
              == new_counterpart:sub(#new_counterpart - ci, #new_counterpart - ci)
            then
              suffix_start_buf = #buf_line - ci
            else
              break
            end
          end
          if prefix_end < suffix_start_buf - 1 then
            local emph_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, prefix_end, {
              end_col = suffix_start_buf - 1,
              hl_group = "McpReviewDelEmph",
            })
            table.insert(extmark_ids, emph_id)
          end
        end
      end

      if #hunk.new_lines > 0 then
        local virt = {}
        local do_wrap = vim.wo.wrap
        local win_width = do_wrap
            and (vim.api.nvim_win_get_width(0) - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff)
          or 0
        for ni, line in ipairs(hunk.new_lines) do
          local old_counterpart = hunk.old_lines[ni]
          local chunks = intra_line_chunks(line, old_counterpart, "McpReviewAdd", "McpReviewAddEmph")
          if do_wrap then
            local wrapped = wrap_chunks(chunks, win_width)
            for _, row in ipairs(wrapped) do
              table.insert(virt, row)
            end
          else
            table.insert(virt, chunks)
          end
        end
        local anchor = start_line + hunk.old_start + #hunk.old_lines - 3
        if #hunk.old_lines == 0 then
          anchor = start_line + hunk.old_start - 2
        end
        anchor = math.max(0, math.min(anchor, vim.api.nvim_buf_line_count(bufnr) - 1))
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor, 0, {
          virt_lines = virt,
        })
        table.insert(extmark_ids, id)
      end
    end
  end

  local last_old_line = start_line + #old_lines - 2
  local footer_line = math.min(last_old_line + 1, vim.api.nvim_buf_line_count(bufnr) - 1)
  footer_line = math.max(0, footer_line)
  local footer_id = vim.api.nvim_buf_set_extmark(bufnr, ns, footer_line, 0, {
    virt_lines = {
      { { "─── [a]ccept  [A]lways  [r]eject  [R]eason  [e]dit ───", "McpReviewInfo" } },
    },
    virt_lines_above = true,
  })
  table.insert(extmark_ids, footer_id)

  pending_review = {
    bufnr = bufnr,
    extmark_ids = extmark_ids,
    on_decision = on_decision,
  }

  -- Emit progress notifications if client provided a progressToken
  local progress_augroup = nil
  local function emit(msg)
    if progress_fn then
      progress_fn(msg)
    end
  end

  emit("Awaiting user review")

  if progress_fn then
    progress_augroup = vim.api.nvim_create_augroup("McpReviewProgress", { clear = true })
    vim.api.nvim_create_autocmd("CursorHold", {
      group = progress_augroup,
      buffer = bufnr,
      callback = function()
        emit("User is reviewing changes")
      end,
    })
    vim.api.nvim_create_autocmd("FocusGained", {
      group = progress_augroup,
      callback = function()
        if pending_review and pending_review.bufnr == bufnr then
          emit("User returned to review")
        end
      end,
    })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = progress_augroup,
      buffer = bufnr,
      callback = function()
        emit("User is editing the buffer")
      end,
    })
  end

  vim.notify("MCP: edit pending review — [a]ccept [A]lways [r]eject [R]eason [e]dit", vim.log.levels.INFO)

  local function cleanup()
    if not pending_review then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    pcall(vim.keymap.del, "n", "a", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "A", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "r", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "R", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "e", { buffer = bufnr })
    if progress_augroup then
      pcall(vim.api.nvim_del_augroup_by_id, progress_augroup)
      progress_augroup = nil
    end
    pending_review = nil
    vim.cmd("echo ''")
  end

  vim.keymap.set("n", "a", function()
    local cb = pending_review and pending_review.on_decision
    cleanup()
    if cb then
      cb("accept")
    end
  end, { buffer = bufnr, nowait = true, desc = "Accept MCP edit" })

  vim.keymap.set("n", "A", function()
    local cb = pending_review and pending_review.on_decision
    cleanup()
    require("mcp-nvim").config.review_edits = false
    vim.notify("MCP: auto-accepting all future edits this session", vim.log.levels.INFO)
    if cb then
      cb("accept")
    end
  end, { buffer = bufnr, nowait = true, desc = "Accept and auto-accept future edits" })

  vim.keymap.set("n", "r", function()
    local cb = pending_review and pending_review.on_decision
    cleanup()
    if cb then
      cb("reject")
    end
  end, { buffer = bufnr, nowait = true, desc = "Reject MCP edit" })

  vim.keymap.set("n", "R", function()
    local cb = pending_review and pending_review.on_decision
    cleanup()
    if cb then
      vim.ui.input({ prompt = "Reject reason: " }, function(reason)
        if reason and reason ~= "" then
          cb("reject", reason)
        else
          cb("reject")
        end
      end)
    end
  end, { buffer = bufnr, nowait = true, desc = "Reject MCP edit with reason" })

  vim.keymap.set("n", "e", function()
    local cb = pending_review and pending_review.on_decision
    cleanup()
    if cb then
      cb("edit")
    end
  end, { buffer = bufnr, nowait = true, desc = "Edit MCP suggestion" })

  vim.cmd("redraw")
end

function M.has_pending()
  return pending_review ~= nil
end

function M.cancel()
  if pending_review then
    local cb = pending_review.on_decision
    local bufnr = pending_review.bufnr
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    pcall(vim.keymap.del, "n", "a", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "r", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "e", { buffer = bufnr })
    pending_review = nil
    if cb then
      cb("reject")
    end
  end
end

return M
