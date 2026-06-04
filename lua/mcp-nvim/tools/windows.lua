local registry = require("mcp-nvim.mcp.registry")

registry.register("window_list", {
  description = "List all windows in the current tab with their buffer info and cursor positions",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local result = {}

  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local width = vim.api.nvim_win_get_width(win)
    local height = vim.api.nvim_win_get_height(win)

    table.insert(result, {
      winid = win,
      bufnr = buf,
      file = vim.api.nvim_buf_get_name(buf),
      cursor_line = cursor[1],
      cursor_col = cursor[2],
      width = width,
      height = height,
    })
  end

  return vim.json.encode(result)
end)

registry.register("window_split", {
  description = "Split the current window horizontally or vertically, optionally opening a file",
  inputSchema = {
    type = "object",
    properties = {
      direction = {
        type = "string",
        enum = { "horizontal", "vertical" },
        description = "Split direction. Default horizontal.",
      },
      file = {
        type = "string",
        description = "Optional file to open in the new split",
      },
    },
  },
}, function(args)
  local direction = args.direction or "horizontal"
  local cmd = direction == "vertical" and "vsplit" or "split"

  if args.file then
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(args.file))
  else
    vim.cmd(cmd)
  end

  local win = vim.api.nvim_get_current_win()
  return vim.json.encode({
    winid = win,
    bufnr = vim.api.nvim_win_get_buf(win),
  })
end)

registry.register("window_close", {
  description = "Close a window by ID",
  inputSchema = {
    type = "object",
    properties = {
      winid = {
        type = "integer",
        description = "Window ID to close. Default: current window.",
      },
    },
  },
}, function(args)
  local win = args.winid or vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(win, false)
  return "Window closed"
end)

registry.register("tab_list", {
  description = "List all tab pages with their window count and current buffer",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local tabs = vim.api.nvim_list_tabpages()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local result = {}

  for _, tab in ipairs(tabs) do
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    local win = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(win)

    table.insert(result, {
      tabnr = tab,
      is_current = tab == current_tab,
      window_count = #wins,
      current_file = vim.api.nvim_buf_get_name(buf),
    })
  end

  return vim.json.encode(result)
end)
