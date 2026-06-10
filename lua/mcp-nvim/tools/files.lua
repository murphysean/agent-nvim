local registry = require("mcp-nvim.mcp.registry")

local function get_workspace()
  return vim.fn.getcwd()
end

local function resolve_path(input_path)
  local workspace = get_workspace()

  local resolved
  if input_path:sub(1, 1) == "/" then
    resolved = input_path
  else
    resolved = workspace .. "/" .. input_path
  end

  resolved = vim.fn.resolve(vim.fn.fnamemodify(resolved, ":p"))

  if resolved:sub(-1) == "/" and #resolved > 1 then
    resolved = resolved:sub(1, -2)
  end

  if resolved:sub(1, #workspace) ~= workspace then
    return nil, string.format("Path '%s' is outside the workspace (%s)", input_path, workspace)
  end

  return resolved
end

registry.register("read_file", {
  annotations = {
    title = "Read File",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Read a file and return its content with line numbers. "
    .. "Paths are relative to the workspace root. "
    .. "Use start_line/end_line to read a specific range of a large file.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path (relative to workspace, or absolute within workspace)",
      },
      start_line = {
        type = "integer",
        description = "Start line (1-indexed, inclusive). Default: 1.",
      },
      end_line = {
        type = "integer",
        description = "End line (1-indexed, inclusive). Default: end of file.",
      },
    },
    required = { "path" },
  },
}, function(args)
  local filepath, err = resolve_path(args.path)
  if not filepath then
    error(err)
  end

  if vim.fn.filereadable(filepath) ~= 1 then
    error("File not found: " .. args.path)
  end

  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    vim.cmd("badd " .. vim.fn.fnameescape(filepath))
    bufnr = vim.fn.bufnr(filepath)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local start_idx = (args.start_line or 1) - 1
  local end_idx = args.end_line or total_lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)

  local numbered = {}
  for i, line in ipairs(lines) do
    local line_num = start_idx + i
    table.insert(numbered, string.format("%4d\t%s", line_num, line))
  end

  local rel_path = filepath:sub(#get_workspace() + 2)
  local header = string.format("File: %s (%d lines total)", rel_path, total_lines)
  return header .. "\n" .. table.concat(numbered, "\n")
end)

