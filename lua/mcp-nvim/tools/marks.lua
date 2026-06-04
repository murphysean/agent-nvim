local registry = require("mcp-nvim.mcp.registry")

registry.register("mark_set", {
  description = "Set a named mark at a position. Uppercase marks (A-Z) are global across files, lowercase (a-z) are buffer-local.",
  inputSchema = {
    type = "object",
    properties = {
      mark = {
        type = "string",
        description = "Mark name (a-z for local, A-Z for global)",
      },
      line = {
        type = "integer",
        description = "Line number (1-indexed). Default: current cursor line.",
      },
      column = {
        type = "integer",
        description = "Column (0-indexed). Default: 0.",
      },
    },
    required = { "mark" },
  },
}, function(args)
  local line = args.line or vim.api.nvim_win_get_cursor(0)[1]
  local col = args.column or 0
  vim.api.nvim_buf_set_mark(0, args.mark, line, col, {})
  return string.format("Mark '%s' set at line %d, col %d", args.mark, line, col)
end)

registry.register("mark_get", {
  description = "Get all marks and their positions",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local marks = {}
  local all_marks = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  for i = 1, #all_marks do
    local mark = all_marks:sub(i, i)
    local pos = vim.api.nvim_buf_get_mark(0, mark)
    if pos[1] > 0 then
      table.insert(marks, {
        mark = mark,
        line = pos[1],
        column = pos[2],
      })
    end
  end

  return vim.json.encode(marks)
end)

registry.register("fold_toggle", {
  description = "Toggle, open, or close a fold at a specific line",
  inputSchema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "Line number. Default: current line.",
      },
      action = {
        type = "string",
        enum = { "toggle", "open", "close", "open_all", "close_all" },
        description = "Fold action. Default: toggle.",
      },
    },
  },
}, function(args)
  if args.line then
    vim.api.nvim_win_set_cursor(0, { args.line, 0 })
  end

  local action = args.action or "toggle"
  local cmds = {
    toggle = "normal! za",
    open = "normal! zo",
    close = "normal! zc",
    open_all = "normal! zR",
    close_all = "normal! zM",
  }

  vim.cmd(cmds[action])
  return "Fold " .. action .. " executed"
end)
