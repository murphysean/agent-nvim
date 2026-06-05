local M = {}

function M.register_all()
  local registry = require("mcp-nvim.mcp.registry")
  registry.reset()

  require("mcp-nvim.tools.files")
  require("mcp-nvim.tools.buffers")
  require("mcp-nvim.tools.navigation")
  require("mcp-nvim.tools.lsp")
  require("mcp-nvim.tools.windows")
  require("mcp-nvim.tools.quickfix")
  require("mcp-nvim.tools.terminal")
  require("mcp-nvim.tools.commands")
end

return M
