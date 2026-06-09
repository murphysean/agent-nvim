local M = {}

function M.register_all()
  local prompt_registry = require("mcp-nvim.mcp.prompts")
  prompt_registry.reset()

  -- External MCP prompts — exposed to clients via prompts/list.
  -- These are neovim-specific agent workflows that leverage live editor state.
  require("mcp-nvim.prompts.neovim_prefer")
  require("mcp-nvim.prompts.code_tour")
  require("mcp-nvim.prompts.pair_program")
  require("mcp-nvim.prompts.diagnostic_repair")
  require("mcp-nvim.prompts.navigate")
  require("mcp-nvim.prompts.context_switch")
  require("mcp-nvim.prompts.pr_review_tour")
  require("mcp-nvim.prompts.pr_review_report")

  -- Internal prompts (prefixed with _) are NOT registered here.
  -- They are used directly by our sampling/autocomplete system:
  --   _complete.lua  → used by autocomplete.lua and completion/blink.lua
  --   _explain.lua   → used internally for explain sampling
  --   _fix.lua       → used internally for fix sampling
  --   _refactor.lua  → used internally for refactor sampling
  --   _review.lua    → used internally for review sampling
end

return M
