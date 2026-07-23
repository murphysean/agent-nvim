local registry = require("agent-nvim.mcp.registry")

local function has_nvchad_term()
  local ok, term = pcall(require, "nvchad.term")
  if ok then
    return term
  end
  return nil
end

local function nvchad_pos(direction)
  if direction == "vertical" then
    return "vsp"
  elseif direction == "float" then
    return "float"
  else
    return "sp"
  end
end

registry.register("terminal_open", {
  annotations = {
    title = "Open Terminal",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = false,
    openWorldHint = true,
  },
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
  local nvterm = has_nvchad_term()

  if nvterm then
    local opts = {
      id = "mcp_term_" .. nvchad_pos(direction),
      pos = nvchad_pos(direction),
    }
    if args.command then
      opts.cmd = args.command
    end
    nvterm.toggle(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local chan = vim.bo[bufnr].channel
    return vim.json.encode({ bufnr = bufnr, channel = chan })
  end

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
  annotations = {
    title = "Send to Terminal",
    readOnlyHint = false,
    destructiveHint = true,
    idempotentHint = false,
    openWorldHint = true,
  },
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
