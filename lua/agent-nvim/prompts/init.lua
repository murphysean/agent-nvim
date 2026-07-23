local M = {}

function M.register_all()
  local prompt_registry = require("agent-nvim.mcp.prompts")
  prompt_registry.reset()

  -- External MCP prompts — exposed to clients via prompts/list.
  -- These are neovim-specific agent workflows that leverage live editor state.
  require("agent-nvim.prompts.neovim_prefer")
  require("agent-nvim.prompts.code_tour")
  require("agent-nvim.prompts.pair_program")
  require("agent-nvim.prompts.diagnostic_repair")
  require("agent-nvim.prompts.navigate")
  require("agent-nvim.prompts.context_switch")
  require("agent-nvim.prompts.pr_review_tour")
  require("agent-nvim.prompts.pr_review_report")

  -- Internal prompts (prefixed with _) are NOT registered here.
  -- They are used directly by our sampling/autocomplete system:
  --   _complete.lua  → used by autocomplete.lua and completion/blink.lua
  --   _explain.lua   → used internally for explain sampling
  --   _fix.lua       → used internally for fix sampling
  --   _refactor.lua  → used internally for refactor sampling
  --   _review.lua    → used internally for review sampling
end

return M
