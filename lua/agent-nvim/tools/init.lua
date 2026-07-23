local M = {}

function M.register_all()
  local registry = require("agent-nvim.mcp.registry")
  registry.reset()

  require("agent-nvim.tools.files")
  require("agent-nvim.tools.buffers")
  require("agent-nvim.tools.navigation")
  require("agent-nvim.tools.lsp")
  require("agent-nvim.tools.windows")
  require("agent-nvim.tools.quickfix")
  require("agent-nvim.tools.terminal")
  require("agent-nvim.tools.commands")
end

return M
