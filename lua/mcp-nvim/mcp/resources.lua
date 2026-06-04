local M = {}

local resources = {}
local templates = {}

--- Register a static resource.
--- provider is a function() that returns { uri, mimeType, text } or nil
function M.register(uri, definition, provider)
  resources[uri] = {
    definition = definition,
    provider = provider,
  }
end

--- Register a resource template.
--- resolver is a function(params) that returns { uri, mimeType, text } or nil
function M.register_template(uri_template, definition, resolver)
  templates[uri_template] = {
    definition = definition,
    resolver = resolver,
  }
end

--- List all available resources (static).
function M.list()
  local result = {}
  for uri, resource in pairs(resources) do
    table.insert(result, {
      uri = uri,
      name = resource.definition.name,
      description = resource.definition.description,
      mimeType = resource.definition.mimeType or "text/plain",
    })
  end
  table.sort(result, function(a, b)
    return a.uri < b.uri
  end)
  return result
end

--- List all resource templates.
function M.list_templates()
  local result = {}
  for uri_template, template in pairs(templates) do
    table.insert(result, {
      uriTemplate = uri_template,
      name = template.definition.name,
      description = template.definition.description,
      mimeType = template.definition.mimeType or "text/plain",
    })
  end
  table.sort(result, function(a, b)
    return a.uriTemplate < b.uriTemplate
  end)
  return result
end

--- Read a resource by URI.
--- Returns ok, contents (array of {uri, mimeType, text})
function M.read(uri)
  -- Check static resources first
  local resource = resources[uri]
  if resource then
    local ok, content = pcall(resource.provider)
    if not ok then
      return false, "Error reading resource: " .. tostring(content)
    end
    if not content then
      return false, "Resource not found: " .. uri
    end
    return true, { content }
  end

  -- Try templates
  for uri_template, template in pairs(templates) do
    local params = M.match_template(uri_template, uri)
    if params then
      local ok, content = pcall(template.resolver, params)
      if not ok then
        return false, "Error reading resource: " .. tostring(content)
      end
      if not content then
        return false, "Resource not found: " .. uri
      end
      return true, { content }
    end
  end

  return false, "Resource not found: " .. uri
end

--- Match a URI against a template, extracting parameters.
--- Simple implementation supporting {param} placeholders.
function M.match_template(template, uri)
  -- Convert template to a regex pattern
  -- "nvim://buffer/{id}" → "^nvim://buffer/(.+)$" and capture names
  local param_names = {}
  local pattern = "^"
    .. template:gsub("{([^}]+)}", function(name)
      table.insert(param_names, name)
      return "(.+)"
    end)
    .. "$"

  -- Escape special pattern chars except our (.+) captures
  -- We need to be careful: escape the fixed parts only
  -- Simpler approach: rebuild pattern piece by piece
  param_names = {}
  local parts = {}
  local last_end = 1
  for start, name, finish in template:gmatch("()({[^}]+})()") do
    local prefix = template:sub(last_end, start - 1)
    table.insert(parts, vim.pesc(prefix))
    table.insert(parts, "([^/]+)")
    table.insert(param_names, name:sub(2, -2)) -- strip { }
    last_end = finish
  end
  table.insert(parts, vim.pesc(template:sub(last_end)))
  pattern = "^" .. table.concat(parts) .. "$"

  local captures = { uri:match(pattern) }
  if #captures == 0 then
    return nil
  end

  local params = {}
  for i, name in ipairs(param_names) do
    params[name] = captures[i]
  end
  return params
end

function M.reset()
  resources = {}
  templates = {}
end

return M
