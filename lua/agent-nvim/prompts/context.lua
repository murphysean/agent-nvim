--- Context gathering for prompt templates.
--- Collects all available editor state that can be injected into prompt placeholders.
local M = {}

--- Resolve the workspace root via LSP root_dir, then git, then cwd.
local function get_workspace_root()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  for _, client in ipairs(clients) do
    if client.config.root_dir then
      return client.config.root_dir
    end
  end
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if vim.v.shell_error == 0 and git_root and git_root ~= "" then
    return git_root
  end
  return vim.fn.getcwd()
end

--- Get the relative path of a file from the workspace root.
local function get_relative_path(filepath, root)
  if filepath:sub(1, #root) == root then
    local rel = filepath:sub(#root + 2)
    return rel ~= "" and rel or filepath
  end
  return filepath
end

--- Extract import/require statements from the buffer.
local function get_imports(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local imports = {}
  for _, line in ipairs(lines) do
    if
      line:match("^%s*require")
      or line:match("^%s*local%s+.+%s*=%s*require")
      or line:match("^%s*import%s+")
      or line:match("^%s*from%s+")
      or line:match("^%s*use%s+")
      or line:match("^%s*#include")
    then
      table.insert(imports, line)
    end
  end
  return table.concat(imports, "\n")
end

--- Get document symbols as a concise outline.
local function get_document_symbols()
  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  local results = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", params, 2000)
  if not results then
    return ""
  end

  local kind_names = {
    [1] = "file",
    [2] = "module",
    [3] = "namespace",
    [5] = "class",
    [6] = "method",
    [9] = "constructor",
    [12] = "function",
    [13] = "variable",
    [14] = "constant",
    [16] = "number",
    [23] = "struct",
  }

  local outline = {}
  for _, resp in pairs(results) do
    if resp.result then
      for _, sym in ipairs(resp.result) do
        local kind = kind_names[sym.kind] or "symbol"
        local line = sym.range and (sym.range.start.line + 1) or "?"
        table.insert(outline, string.format("  L%s %s (%s)", line, sym.name, kind))
      end
    end
  end
  return table.concat(outline, "\n")
end

--- Get diagnostics near the cursor.
local function get_diagnostics_near(buf, cursor_row, radius)
  local diags = vim.diagnostic.get(buf)
  local nearby = {}
  local severity_names = { "ERROR", "WARN", "INFO", "HINT" }
  for _, d in ipairs(diags) do
    if math.abs(d.lnum - (cursor_row - 1)) <= radius then
      local sev = severity_names[d.severity] or "?"
      table.insert(nearby, string.format("  L%d [%s]: %s", d.lnum + 1, sev, d.message))
    end
  end
  if #nearby == 0 then
    return ""
  end
  return table.concat(nearby, "\n")
end

--- Get treesitter scope chain at the cursor.
local function get_scope_chain(buf, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row - 1, col } })
  if not ok or not node then
    return "", ""
  end

  local chain = {}
  local current = node
  while current do
    table.insert(chain, 1, current:type())
    current = current:parent()
  end

  return node:type(), table.concat(chain, " → ")
end

--- Get the full text of the enclosing function around the cursor.
local function get_enclosing_function(buf, row)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row - 1, 0 } })
  if not ok or not node then
    return ""
  end

  local function_types = {
    function_declaration = true,
    function_definition = true,
    function_item = true,
    method_definition = true,
    method_declaration = true,
    arrow_function = true,
    lambda_expression = true,
    fn_item = true,
  }

  local current = node
  while current do
    if function_types[current:type()] then
      local start_row, _, end_row, _ = current:range()
      local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
      -- Cap at 40 lines to avoid bloating the prompt
      if #lines > 40 then
        local head = { unpack(lines, 1, 20) }
        table.insert(head, "  -- ... (" .. (#lines - 40) .. " lines omitted) ...")
        for i = #lines - 19, #lines do
          table.insert(head, lines[i])
        end
        lines = head
      end
      return table.concat(lines, "\n")
    end
    current = current:parent()
  end
  return ""
end

--- Get list of open buffer paths (excluding current), relative to workspace root.
local function get_open_buffers(current_buf, root)
  local bufs = vim.api.nvim_list_bufs()
  local files = {}
  for _, b in ipairs(bufs) do
    if b ~= current_buf and vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        table.insert(files, "  " .. get_relative_path(name, root))
      end
    end
  end
  return table.concat(files, "\n")
end

--- Get git diff for the current file (unstaged changes).
local function get_git_diff(filepath)
  local output = vim.fn.systemlist("git diff --no-color -- " .. vim.fn.shellescape(filepath))
  if vim.v.shell_error ~= 0 or #output == 0 then
    return ""
  end
  -- Cap at 50 lines
  if #output > 50 then
    output = { unpack(output, 1, 50) }
    table.insert(output, "... (diff truncated)")
  end
  return table.concat(output, "\n")
end

--- Detect the visual selection range (if any).
--- Returns start_row, start_col, end_row, end_col (all 1-indexed) or nil.
local function get_visual_selection(buf)
  local mode = vim.fn.mode()
  -- If we're called from a command (which exits visual mode), check '< and '> marks
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  -- Marks are (0,0) if never set
  if start_pos[1] == 0 and start_pos[2] == 0 then
    return nil
  end

  return start_pos[1], start_pos[2], end_pos[1], end_pos[2]
end

--- Gather all context variables for the current cursor position.
---@param opts table|nil Options: { mode = "normal"|"visual"|"insert", selection = string|nil, replace_range = {start_row, end_row}|nil }
---@return table context Key-value pairs for template placeholders.
function M.gather(opts)
  opts = opts or {}

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local filepath = vim.api.nvim_buf_get_name(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  local root = get_workspace_root()

  -- Surrounding code
  local before_start = math.max(0, row - 51)
  local before_lines = vim.api.nvim_buf_get_lines(buf, before_start, row - 1, false)
  local current_line = lines[row] or ""
  local after_end = math.min(#lines, row + 50)
  local after_lines = vim.api.nvim_buf_get_lines(buf, row, after_end, false)

  -- Treesitter
  local node_type, scope_chain = get_scope_chain(buf, row, col)

  -- Mode and selection
  local mode = opts.mode or "normal"
  local selection = opts.selection or ""
  local intent = ""

  if mode == "visual" and selection ~= "" then
    intent = "Replace the selected code with a proper implementation."
  elseif mode == "normal" then
    intent = "Complete or fill in code at the cursor line."
  elseif mode == "insert" then
    intent = "Insert code at the cursor position (between existing text)."
  end

  return {
    -- File & Project
    filepath = filepath,
    relative_path = get_relative_path(filepath, root),
    filename = vim.fn.fnamemodify(filepath, ":t"),
    filetype = ft,
    workspace_root = root,

    -- Cursor & Position
    cursor_line = tostring(row),
    cursor_col = tostring(col),
    total_lines = tostring(#lines),
    current_line = current_line,
    lines_before = table.concat(before_lines, "\n"),
    lines_after = table.concat(after_lines, "\n"),

    -- Mode & Selection
    mode = mode,
    selection = selection,
    intent = intent,

    -- LSP Context
    diagnostics = get_diagnostics_near(buf, row, 15),
    document_symbols = get_document_symbols(),

    -- Treesitter Context
    node_type = node_type,
    scope_chain = scope_chain,
    enclosing_function = get_enclosing_function(buf, row),

    -- Buffer/Editor State
    imports = get_imports(buf),
    open_buffers = get_open_buffers(buf, root),
    git_diff = get_git_diff(filepath),
  }
end

return M
