--- Per-instance HTTP MCP lockfile.
---
--- Each running nvim with mcp-nvim writes a lockfile under
--- $XDG_RUNTIME_DIR/mcp-nvim/<pid>.json so external clients (Claude Code,
--- mcp-inspector, etc.) can discover which port belongs to which nvim/cwd.
---
--- Schema:
---   { pid, cwd, servername, url, authToken }
---
--- Atomic writes: write to <pid>.json.tmp, then rename. Stale entries from
--- crashed nvims are GC'd on startup by checking pid liveness with
--- vim.loop.kill(pid, 0).

local uv = vim.uv or vim.loop
local json = require("mcp-nvim.json")

local M = {}

local current_path = nil

local function lock_dir()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if runtime and runtime ~= "" then
    return runtime .. "/mcp-nvim"
  end
  return vim.fn.stdpath("state") .. "/mcp-nvim"
end

local function ensure_dir(dir)
  local stat = uv.fs_stat(dir)
  if not stat then
    uv.fs_mkdir(dir, tonumber("700", 8))
    return
  end
  if stat.type ~= "directory" then
    return
  end
  -- Force 0700 even if pre-existing (in case it was created loosely)
  uv.fs_chmod(dir, tonumber("700", 8))
end

local function pid_alive(pid)
  if not pid or pid <= 0 then
    return false
  end
  -- vim.loop.kill(pid, 0) returns 0 if alive, -ESRCH if not.
  local ok, ret = pcall(uv.kill, pid, 0)
  if not ok then
    return false
  end
  return ret == 0
end

local function gen_token()
  -- 16 random bytes → 32 hex chars (128-bit auth token).
  local bytes = uv.random(16)
  if not bytes then
    error("lockfile: uv.random failed — cannot generate secure auth token")
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

--- Remove stale lockfiles whose owning pid is dead.
--- Called on plugin startup.
function M.gc_stale()
  local dir = lock_dir()
  local stat = uv.fs_stat(dir)
  if not stat or stat.type ~= "directory" then
    return
  end

  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end

  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if entry_type == "file" and name:match("%.json$") then
      local path = dir .. "/" .. name
      local fd = uv.fs_open(path, "r", tonumber("600", 8))
      if fd then
        local fstat = uv.fs_fstat(fd)
        local data = fstat and uv.fs_read(fd, fstat.size, 0) or nil
        uv.fs_close(fd)
        if data then
          local ok, parsed = pcall(json.decode, data)
          if ok and parsed and parsed.pid and not pid_alive(parsed.pid) then
            uv.fs_unlink(path)
          end
        end
      end
    end
  end
end

--- Write a lockfile for this nvim instance.
--- Returns the auth token (caller stashes it for HTTP request validation).
--- Atomic: write tmp, rename.
function M.write(opts)
  local dir = lock_dir()
  ensure_dir(dir)

  local pid = uv.os_getpid()
  local path = string.format("%s/%d.json", dir, pid)
  local token_ok, token = pcall(gen_token)
  if not token_ok then
    return nil
  end

  local payload = json.encode({
    pid = pid,
    cwd = opts.cwd or vim.fn.getcwd(),
    servername = opts.servername or vim.v.servername,
    url = opts.url,
    authToken = token,
  })

  local tmp = path .. ".tmp"
  local fd = uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return nil
  end
  uv.fs_write(fd, payload, 0)
  uv.fs_close(fd)

  if not uv.fs_rename(tmp, path) then
    uv.fs_unlink(tmp)
    return nil
  end

  current_path = path
  return token
end

--- Remove this instance's lockfile.
--- Idempotent.
function M.remove()
  if current_path then
    uv.fs_unlink(current_path)
    current_path = nil
  end
end

--- Return the current lockfile path (for status / debugging).
function M.path()
  return current_path
end

--- Return the lock directory (for status / debugging).
function M.dir()
  return lock_dir()
end

return M
