local registry = require("mcp-nvim.mcp.registry")

registry.register("terminal_open", {
  description = "Open a terminal in a split window",
  inputSchema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "Command to run in the terminal. Default: user's shell.",
      },
      direction = {
        type = "string",
        enum = { "horizontal", "vertical", "tab", "float" },
        description = "Where to open the terminal. Default: horizontal split.",
      },
      size = {
        type = "integer",
        description = "Size (height for horizontal, width for vertical). Default: half.",
      },
    },
  },
}, function(args)
  local direction = args.direction or "horizontal"

  if direction == "tab" then
    vim.cmd("tabnew")
  elseif direction == "vertical" then
    vim.cmd("vsplit")
    if args.size then
      vim.cmd("vertical resize " .. args.size)
    end
  elseif direction == "float" then
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
    })
  else
    vim.cmd("split")
    if args.size then
      vim.cmd("resize " .. args.size)
    end
  end

  local cmd = args.command and ("term " .. args.command) or "term"
  vim.cmd(cmd)

  local bufnr = vim.api.nvim_get_current_buf()
  local chan = vim.bo[bufnr].channel

  return vim.json.encode({
    bufnr = bufnr,
    channel = chan,
  })
end)

registry.register("terminal_send", {
  description = "Send keystrokes or text to a terminal buffer",
  inputSchema = {
    type = "object",
    properties = {
      buffer = {
        type = "integer",
        description = "Buffer number of the terminal",
      },
      text = {
        type = "string",
        description = "Text to send to the terminal",
      },
      newline = {
        type = "boolean",
        description = "Append a newline (execute the command). Default true.",
      },
    },
    required = { "buffer", "text" },
  },
}, function(args)
  local bufnr = args.buffer
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid terminal buffer")
  end

  local chan = vim.bo[bufnr].channel
  if not chan or chan == 0 then
    error("Buffer is not a terminal")
  end

  local text = args.text
  if args.newline ~= false then
    text = text .. "\n"
  end

  vim.api.nvim_chan_send(chan, text)
  return "Sent to terminal"
end)

registry.register("notify", {
  description = "Show a notification message to the user in Neovim",
  inputSchema = {
    type = "object",
    properties = {
      message = {
        type = "string",
        description = "Message to display",
      },
      level = {
        type = "string",
        enum = { "info", "warn", "error" },
        description = "Notification level. Default: info.",
      },
    },
    required = { "message" },
  },
}, function(args)
  local levels = {
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  }
  local level = levels[args.level or "info"]
  vim.notify(args.message, level)
  return "Notification sent"
end)

registry.register("nvim_info", {
  description = "Get information about the current Neovim instance: version, cwd, loaded plugins, runtimepath",
  inputSchema = {
    type = "object",
    properties = vim.empty_dict(),
  },
}, function(_)
  local version = vim.version()
  local result = {
    version = string.format("%d.%d.%d", version.major, version.minor, version.patch),
    cwd = vim.fn.getcwd(),
    vimrc = vim.env.MYVIMRC or "",
    plugins = {},
  }

  local packpath = vim.o.packpath
  if packpath then
    for _, path in ipairs(vim.split(packpath, ",")) do
      local start_dir = path .. "/pack/*/start/*"
      local opt_dir = path .. "/pack/*/opt/*"
      for _, dir in ipairs(vim.fn.glob(start_dir, false, true)) do
        table.insert(result.plugins, vim.fn.fnamemodify(dir, ":t"))
      end
      for _, dir in ipairs(vim.fn.glob(opt_dir, false, true)) do
        table.insert(result.plugins, vim.fn.fnamemodify(dir, ":t") .. " (opt)")
      end
    end
  end

  -- Also check lazy.nvim if available
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    result.plugins = {}
    local plugins = lazy.plugins()
    for _, plugin in ipairs(plugins) do
      table.insert(result.plugins, plugin.name or plugin[1])
    end
  end

  return vim.json.encode(result)
end)
