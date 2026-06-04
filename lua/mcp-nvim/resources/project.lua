local resources = require("mcp-nvim.mcp.resources")

local cache = {}
local CACHE_TTL = 5 -- seconds

local function cached_system(cmd, key)
  local now = vim.loop.now() / 1000
  if cache[key] and (now - cache[key].time) < CACHE_TTL then
    return cache[key].output, cache[key].exit_code
  end
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  cache[key] = { output = output, exit_code = exit_code, time = now }
  return output, exit_code
end

resources.register("nvim://cwd", {
  name = "Working Directory",
  description = "Current working directory and top-level file/directory listing",
  mimeType = "application/json",
}, function()
  local cwd = vim.fn.getcwd()
  local entries = vim.fn.readdir(cwd)

  local files = {}
  local dirs = {}
  for _, entry in ipairs(entries) do
    if entry:sub(1, 1) ~= "." then
      local full = cwd .. "/" .. entry
      if vim.fn.isdirectory(full) == 1 then
        table.insert(dirs, entry)
      else
        table.insert(files, entry)
      end
    end
  end

  table.sort(dirs)
  table.sort(files)

  return {
    uri = "nvim://cwd",
    mimeType = "application/json",
    text = vim.json.encode({
      path = cwd,
      directories = dirs,
      files = files,
    }),
  }
end)

resources.register("nvim://roots", {
  name = "Client Roots",
  description = "Filesystem roots declared by the connected MCP client",
  mimeType = "application/json",
}, function()
  local roots_module = require("mcp-nvim.mcp.roots")
  return {
    uri = "nvim://roots",
    mimeType = "application/json",
    text = vim.json.encode({
      roots = roots_module.get(),
      paths = roots_module.list_paths(),
    }),
  }
end)

resources.register("nvim://git/status", {
  name = "Git Status",
  description = "Current git status (branch, modified/staged/untracked files)",
  mimeType = "application/json",
}, function()
  local result = {
    branch = "",
    files = {},
  }

  local branch, branch_exit = cached_system("git rev-parse --abbrev-ref HEAD 2>/dev/null", "git_branch")
  if branch_exit == 0 then
    result.branch = vim.trim(branch)
  end

  local status, status_exit = cached_system("git status --porcelain 2>/dev/null", "git_status")
  if status_exit == 0 then
    for line in status:gmatch("[^\n]+") do
      local xy = line:sub(1, 2)
      local file = line:sub(4)
      table.insert(result.files, {
        status = vim.trim(xy),
        file = file,
      })
    end
  end

  return {
    uri = "nvim://git/status",
    mimeType = "application/json",
    text = vim.json.encode(result),
  }
end)
