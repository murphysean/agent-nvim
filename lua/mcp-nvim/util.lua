local M = {}

--- Returns true if a window is suitable for code editing operations
--- (normal file buffers, not terminals, quickfix, floating popups, etc.)
local function is_code_window(win)
  -- Floating windows are popups (cheatsheets, hover, completion, etc.)
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg.relative and cfg.relative ~= "" then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })

  -- Only empty buftype (normal files) or "acwrite" (auto-command write) are code windows
  -- Excludes: terminal, nofile (DAP, file trees), nowrite, quickfix, prompt, help
  if bt ~= "" and bt ~= "acwrite" then
    return false
  end

  return true
end

--- Returns a window ID suitable for code operations.
--- If bufnr is provided, first checks if that buffer is already visible in any
--- tab and switches to that window. Otherwise, if the current window is not a
--- code window (terminal, file browser, DAP, floating popup, quickfix, etc.),
--- finds and switches to an appropriate window.
function M.ensure_code_window(bufnr)
  if bufnr then
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_buf(win) == bufnr and is_code_window(win) then
          vim.api.nvim_set_current_tabpage(tab)
          vim.api.nvim_set_current_win(win)
          return win
        end
      end
    end
  end

  local cur_win = vim.api.nvim_get_current_win()

  if is_code_window(cur_win) then
    return cur_win
  end

  -- Find the largest code window in the current tab (most likely the main editor)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local best_win, best_area = nil, 0

  for _, win in ipairs(wins) do
    if is_code_window(win) then
      local w = vim.api.nvim_win_get_width(win)
      local h = vim.api.nvim_win_get_height(win)
      local area = w * h
      if area > best_area then
        best_win = win
        best_area = area
      end
    end
  end

  if best_win then
    vim.api.nvim_set_current_win(best_win)
    return best_win
  end

  -- No code windows exist — create one
  vim.cmd("vsplit")
  vim.cmd("enew")
  return vim.api.nvim_get_current_win()
end

return M
