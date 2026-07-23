local M = {}

local prompts = {}

function M.register(name, definition, handler)
  prompts[name] = {
    definition = definition,
    handler = handler,
  }
end

function M.list()
  local result = {}
  for name, prompt in pairs(prompts) do
    table.insert(result, {
      name = name,
      description = prompt.definition.description,
      arguments = prompt.definition.arguments,
    })
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.get(name, arguments)
  local prompt = prompts[name]
  if not prompt then
    return false, "Unknown prompt: " .. name
  end

  local ok, result = pcall(prompt.handler, arguments or {})
  if not ok then
    return false, "Error generating prompt: " .. tostring(result)
  end

  return true, result
end

function M.reset()
  prompts = {}
end

return M
