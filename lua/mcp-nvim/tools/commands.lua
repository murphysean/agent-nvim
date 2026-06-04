local registry = require("mcp-nvim.mcp.registry")

local function code_execution_allowed()
  local config = require("mcp-nvim").config
  return config.allow_code_execution ~= false
end

registry.register("nvim_exec", {
  description = "Execute a Neovim Ex command (like typing ':' followed by a command). Returns the output. WARNING: executes arbitrary code with full system access. Disable with allow_code_execution = false.",
  inputSchema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "The Ex command to execute (without the leading ':')",
      },
    },
    required = { "command" },
  },
}, function(args)
  if not code_execution_allowed() then
    error("Code execution is disabled (allow_code_execution = false)")
  end
  local output = vim.api.nvim_exec2(args.command, { output = true })
  return output.output or ""
end)

registry.register("nvim_eval", {
  description = "Evaluate a Vimscript expression and return the result. WARNING: can execute arbitrary code via system(). Disable with allow_code_execution = false.",
  inputSchema = {
    type = "object",
    properties = {
      expr = {
        type = "string",
        description = "Vimscript expression to evaluate",
      },
    },
    required = { "expr" },
  },
}, function(args)
  if not code_execution_allowed() then
    error("Code execution is disabled (allow_code_execution = false)")
  end
  local result = vim.fn.eval(args.expr)
  if type(result) == "string" then
    return result
  end
  return vim.json.encode(result)
end)

registry.register("lua_exec", {
  description = "Execute Lua code in the Neovim Lua runtime with full access to vim.api, vim.fn, io, os, etc. Return a value by assigning to a local 'result' variable. WARNING: unsandboxed arbitrary code execution. Disable with allow_code_execution = false.",
  inputSchema = {
    type = "object",
    properties = {
      code = {
        type = "string",
        description = "Lua code to execute",
      },
    },
    required = { "code" },
  },
}, function(args)
  if not code_execution_allowed() then
    error("Code execution is disabled (allow_code_execution = false)")
  end
  local chunk, err = load("local result; " .. args.code .. "; return result")
  if not chunk then
    error("Lua syntax error: " .. (err or "unknown"))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("Lua runtime error: " .. tostring(result))
  end
  if result == nil then
    return "OK (no return value)"
  end
  if type(result) == "string" then
    return result
  end
  return vim.json.encode(result)
end)

registry.register("keymap_list", {
  description = "List keymaps for a given mode",
  inputSchema = {
    type = "object",
    properties = {
      mode = {
        type = "string",
        description = "Mode: 'n' (normal), 'i' (insert), 'v' (visual), 'x' (visual block), etc. Default 'n'.",
      },
      buffer_local = {
        type = "boolean",
        description = "Only show buffer-local keymaps. Default false.",
      },
    },
  },
}, function(args)
  local mode = args.mode or "n"
  local maps

  if args.buffer_local then
    maps = vim.api.nvim_buf_get_keymap(0, mode)
  else
    maps = vim.api.nvim_get_keymap(mode)
  end

  local result = {}
  for _, map in ipairs(maps) do
    table.insert(result, {
      lhs = map.lhs,
      rhs = map.rhs or (map.callback and "<Lua function>") or "",
      desc = map.desc or "",
      buffer = map.buffer ~= 0,
    })
  end

  return vim.json.encode(result)
end)

registry.register("user_command_list", {
  description = "List available user-defined commands",
  inputSchema = {
    type = "object",
    properties = {
      buffer_local = {
        type = "boolean",
        description = "Only show buffer-local commands. Default false.",
      },
    },
  },
}, function(args)
  local cmds
  if args.buffer_local then
    cmds = vim.api.nvim_buf_get_commands(0, {})
  else
    cmds = vim.api.nvim_get_commands({})
  end

  local result = {}
  for name, cmd in pairs(cmds) do
    table.insert(result, {
      name = name,
      definition = cmd.definition or "",
      nargs = cmd.nargs,
      description = cmd.definition or "",
    })
  end

  return vim.json.encode(result)
end)

registry.register("option_get", {
  description = "Get the value of a Neovim option",
  inputSchema = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "Option name (e.g. 'shiftwidth', 'filetype', 'expandtab')",
      },
      scope = {
        type = "string",
        enum = { "global", "local" },
        description = "Option scope. Default: effective value.",
      },
    },
    required = { "name" },
  },
}, function(args)
  local opts = {}
  if args.scope == "global" then
    opts.scope = "global"
  elseif args.scope == "local" then
    opts.buf = vim.api.nvim_get_current_buf()
  end

  local value = vim.api.nvim_get_option_value(args.name, opts)
  return vim.json.encode({ name = args.name, value = value })
end)

registry.register("option_set", {
  description = "Set a Neovim option value",
  inputSchema = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "Option name",
      },
      value = {
        description = "Value to set (type depends on the option)",
      },
      scope = {
        type = "string",
        enum = { "global", "local" },
        description = "Option scope. Default: local.",
      },
    },
    required = { "name", "value" },
  },
}, function(args)
  local opts = {}
  if args.scope == "global" then
    opts.scope = "global"
  else
    opts.buf = vim.api.nvim_get_current_buf()
  end

  vim.api.nvim_set_option_value(args.name, args.value, opts)
  return string.format("Option '%s' set to %s", args.name, vim.inspect(args.value))
end)
