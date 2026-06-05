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
    local entry = {
      name = name,
      description = tool.definition.description,
      inputSchema = tool.definition.inputSchema,
    }
    if tool.definition.annotations then
      entry.annotations = tool.definition.annotations
    end
    table.insert(result, entry)
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.call_tool(name, arguments, callback)
  local tool = tools[name]
  if not tool then
    local err_result = { false, "Unknown tool: " .. name }
    if callback then
      callback(unpack(err_result))
      return
    end
    return unpack(err_result)
  end

  local valid, err = validate_arguments(arguments, tool.definition.inputSchema)
  if not valid then
    local err_result = { true, { { type = "text", text = "Validation error: " .. err } }, true }
    if callback then
      callback(unpack(err_result))
      return
    end
    return unpack(err_result)
  end

  if tool.definition.async and callback then
    local ok, call_err = pcall(tool.handler, arguments, function(result, is_error)
      if type(result) == "string" then
        callback(true, { { type = "text", text = result } }, is_error or false)
      elseif type(result) == "table" and result[1] and result[1].type then
        callback(true, result, is_error or false)
      else
        callback(true, { { type = "text", text = tostring(result) } }, is_error or false)
      end
    end)
    if not ok then
      callback(true, { { type = "text", text = string.format("Error in %s: %s", name, tostring(call_err)) } }, true)
    end
    return "async"
  end

  local ok, result = pcall(tool.handler, arguments)
  if not ok then
    local err_result = { true, { { type = "text", text = string.format("Error in %s: %s", name, tostring(result)) } }, true }
    if callback then
      callback(unpack(err_result))
      return
    end
    return unpack(err_result)
  end

  if type(result) == "string" then
    local r = { true, { { type = "text", text = result } }, false }
    if callback then
      callback(unpack(r))
      return
    end
    return unpack(r)
  end

  if type(result) == "table" and result[1] and result[1].type then
    local r = { true, result, false }
    if callback then
      callback(unpack(r))
      return
    end
    return unpack(r)
  end

  local r = { true, { { type = "text", text = tostring(result) } }, false }
  if callback then
    callback(unpack(r))
    return
  end
  return unpack(r)
end

function M.reset()
  tools = {}
end

return M
