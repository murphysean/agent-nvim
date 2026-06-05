local M = {}

local ns = vim.api.nvim_create_namespace("mcp_review")

local pending_review = nil

vim.api.nvim_set_hl(0, "McpReviewAdd", { bg = "#1a3a1a", default = true })
vim.api.nvim_set_hl(0, "McpReviewDel", { bg = "#3a1a1a", default = true })
vim.api.nvim_set_hl(0, "McpReviewDelText", { fg = "#cc6666", strikethrough = true, default = true })
vim.api.nvim_set_hl(0, "McpReviewInfo", { fg = "#888888", italic = true, default = true })
vim.api.nvim_set_hl(0, "McpReviewContext", { fg = "#666666", default = true })

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

function M.show_diff(bufnr, start_line, old_lines, new_lines, on_decision)
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
      end

      if #hunk.new_lines > 0 then
        local virt = {}
        for _, line in ipairs(hunk.new_lines) do
          table.insert(virt, { { " " .. line, "McpReviewAdd" } })
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
    pending_review = nil
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
