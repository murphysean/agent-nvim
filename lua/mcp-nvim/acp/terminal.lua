--- ACP terminal/* handlers — run commands in Neovim terminal buffers.
---
--- All terminal commands are executed via termopen() so the user can see
--- them running in a real terminal buffer. Output is captured and tracked
--- per terminal ID for the agent to retrieve.

local M = {}

-- terminalId -> { buf, chan, output, exit_code, signal, exited, waiters }
local terminals = {}
local next_id = 1

local function gen_id()
  local id = "term_" .. next_id
  next_id = next_id + 1
  return id
end

--- terminal/create: spawn a command in a visible terminal buffer.
--- params: { sessionId, command, args?, env?, cwd?, outputByteLimit? }
function M.create(params, respond)
  local command = params and params.command
  if type(command) ~= "string" or command == "" then
    respond({ code = -32602, message = "terminal/create: missing command" }, true)
    return
  end

  local args = params.args or {}
  local cwd = params.cwd or vim.fn.getcwd()
  local byte_limit = params.outputByteLimit or (1024 * 1024)

  -- Build the shell command string for termopen.
  local cmd_parts = { command }
  for _, a in ipairs(args) do
    table.insert(cmd_parts, vim.fn.shellescape(a))
  end
  local cmd_str = table.concat(cmd_parts, " ")

  -- Build env table for termopen.
  local env = nil
  if params.env and #params.env > 0 then
    env = {}
    for _, e in ipairs(params.env) do
      if e.name then
        env[e.name] = e.value or ""
      end
    end
  end

  local term_id = gen_id()
  local term_state = {
    buf = nil,
    chan = nil,
    output = {},
    output_bytes = 0,
    byte_limit = byte_limit,
    exit_code = nil,
    signal = nil,
    exited = false,
    waiters = {},
  }
  terminals[term_id] = term_state

  -- Create a terminal buffer in a small bottom split.
  vim.cmd("botright 10split")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, "acp-terminal://" .. term_id .. " " .. cmd_str)

  local termopen_opts = {
    cwd = cwd,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, chunk in ipairs(data) do
        if chunk ~= "" and term_state.output_bytes < term_state.byte_limit then
          table.insert(term_state.output, chunk)
          term_state.output_bytes = term_state.output_bytes + #chunk
        end
      end
    end,
    on_exit = function(_, code, event)
      term_state.exited = true
      if event == "signal" then
        term_state.exit_code = nil
        term_state.signal = "SIG" .. tostring(code)
      else
        term_state.exit_code = code
        term_state.signal = nil
      end
      -- Wake any waiters.
      for _, waiter in ipairs(term_state.waiters) do
        vim.schedule(function()
          waiter({ exitCode = term_state.exit_code, signal = term_state.signal })
        end)
      end
      term_state.waiters = {}
    end,
  }

  if env then
    termopen_opts.env = env
  end

  local chan = vim.fn.termopen(cmd_str, termopen_opts)
  if chan <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    terminals[term_id] = nil
    respond({ code = -32000, message = "terminal/create: termopen failed" }, true)
    return
  end

  term_state.buf = buf
  term_state.chan = chan

  respond({ terminalId = term_id })
end

--- terminal/output: get current output without waiting.
--- params: { sessionId, terminalId }
function M.output(params, respond)
  local term_id = params and params.terminalId
  local term_state = term_id and terminals[term_id]
  if not term_state then
    respond({ code = -32000, message = "terminal/output: unknown terminalId" }, true)
    return
  end

  local text = table.concat(term_state.output, "\n")
  local truncated = term_state.output_bytes >= term_state.byte_limit

  local result = {
    output = text,
    truncated = truncated,
  }

  if term_state.exited then
    result.exitStatus = {
      exitCode = term_state.exit_code,
      signal = term_state.signal,
    }
  end

  respond(result)
end

--- terminal/wait_for_exit: block until the command finishes.
--- params: { sessionId, terminalId }
--- This is async — we register a waiter and respond later.
function M.wait_for_exit(params, respond)
  local term_id = params and params.terminalId
  local term_state = term_id and terminals[term_id]
  if not term_state then
    respond({ code = -32000, message = "terminal/wait_for_exit: unknown terminalId" }, true)
    return
  end

  if term_state.exited then
    respond({ exitCode = term_state.exit_code, signal = term_state.signal })
    return
  end

  -- Register a waiter — respond will be called when the process exits.
  table.insert(term_state.waiters, function(exit_result)
    respond(exit_result)
  end)
  return "async"
end

--- terminal/kill: send SIGTERM to the process.
--- params: { sessionId, terminalId }
function M.kill(params, respond)
  local term_id = params and params.terminalId
  local term_state = term_id and terminals[term_id]
  if not term_state then
    respond({ code = -32000, message = "terminal/kill: unknown terminalId" }, true)
    return
  end

  if not term_state.exited and term_state.chan then
    vim.fn.jobstop(term_state.chan)
  end

  respond(vim.NIL)
end

--- terminal/release: kill if running and free all resources.
--- params: { sessionId, terminalId }
function M.release(params, respond)
  local term_id = params and params.terminalId
  local term_state = term_id and terminals[term_id]
  if not term_state then
    respond({ code = -32000, message = "terminal/release: unknown terminalId" }, true)
    return
  end

  if not term_state.exited and term_state.chan then
    pcall(vim.fn.jobstop, term_state.chan)
  end

  if term_state.buf and vim.api.nvim_buf_is_valid(term_state.buf) then
    pcall(vim.api.nvim_buf_delete, term_state.buf, { force = true })
  end

  -- Fail any waiters.
  for _, waiter in ipairs(term_state.waiters) do
    vim.schedule(function()
      waiter({ exitCode = nil, signal = "released" })
    end)
  end

  terminals[term_id] = nil
  respond(vim.NIL)
end

return M
