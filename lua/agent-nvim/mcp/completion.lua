local M = {}

local completers = {}

function M.register(ref_type, ref_name, arg_name, handler)
  local key = string.format("%s:%s:%s", ref_type, ref_name, arg_name)
  completers[key] = handler
end

function M.complete(ref, argument)
  local ref_type = ref.type
  local ref_name = ref.name or ref.uri or ""
  local arg_name = argument.name or ""
  local arg_value = argument.value or ""

  local key = string.format("%s:%s:%s", ref_type, ref_name, arg_name)
  local handler = completers[key]

  if not handler then
    return { values = {} }
  end

  local ok, values = pcall(handler, arg_value)
  if not ok then
    return { values = {} }
  end

  local filtered = {}
  for _, v in ipairs(values) do
    if arg_value == "" or v:find(arg_value, 1, true) == 1 then
      table.insert(filtered, v)
    end
  end

  return {
    values = filtered,
    hasMore = #filtered > 50,
    total = #filtered,
  }
end

function M.reset()
  completers = {}
end

function M.register_defaults()
  -- Resource template completions
  M.register("ref/resource", "nvim://buffer/{id}", "id", function()
    local bufs = vim.api.nvim_list_bufs()
    local values = {}
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(buf) then
        table.insert(values, tostring(buf))
      end
    end
    return values
  end)

  M.register("ref/resource", "nvim://keymaps/{mode}", "mode", function()
    return { "n", "i", "v", "x", "s", "o", "c", "t" }
  end)

  M.register("ref/resource", "nvim://diagnostics/{bufnr}", "bufnr", function()
    local bufs = vim.api.nvim_list_bufs()
    local values = {}
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local diags = vim.diagnostic.get(buf)
        if #diags > 0 then
          table.insert(values, tostring(buf))
        end
      end
    end
    return values
  end)

  -- Prompt argument completions
  M.register("ref/prompt", "fix", "scope", function()
    return { "line", "buffer" }
  end)

  M.register("ref/prompt", "explain", "depth", function()
    return { "brief", "normal", "deep" }
  end)

  M.register("ref/prompt", "refactor", "instructions", function()
    return { "extract into a function", "simplify", "add error handling", "rename for clarity", "reduce nesting" }
  end)

  M.register("ref/prompt", "review", "scope", function()
    return { "buffer", "diff", "staged" }
  end)

  M.register("ref/prompt", "review", "focus", function()
    return { "all", "bugs", "security", "performance", "style" }
  end)
end

return M
