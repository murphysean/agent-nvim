--- ACP fs/* handlers — the editor side of the ACP filesystem methods.
---
--- The agent calls these on us when it wants to read or write a file. We
--- proxy through Neovim's buffer API so that:
---   - `fs/read_text_file` returns the in-memory buffer contents when the
---     file is open (matches the user's actual editing state, not stale disk),
---     and falls back to disk otherwise.
---   - `fs/write_text_file` updates the buffer and (depending on phase 5
---     wiring) routes through review.lua for diff approval before writing.
---
--- Per ACP, paths must be absolute. Both methods take {sessionId, path} and
--- read also accepts {line, limit} (1-based, both optional).

local uv = vim.loop

local M = {}

local function find_buf_by_path(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name == path then
        return b
      end
    end
  end
  return nil
end

local function read_file_disk(path)
  local fd = uv.fs_open(path, "r", 420) -- 0644
  if not fd then
    return nil, "cannot open file: " .. path
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, "cannot stat file: " .. path
  end
  local data = uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  return data, nil
end

local function slice_lines(content, line, limit)
  if not line and not limit then
    return content
  end
  local lines = vim.split(content, "\n", { plain = true })
  local start_idx = line or 1
  if start_idx < 1 then
    start_idx = 1
  end
  local end_idx = limit and (start_idx + limit - 1) or #lines
  if end_idx > #lines then
    end_idx = #lines
  end
  if start_idx > #lines then
    return ""
  end
  local out = {}
  for i = start_idx, end_idx do
    table.insert(out, lines[i])
  end
  return table.concat(out, "\n")
end

--- fs/read_text_file handler. params: { sessionId, path, line?, limit? }.
--- Calls respond({content=string}) on success, respond(err, true) on failure.
function M.read_text_file(params, respond)
  local path = params and params.path
  if type(path) ~= "string" or path == "" then
    respond({ code = -32602, message = "fs/read_text_file: missing path" }, true)
    return
  end
  if path:sub(1, 1) ~= "/" then
    respond({ code = -32602, message = "fs/read_text_file: path must be absolute" }, true)
    return
  end

  local content
  local buf = find_buf_by_path(path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    content = table.concat(lines, "\n")
  else
    local data, err = read_file_disk(path)
    if not data then
      respond({ code = -32000, message = err }, true)
      return
    end
    content = data
  end

  respond({ content = slice_lines(content, params.line, params.limit) })
end

--- Apply a write directly: ensure parent dir, write file, reload buffer.
local function apply_write(path, content, respond)
  local parent = vim.fn.fnamemodify(path, ":h")
  if parent and parent ~= "" and parent ~= "." then
    vim.fn.mkdir(parent, "p")
  end

  local fd = uv.fs_open(path, "w", 420) -- 0644
  if not fd then
    respond({ code = -32000, message = "cannot open for write: " .. path }, true)
    return
  end
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)

  local buf = find_buf_by_path(path)
  if buf then
    vim.schedule(function()
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("checktime")
      end)
    end)
  end

  respond(vim.NIL)
end

--- fs/write_text_file handler. params: { sessionId, path, content }.
---
--- Routes through review.lua for an in-buffer diff approval when:
---   - the user has not opted out (config.review_edits == true), AND
---   - the path corresponds to a buffer we can show the diff in (existing
---     file or one we can load).
---
--- For brand-new files (no existing content), no diff is meaningful and we
--- skip review even with review_edits=true. The chat-level
--- session/request_permission flow handles approval for those cases.
function M.write_text_file(params, respond)
  local path = params and params.path
  local content = params and params.content
  if type(path) ~= "string" or path == "" then
    respond({ code = -32602, message = "fs/write_text_file: missing path" }, true)
    return
  end
  if type(content) ~= "string" then
    respond({ code = -32602, message = "fs/write_text_file: missing content" }, true)
    return
  end

  local cfg = require("mcp-nvim").config or {}
  local exists = uv.fs_stat(path) ~= nil

  if not cfg.review_edits or not exists then
    apply_write(path, content, respond)
    return
  end

  -- Show diff in the buffer for this file; create/load the buffer if needed.
  vim.schedule(function()
    local util = require("mcp-nvim.util")

    local bufnr = find_buf_by_path(path)
    if not bufnr then
      bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
    end

    util.ensure_code_window(bufnr)
    pcall(vim.api.nvim_set_current_buf, bufnr)

    local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines = vim.split(content, "\n", { plain = true })
    -- Preserve "no trailing newline" semantics: if content ended with \n,
    -- vim.split leaves an empty last element — drop it so the diff doesn't
    -- show a phantom blank line.
    if content:sub(-1) == "\n" and new_lines[#new_lines] == "" then
      table.remove(new_lines)
    end

    local review = require("mcp-nvim.review")
    review.show_diff(bufnr, 1, old_lines, new_lines, function(decision, reason)
      if decision == "accept" then
        apply_write(path, content, respond)
      elseif decision == "reject" then
        local msg = reason and ("user rejected: " .. reason) or "user rejected the write"
        respond({ code = -32000, message = msg }, true)
      else
        -- "edit" decision: tell the agent it was rejected so it doesn't
        -- assume the file matches `content`. The user is now editing manually.
        respond({ code = -32000, message = "user took over editing manually" }, true)
      end
    end)
  end)
end

return M