registry.register("edit_file", {
  annotations = {
    title = "Edit File",
    readOnlyHint = false,
    destructiveHint = false,
    idempotentHint = false,
    openWorldHint = false,
  },
  async = true,
  description = "Edit a file by finding an exact string match and replacing it. "
    .. "The file is saved to disk automatically after the edit. "
    .. "The 'old_string' must appear exactly once in the file. "
    .. "Always read_file first to see current content.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path (relative to workspace, or absolute within workspace)",
      },
      old_string = {
        type = "string",
        description = "The exact text to find. Must match exactly once in the file.",
      },
      new_string = {
        type = "string",
        description = "The replacement text. Use empty string to delete the matched text.",
      },
    },
    required = { "path", "old_string", "new_string" },
  },
}, function(args, resolve, progress_fn)
  local config = require("mcp-nvim").config
  local filepath, err = resolve_path(args.path)
  if not filepath then
    error(err)
  end

  if vim.fn.filereadable(filepath) ~= 1 then
    error("File not found: " .. args.path)
  end

  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    vim.cmd("badd " .. vim.fn.fnameescape(filepath))
    bufnr = vim.fn.bufnr(filepath)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  local before = args.old_string
  local after = args.new_string

  local start_pos, end_pos = content:find(before, 1, true)
  if not start_pos then
    local preview_lines = {}
    for i, line in ipairs(lines) do
      if i <= 20 then
        table.insert(preview_lines, string.format("%4d | %s", i, line))
      end
    end
    local preview = table.concat(preview_lines, "\n")
    error(
      "No match found for 'old_string'. "
        .. "The file may have changed since you last read it, or there may be a whitespace mismatch.\n\n"
        .. "Current content (first 20 lines):\n"
        .. preview
    )
  end

  local second_start = content:find(before, end_pos + 1, true)
  if second_start then
    local function line_of(pos)
      local count = 1
      for i = 1, pos - 1 do
        if content:sub(i, i) == "\n" then
          count = count + 1
        end
      end
      return count
    end
    error(
      string.format(
        "Multiple matches found (at line %d and line %d). "
          .. "Include more surrounding context in 'old_string' to uniquely identify the text.",
        line_of(start_pos),
        line_of(second_start)
      )
    )
  end

  local function line_of(pos)
    local count = 1
    for i = 1, pos - 1 do
      if content:sub(i, i) == "\n" then
        count = count + 1
      end
    end
    return count
  end

  local start_line = line_of(start_pos)
  local old_lines = vim.split(before, "\n", { plain = true })
  local new_lines_split = vim.split(after, "\n", { plain = true })
  local rel_path = filepath:sub(#get_workspace() + 2)

  local function apply_edit()
    local new_content = content:sub(1, start_pos - 1) .. after .. content:sub(end_pos + 1)
    local new_lines = vim.split(new_content, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)
    local line_diff = #new_lines - #lines
    local result_msg = string.format("Edited %s at line %d", rel_path, start_line)
    if line_diff ~= 0 then
      result_msg = result_msg .. string.format(" (%+d lines)", line_diff)
    end
    result_msg = result_msg .. string.format(". File saved (%d lines total).", #new_lines)
    return result_msg
  end

  if config.review_edits == false then
    resolve(apply_edit())
    return
  end

  local review = require("mcp-nvim.review")

  require("mcp-nvim.util").ensure_code_window(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
  vim.cmd("normal! zz")

  review.show_diff(bufnr, start_line, old_lines, new_lines_split, function(decision, reason)
    if decision == "accept" then
      local msg = apply_edit()
      resolve(msg)
    elseif decision == "reject" then
      local msg = "Edit rejected by user."
      if reason then
        msg = msg .. " Reason: " .. reason
      end
      resolve(msg, true)
    elseif decision == "edit" then
      apply_edit()
      vim.api.nvim_win_set_cursor(0, { start_line, 0 })
      vim.notify("MCP: Edit applied — make your changes, :w to finalize", vim.log.levels.INFO)
      local end_line = start_line + #new_lines_split - 1
      local autocmd_id
      autocmd_id = vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = bufnr,
        once = true,
        callback = function()
          local final_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
          local final_content = table.concat(final_lines, "\n")
          local proposed_content = table.concat(new_lines_split, "\n")
          if final_content == proposed_content then
            resolve(string.format("Edited %s at line %d. User accepted as proposed.", rel_path, start_line))
          else
            resolve(
              string.format(
                "Edited %s at line %d. User modified the edit. Final content at lines %d-%d:\n%s",
                rel_path,
                start_line,
                start_line,
                end_line,
                final_content
              )
            )
          end
        end,
      })
    end
  end, progress_fn)
end)

