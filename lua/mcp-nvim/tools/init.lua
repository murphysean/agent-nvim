local M = {}

function M.register_all()
  local registry = require("mcp-nvim.mcp.registry")
  registry.reset()

  require("mcp-nvim.tools.buffers")
  require("mcp-nvim.tools.windows")
  require("mcp-nvim.tools.navigation")
  require("mcp-nvim.tools.editing")
  require("mcp-nvim.tools.lsp")
  require("mcp-nvim.tools.diagnostics")
  require("mcp-nvim.tools.commands")
  require("mcp-nvim.tools.quickfix")
  require("mcp-nvim.tools.marks")
  require("mcp-nvim.tools.terminal")
end

return M
