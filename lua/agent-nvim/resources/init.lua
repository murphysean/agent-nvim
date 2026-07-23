local M = {}

function M.register_all()
  local resource_registry = require("agent-nvim.mcp.resources")
  resource_registry.reset()

  require("agent-nvim.resources.buffers")
  require("agent-nvim.resources.diagnostics")
  require("agent-nvim.resources.lists")
  require("agent-nvim.resources.config")
  require("agent-nvim.resources.project")
end

return M
