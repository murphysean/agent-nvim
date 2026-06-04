local M = {}

local tools = {}

local JSON_TYPE_MAP = {
  string = "string",
  number = "number",
  boolean = "boolean",
  table = "object",
}

local function validate_arguments(arguments, schema)
  if not schema or schema.type ~= "object" then
    return true
  end

  local required = schema.required or {}
  for _, field in ipairs(required) do
    if arguments[field] == nil then
      return false, string.format("Missing required field: %s", field)
    end
  end

  local properties = schema.properties
  if not properties or vim.tbl_isempty(properties) then
    return true
  end

  for field, value in pairs(arguments) do
    local prop = properties[field]
    if prop and prop.type then
      local lua_type = type(value)
      local expected = prop.type
      if expected == "integer" then
        expected = "number"
      end
      local actual = JSON_TYPE_MAP[lua_type] or lua_type
      if expected == "array" then
        if lua_type ~= "table" then
          return false, string.format("Field '%s': expected array, got %s", field, lua_type)
        end
      elseif actual ~= expected then
        return false, string.format("Field '%s': expected %s, got %s", field, expected, lua_type)
      end
    end
  end

  return true
end

function M.register(name, definition, handler)
  tools[name] = {
    definition = definition,
    handler = handler,
  }
end

function M.list_tools()
  local result = {}
  for name, tool in pairs(tools) do
    table.insert(result, {
      name = name,
      description = tool.definition.description,
      inputSchema = tool.definition.inputSchema,
    })
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.call_tool(name, arguments)
  local tool = tools[name]
  if not tool then
    return false, "Unknown tool: " .. name
  end

  local valid, err = validate_arguments(arguments, tool.definition.inputSchema)
  if not valid then
    return true, { { type = "text", text = "Validation error: " .. err } }, true
  end

  local ok, result = pcall(tool.handler, arguments)
  if not ok then
    return true, { { type = "text", text = string.format("Error in %s: %s", name, tostring(result)) } }, true
  end

  if type(result) == "string" then
    return true, { { type = "text", text = result } }, false
  end

  if type(result) == "table" and result[1] and result[1].type then
    return true, result, false
  end

  return true, { { type = "text", text = tostring(result) } }, false
end

function M.reset()
  tools = {}
end

return M
