local M = {}

function M.register_all()
  local prompt_registry = require("mcp-nvim.mcp.prompts")
  prompt_registry.reset()

  require("mcp-nvim.prompts.complete")
  require("mcp-nvim.prompts.fix")
  require("mcp-nvim.prompts.explain")
  require("mcp-nvim.prompts.refactor")
  require("mcp-nvim.prompts.review")
end

return M
