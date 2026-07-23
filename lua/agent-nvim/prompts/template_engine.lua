--- Template engine for prompt files.
--- Reads .md template files and substitutes {placeholder} tokens with context values.
local M = {}

local template_cache = {}

--- Find the templates directory relative to the plugin root.
local function get_templates_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h:h")
  return plugin_dir .. "/prompts/templates"
end

--- Read a template file by name (without extension).
--- Returns the raw template string, or nil + error.
function M.read(name)
  if template_cache[name] then
    return template_cache[name]
  end

  local dir = get_templates_dir()
  local path = dir .. "/" .. name .. ".md"
  local f = io.open(path, "r")
  if not f then
    return nil, "Template not found: " .. path
  end
  local content = f:read("*a")
  f:close()
  template_cache[name] = content
  return content
end

--- Clear the template cache (for development/reload).
function M.clear_cache()
  template_cache = {}
end

--- Substitute all {placeholder} tokens in a template with values from a context table.
--- Unresolved placeholders are replaced with empty string.
function M.render(template, context)
  return (
    template:gsub("{([%w_]+)}", function(key)
      local value = context[key]
      if value == nil or value == "" then
        return ""
      end
      return value
    end)
  )
end

--- Convenience: read a template and render it with the given context.
function M.load_and_render(name, context)
  local template, err = M.read(name)
  if not template then
    return nil, err
  end
  return M.render(template, context)
end

return M