registry.register("write_file", {
  annotations = {
    title = "Write File",
    readOnlyHint = false,
    destructiveHint = true,
    idempotentHint = true,
    openWorldHint = false,
  },
  async = true,
  description = "Create or overwrite a file with the given content. "
    .. "The file is saved to disk immediately. "
    .. "Use this for new files or complete rewrites. For partial edits, use edit_file instead.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path (relative to workspace, or absolute within workspace). Parent directories are created if needed.",
      },
      content = {
        type = "string",
        description = "Full file content",
      },
    },
    required = { "path", "content" },
  },
}, function(args, resolve, progress_fn)
  local config = require("mcp-nvim").config
  local filepath, err = resolve_path(args.path)
  if not filepath then
    error(err)
  end

  local dir = vim.fn.fnamemodify(filepath, ":h")
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end

  local is_new = vim.fn.filereadable(filepath) ~= 1

  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    vim.cmd("badd " .. vim.fn.fnameescape(filepath))
    bufnr = vim.fn.bufnr(filepath)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  local new_lines = vim.split(args.content, "\n", { plain = true })
  local rel_path = filepath:sub(#get_workspace() + 2)

  local function apply_write()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)
    return string.format("Written %s (%d lines)", rel_path, #new_lines)
  end

  if config.review_edits == false or is_new then
    resolve(apply_write())
    return
  end

  local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local review = require("mcp-nvim.review")

  require("mcp-nvim.util").ensure_code_window(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  review.show_diff(bufnr, 1, old_lines, new_lines, function(decision, reason)
    if decision == "accept" then
      local msg = apply_write()
      resolve(msg)
    elseif decision == "reject" then
      local msg = "Write rejected by user."
      if reason then
        msg = msg .. " Reason: " .. reason
      end
      resolve(msg, true)
    elseif decision == "edit" then
      apply_write()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.notify("MCP: Write applied — make your changes, :w to finalize", vim.log.levels.INFO)
      vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = bufnr,
        once = true,
        callback = function()
          local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local final_content = table.concat(final_lines, "\n")
          local proposed_content = table.concat(new_lines, "\n")
          if final_content == proposed_content then
            resolve(string.format("Written %s (%d lines). User accepted as proposed.", rel_path, #new_lines))
          else
            resolve(
              string.format("Written %s. User modified the content. Final file (%d lines).", rel_path, #final_lines)
            )
          end
        end,
      })
    end
  end, progress_fn)
end)

registry.register("run", {
  annotations = {
    title = "Run Shell Command",
    readOnlyHint = false,
    destructiveHint = true,
    idempotentHint = false,
    openWorldHint = true,
  },
  description = "Execute a shell command and return its output (stdout, stderr, exit code). "
    .. "The working directory is the workspace root. "
    .. "Use for builds, tests, git, file operations, etc.",
  inputSchema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "Shell command to execute",
      },
      timeout = {
        type = "integer",
        description = "Timeout in milliseconds. Default: 30000 (30 seconds).",
      },
    },
    required = { "command" },
  },
}, function(args)
  local config = require("mcp-nvim").config
  if config.allow_code_execution == false then
    error("Code execution is disabled (allow_code_execution = false)")
  end

  local cwd = get_workspace()
  local timeout = args.timeout or 30000

  local result = vim.system({ "sh", "-c", args.command }, { text = true, cwd = cwd, timeout = timeout }):wait()

  local output = {}
  if result.stdout and result.stdout ~= "" then
    table.insert(output, result.stdout)
  end
  if result.stderr and result.stderr ~= "" then
    table.insert(output, "STDERR:\n" .. result.stderr)
  end

  local text = table.concat(output, "\n")
  if text == "" then
    text = "(no output)"
  end

  return vim.json.encode({
    exit_code = result.code,
    output = text,
  })
end)

registry.register("list_files", {
  annotations = {
    title = "List Files",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "List files and directories in the workspace. "
    .. "Returns names, types, and sizes. Paths are relative to workspace root.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Directory path relative to workspace. Default: workspace root.",
      },
      glob = {
        type = "string",
        description = "Filter by glob pattern (e.g. '*.lua', '*.rs'). Default: show all.",
      },
      recursive = {
        type = "boolean",
        description = "List recursively. Default: false.",
      },
      max_depth = {
        type = "integer",
        description = "Max recursion depth. Default: 5.",
      },
    },
  },
}, function(args)
  local dir_path
  if args.path then
    local resolved, err = resolve_path(args.path)
    if not resolved then
      error(err)
    end
    dir_path = resolved
  else
    dir_path = get_workspace()
  end

  if vim.fn.isdirectory(dir_path) ~= 1 then
    error("Not a directory: " .. (args.path or "."))
  end

  local glob = args.glob
  local recursive = args.recursive == true
  local max_depth = args.max_depth or 5
  local workspace = get_workspace()

  local results = {}

  local function scan(dir, depth)
    if depth > max_depth then
      return
    end

    local handle = vim.loop.fs_scandir(dir)
    if not handle then
      return
    end

    while true do
      local name, ftype = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      if name:sub(1, 1) ~= "." then
        local full_path = dir .. "/" .. name
        local matches = true

        if glob then
          matches = vim.fn.matchstr(name, vim.fn.glob2regpat(glob)) ~= ""
        end

        if matches or (ftype == "directory" and recursive) then
          local entry = {
            name = full_path:sub(#workspace + 2),
            type = ftype or "file",
          }

          if ftype == "file" then
            local stat = vim.loop.fs_stat(full_path)
            if stat then
              entry.size = stat.size
            end
          end

          if matches then
            table.insert(results, entry)
          end
        end

        if ftype == "directory" and recursive then
          scan(full_path, depth + 1)
        end
      end
    end
  end

  scan(dir_path, 1)

  table.sort(results, function(a, b)
    if a.type ~= b.type then
      return a.type == "directory"
    end
    return a.name < b.name
  end)

  return vim.json.encode({
    workspace = workspace,
    count = #results,
    entries = results,
  })
end)

