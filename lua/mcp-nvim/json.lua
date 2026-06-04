-- Thin wrapper around vim.json (or vim.fn.json_encode/decode)
local M = {}

function M.encode(value)
  return vim.json.encode(value)
end

function M.decode(str)
  if not str or str == "" then
    return nil, "empty input"
  end
  local ok, result = pcall(vim.json.decode, str)
  if ok then
    return result
  end
  return nil, tostring(result)
end

return M
