local M = {}

function M.register_all()
  local resource_registry = require("mcp-nvim.mcp.resources")
  resource_registry.reset()

  require("mcp-nvim.resources.buffers")
  require("mcp-nvim.resources.diagnostics")
  require("mcp-nvim.resources.lists")
  require("mcp-nvim.resources.config")
  require("mcp-nvim.resources.project")
end

return M