registry.register("search_files", {
  annotations = {
    title = "Search Files",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Search for text across files in the workspace. "
    .. "Returns matching file paths, line numbers, and line content.",
  inputSchema = {
    type = "object",
    properties = {
      pattern = {
        type = "string",
        description = "Text to search for (literal match)",
      },
      glob = {
        type = "string",
        description = "File glob to restrict search (e.g. '**/*.lua'). Default: '**/*'.",
      },
      path = {
        type = "string",
        description = "Subdirectory to search within (relative to workspace). Default: entire workspace.",
      },
    },
    required = { "pattern" },
  },
}, function(args)
  local workspace = get_workspace()
  local search_dir = workspace

  if args.path then
    local resolved, err = resolve_path(args.path)
    if not resolved then
      error(err)
    end
    search_dir = resolved
  end

  if vim.fn.executable("rg") == 1 then
    local cmd = { "rg", "--no-heading", "--line-number", "--color=never", "--fixed-strings" }
    if args.glob then
      table.insert(cmd, "--glob")
      table.insert(cmd, args.glob)
    end
    table.insert(cmd, "--")
    table.insert(cmd, args.pattern)
    table.insert(cmd, search_dir)

    local rg_result = vim.system(cmd, { text = true, timeout = 15000 }):wait()
    local results = {}

    if rg_result.stdout and rg_result.stdout ~= "" then
      for line in rg_result.stdout:gmatch("[^\n]+") do
        local file, lnum, text = line:match("^(.+):(%d+):(.*)$")
        if file then
          if file:sub(1, #workspace) == workspace then
            file = file:sub(#workspace + 2)
          end
          table.insert(results, {
            file = file,
            line = tonumber(lnum),
            text = text,
          })
        end
      end
    end

    return vim.json.encode(results)
  end

  local glob = args.glob or "**/*"
  local escaped = vim.fn.escape(args.pattern, "/\\")

  local saved_cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(search_dir))
  vim.cmd("silent! vimgrep /\\V" .. escaped .. "/j " .. glob)
  vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))

  local qflist = vim.fn.getqflist()
  local results = {}

  for _, item in ipairs(qflist) do
    local file = ""
    if item.bufnr and item.bufnr > 0 then
      file = vim.api.nvim_buf_get_name(item.bufnr)
      if file:sub(1, #workspace) == workspace then
        file = file:sub(#workspace + 2)
      end
    end
    table.insert(results, {
      file = file,
      line = item.lnum,
      text = item.text,
    })
  end

  return vim.json.encode(results)
end)

registry.register("diagnostics", {
  annotations = {
    title = "Get Diagnostics",
    readOnlyHint = true,
    openWorldHint = false,
  },
  description = "Get LSP diagnostics (errors, warnings, hints) for the workspace or a specific file.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path to get diagnostics for. Default: all open files.",
      },
      severity = {
        type = "string",
        enum = { "error", "warn", "info", "hint" },
        description = "Filter by minimum severity. Default: all.",
      },
    },
  },
}, function(args)
  local workspace = get_workspace()
  local bufnr = nil

  if args.path then
    local filepath, err = resolve_path(args.path)
    if not filepath then
      error(err)
    end
    bufnr = vim.fn.bufnr(filepath)
    if bufnr == -1 then
      return vim.json.encode({})
    end
  end

  local opts = {}
  if args.severity then
    local severity_map = {
      error = vim.diagnostic.severity.ERROR,
      warn = vim.diagnostic.severity.WARN,
      info = vim.diagnostic.severity.INFO,
      hint = vim.diagnostic.severity.HINT,
    }
    opts.severity = severity_map[args.severity]
  end

  local diagnostics = vim.diagnostic.get(bufnr, opts)

  local severity_names = { "ERROR", "WARN", "INFO", "HINT" }
  local result = {}
  for _, d in ipairs(diagnostics) do
    local file = ""
    if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
      file = vim.api.nvim_buf_get_name(d.bufnr)
      if file:sub(1, #workspace) == workspace then
        file = file:sub(#workspace + 2)
      end
    end
    table.insert(result, {
      file = file,
      line = d.lnum + 1,
      column = d.col + 1,
      message = d.message,
      severity = severity_names[d.severity] or "UNKNOWN",
      source = d.source,
    })
  end

  return vim.json.encode(result)
end)
