local resources = require("agent-nvim.mcp.resources")

resources.register("nvim://buffers", {
  name = "Open Buffers",
  description = "List of all open buffers with metadata (number, path, modified status, line count)",
  mimeType = "application/json",
}, function()
  local bufs = vim.api.nvim_list_bufs()
  local result = {}

  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_option_value("buflisted", { buf = buf }) then
      local name = vim.api.nvim_buf_get_name(buf)
      table.insert(result, {
        bufnr = buf,
        name = name ~= "" and name or "[No Name]",
        modified = vim.api.nvim_get_option_value("modified", { buf = buf }),
        loaded = vim.api.nvim_buf_is_loaded(buf),
        line_count = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_line_count(buf) or 0,
        filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
      })
    end
  end

  return {
    uri = "nvim://buffers",
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)

resources.register("nvim://buffer/current", {
  name = "Current Buffer",
  description = "Full contents of the currently active buffer",
  mimeType = "text/plain",
}, function()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })

  local mime = "text/plain"
  if ft == "lua" then
    mime = "text/x-lua"
  elseif ft == "rust" then
    mime = "text/x-rust"
  elseif ft == "go" then
    mime = "text/x-go"
  elseif ft == "python" then
    mime = "text/x-python"
  elseif ft == "json" then
    mime = "application/json"
  elseif ft == "yaml" then
    mime = "text/yaml"
  end

  return {
    uri = "nvim://buffer/current",
    mimeType = mime,
    text = table.concat(lines, "\n"),
  }
end)

resources.register("nvim://selection", {
  name = "Visual Selection",
  description = "Currently selected text (visual mode). Empty if no active selection.",
  mimeType = "text/plain",
}, function()
  local mode = vim.fn.mode()
  local text = ""

  if mode == "v" or mode == "V" or mode == "\22" then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    text = table.concat(lines, "\n")
  else
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    if start_pos[2] > 0 and end_pos[2] > 0 then
      local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
      text = table.concat(lines, "\n")
    end
  end

  return {
    uri = "nvim://selection",
    mimeType = "text/plain",
    text = text,
  }
end)

resources.register("nvim://cursor", {
  name = "Cursor Context",
  description = "Current cursor position with surrounding lines for context",
  mimeType = "application/json",
}, function()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2] + 1
  local name = vim.api.nvim_buf_get_name(buf)
  local total_lines = vim.api.nvim_buf_line_count(buf)

  local context_start = math.max(0, line - 6)
  local context_end = math.min(total_lines, line + 5)
  local context_lines = vim.api.nvim_buf_get_lines(buf, context_start, context_end, false)

  return {
    uri = "nvim://cursor",
    mimeType = "application/json",
    text = vim.json.encode({
      file = name,
      bufnr = buf,
      line = line,
      column = col,
      total_lines = total_lines,
      context_start = context_start + 1,
      context = context_lines,
    }),
  }
end)

-- Template: specific buffer by ID
resources.register_template("nvim://buffer/{id}", {
  name = "Buffer by ID",
  description = "Full contents of a specific buffer by its buffer number",
  mimeType = "text/plain",
}, function(params)
  local bufnr = tonumber(params.id)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  return {
    uri = "nvim://buffer/" .. params.id,
    mimeType = "text/plain",
    text = table.concat(lines, "\n"),
  }
end)
