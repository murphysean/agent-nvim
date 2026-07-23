local M = {}

local client_roots = {}

function M.set(roots)
  client_roots = roots or {}
end

function M.get()
  return client_roots
end

function M.list_uris()
  local uris = {}
  for _, root in ipairs(client_roots) do
    table.insert(uris, root.uri)
  end
  return uris
end

function M.list_paths()
  local paths = {}
  for _, root in ipairs(client_roots) do
    local uri = root.uri
    if uri:sub(1, 7) == "file://" then
      table.insert(paths, uri:sub(8))
    end
  end
  return paths
end

function M.contains(filepath)
  local abs = vim.fn.fnamemodify(filepath, ":p")
  for _, root in ipairs(client_roots) do
    local uri = root.uri
    if uri:sub(1, 7) == "file://" then
      local root_path = uri:sub(8)
      if abs:sub(1, #root_path) == root_path then
        return true
      end
    end
  end
  return #client_roots == 0
end

function M.reset()
  client_roots = {}
end

return M
