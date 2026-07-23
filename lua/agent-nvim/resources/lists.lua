local resources = require("agent-nvim.mcp.resources")

resources.register("nvim://quickfix", {
  name = "Quickfix List",
  description = "Current quickfix list entries with file, line, and description",
  mimeType = "application/json",
}, function()
  local qf = vim.fn.getqflist({ all = true })
  local items = {}

  for _, item in ipairs(qf.items or {}) do
    local file = ""
    if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      file = vim.api.nvim_buf_get_name(item.bufnr)
    end
    table.insert(items, {
      file = file,
      line = item.lnum,
      column = item.col,
      text = item.text,
      type = item.type,
    })
  end

  return {
    uri = "nvim://quickfix",
    mimeType = "application/json",
    text = vim.json.encode({
      title = qf.title or "",
      items = items,
    }),
  }
end)

resources.register("nvim://jumplist", {
  name = "Jump List",
  description = "Current jump list with file positions and navigation index",
  mimeType = "application/json",
}, function()
  local jumplist = vim.fn.getjumplist()
  local jumps = jumplist[1]
  local current_pos = jumplist[2]

  local result = {}
  for _, jump in ipairs(jumps) do
    local name = ""
    if jump.bufnr and vim.api.nvim_buf_is_valid(jump.bufnr) then
      name = vim.api.nvim_buf_get_name(jump.bufnr)
    end
    table.insert(result, {
      file = name,
      line = jump.lnum,
      column = jump.col + 1,
    })
  end

  return {
    uri = "nvim://jumplist",
    mimeType = "application/json",
    text = vim.json.encode({
      jumps = result,
      current_index = current_pos,
    }),
  }
end)

resources.register("nvim://loclist", {
  name = "Location List",
  description = "Current window's location list entries",
  mimeType = "application/json",
}, function()
  local loc = vim.fn.getloclist(0, { all = true })
  local items = {}

  for _, item in ipairs(loc.items or {}) do
    local file = ""
    if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      file = vim.api.nvim_buf_get_name(item.bufnr)
    end
    table.insert(items, {
      file = file,
      line = item.lnum,
      column = item.col,
      text = item.text,
    })
  end

  return {
    uri = "nvim://loclist",
    mimeType = "application/json",
    text = vim.json.encode({
      title = loc.title or "",
      items = items,
    }),
  }
end)

resources.register("nvim://marks", {
  name = "Marks",
  description = "All set marks (a-z local, A-Z global) with their positions",
  mimeType = "application/json",
}, function()
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

  return {
    uri = "nvim://marks",
    mimeType = "application/json",
    text = vim.json.encode(marks),
  }
end)

resources.register("nvim://changelist", {
  name = "Change List",
  description = "Positions of recent edits in the current buffer (navigate with g; and g,)",
  mimeType = "application/json",
}, function()
  local changelist = vim.fn.getchangelist()
  local changes = changelist[1] or {}
  local current_pos = changelist[2]

  local result = {}
  for _, change in ipairs(changes) do
    table.insert(result, {
      line = change.lnum,
      column = change.col + 1,
    })
  end

  return {
    uri = "nvim://changelist",
    mimeType = "application/json",
    text = vim.json.encode({
      changes = result,
      current_index = current_pos,
    }),
  }
end)
