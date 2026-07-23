local resources = require("agent-nvim.mcp.resources")

resources.register("nvim://autocmds", {
  name = "Autocommands",
  description = "All registered autocommands grouped by event",
  mimeType = "application/json",
}, function()
  local autocmds = vim.api.nvim_get_autocmds({})
  local result = {}

  for _, ac in ipairs(autocmds) do
    table.insert(result, {
      event = ac.event,
      group_name = ac.group_name,
      pattern = ac.pattern,
      desc = ac.desc,
      buffer = ac.buflocal and ac.buffer or nil,
    })
  end

  return {
    uri = "nvim://autocmds",
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)

resources.register("nvim://options", {
  name = "Editor Options",
  description = "Key Neovim option values for the current buffer/window",
  mimeType = "application/json",
}, function()
  local buf = vim.api.nvim_get_current_buf()
  local opts = {
    filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
    shiftwidth = vim.api.nvim_get_option_value("shiftwidth", { buf = buf }),
    tabstop = vim.api.nvim_get_option_value("tabstop", { buf = buf }),
    expandtab = vim.api.nvim_get_option_value("expandtab", { buf = buf }),
    textwidth = vim.api.nvim_get_option_value("textwidth", { buf = buf }),
    fileencoding = vim.api.nvim_get_option_value("fileencoding", { buf = buf }),
    eol = vim.api.nvim_get_option_value("endofline", { buf = buf }),
    modified = vim.api.nvim_get_option_value("modified", { buf = buf }),
    readonly = vim.api.nvim_get_option_value("readonly", { buf = buf }),
    spell = vim.api.nvim_get_option_value("spell", { win = 0 }),
    wrap = vim.api.nvim_get_option_value("wrap", { win = 0 }),
    number = vim.api.nvim_get_option_value("number", { win = 0 }),
    relativenumber = vim.api.nvim_get_option_value("relativenumber", { win = 0 }),
  }

  return {
    uri = "nvim://options",
    mimeType = "application/json",
    text = vim.json.encode(opts),
  }
end)

resources.register("nvim://plugins", {
  name = "Loaded Plugins",
  description = "List of all installed/loaded plugins",
  mimeType = "application/json",
}, function()
  local plugins = {}

  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    for _, plugin in ipairs(lazy.plugins()) do
      table.insert(plugins, {
        name = plugin.name or plugin[1],
        loaded = plugin._.loaded ~= nil,
        dir = plugin.dir,
      })
    end
  else
    local packpath = vim.o.packpath
    for _, path in ipairs(vim.split(packpath, ",")) do
      for _, dir in ipairs(vim.fn.glob(path .. "/pack/*/start/*", false, true)) do
        table.insert(plugins, { name = vim.fn.fnamemodify(dir, ":t"), loaded = true, dir = dir })
      end
      for _, dir in ipairs(vim.fn.glob(path .. "/pack/*/opt/*", false, true)) do
        table.insert(plugins, { name = vim.fn.fnamemodify(dir, ":t"), loaded = false, dir = dir })
      end
    end
  end

  return {
    uri = "nvim://plugins",
    mimeType = "application/json",
    text = vim.json.encode(plugins),
  }
end)

-- Template: keymaps by mode
resources.register_template("nvim://keymaps/{mode}", {
  name = "Keymaps by Mode",
  description = "All keymaps for a specific mode (n=normal, i=insert, v=visual, x=visual block)",
  mimeType = "application/json",
}, function(params)
  local mode = params.mode
  if not mode or #mode == 0 then
    return nil
  end

  local maps = vim.api.nvim_get_keymap(mode)
  local buf_maps = vim.api.nvim_buf_get_keymap(0, mode)

  local result = {}
  for _, map in ipairs(maps) do
    table.insert(result, {
      lhs = map.lhs,
      rhs = map.rhs or (map.callback and "<Lua function>") or "",
      desc = map.desc or "",
      buffer = false,
    })
  end
  for _, map in ipairs(buf_maps) do
    table.insert(result, {
      lhs = map.lhs,
      rhs = map.rhs or (map.callback and "<Lua function>") or "",
      desc = map.desc or "",
      buffer = true,
    })
  end

  return {
    uri = "nvim://keymaps/" .. mode,
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)
