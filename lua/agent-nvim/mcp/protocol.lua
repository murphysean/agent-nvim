local json = require("agent-nvim.json")
local sessions = require("agent-nvim.sessions")

local M = {}

M.PROTOCOL_VERSION = "2025-03-26"

M.SERVER_INFO = {
  name = "neovim-mcp",
  version = "0.1.0",
}

M.CAPABILITIES = {
  tools = { listChanged = false },
  resources = { subscribe = true, listChanged = true },
  prompts = { listChanged = false },
  completions = vim.empty_dict(),
}

M.client_capabilities = {}

function M.client_supports(capability)
  return M.client_capabilities[capability] ~= nil
end

--- Auto-subscribe a session based on read-like tool usage.
--- Maps tool calls to resource URIs the client implicitly cares about.
function M._auto_subscribe_tool(session_id, tool_name, arguments)
  if tool_name == "read_file" then
    local path = arguments.path
    if path then
      -- Resolve to absolute path
      if not path:match("^/") then
        path = vim.fn.getcwd() .. "/" .. path
      end
      sessions.subscribe(session_id, "file://" .. path)
    end
  elseif tool_name == "buffer_get_content" then
    local bufnr = arguments.buffer
    if bufnr then
      sessions.subscribe(session_id, "nvim://buffer/" .. bufnr)
    end
    if arguments.file then
      local path = arguments.file
      if not path:match("^/") then
        path = vim.fn.getcwd() .. "/" .. path
      end
      sessions.subscribe(session_id, "file://" .. path)
    end
  elseif tool_name == "buffer_open" then
    local path = arguments.file
    if path then
      if not path:match("^/") then
        path = vim.fn.getcwd() .. "/" .. path
      end
      sessions.subscribe(session_id, "file://" .. path)
    end
  elseif tool_name == "cursor_get" then
    sessions.subscribe(session_id, "nvim://cursor")
  elseif tool_name == "diagnostics" then
    sessions.subscribe(session_id, "nvim://diagnostics")
  elseif tool_name == "quickfix_get" then
    sessions.subscribe(session_id, "nvim://quickfix")
  end
end

function M.handle_jsonrpc(request_body, tool_registry, session_id, respond_fn)
  local msg = json.decode(request_body)
  if not msg then
    return M.error_response(nil, -32700, "Parse error")
  end

  local method = msg.method
  local id = msg.id
  local params = msg.params or {}

  -- Extract Goose session ID from _meta on all incoming requests.
  -- Goose injects `agent-session-id` into request _meta for session-aware routing.
  if params._meta and params._meta["agent-session-id"] and session_id then
    sessions.set_client_session_id(session_id, params._meta["agent-session-id"])
  end

  -- Handle responses to server-initiated requests (sampling, etc.)
  if not method and id and (msg.result or msg.error) then
    local sampling = require("agent-nvim.mcp.sampling")
    if sampling.handle_response(msg) then
      return nil
    end
    return nil
  end

  if method == "initialize" then
    local roots_module = require("agent-nvim.mcp.roots")
    if params.roots then
      roots_module.set(params.roots)
    end
    if params.capabilities then
      M.client_capabilities = params.capabilities
    end

    -- Notify lifecycle that a capable client may have connected
    vim.schedule(function()
      local lifecycle = require("agent-nvim.sampling_lifecycle")
      lifecycle.on_session_ready()
    end)

    return M.success_response(id, {
      protocolVersion = M.PROTOCOL_VERSION,
      capabilities = M.CAPABILITIES,
      serverInfo = M.SERVER_INFO,
    })
  end

  if method == "notifications/initialized" then
    return nil
  end

  if method == "notifications/roots/list_changed" then
    local roots_module = require("agent-nvim.mcp.roots")
    if params.roots then
      roots_module.set(params.roots)
    end
    return nil
  end

  if method == "ping" then
    return M.success_response(id, {})
  end

  -- Tools
  if method == "tools/list" then
    local tools = tool_registry.list_tools()
    return M.success_response(id, {
      tools = tools,
    })
  end

  if method == "tools/call" then
    local tool_name = params.name
    local arguments = params.arguments or {}

    -- Extract progressToken from _meta if provided by client
    local progress_token = params._meta and params._meta.progressToken or nil
    local progress_fn = nil
    if progress_token and session_id then
      progress_fn = function(message)
        sessions.send_notification(session_id, "notifications/progress", {
          progressToken = progress_token,
          progress = 0,
          message = message,
        })
      end
    end

    local responded = false
    local function respond_with(ok, content, is_error)
      if responded then
        return
      end
      responded = true
      local response_body
      if not ok then
        response_body = M.error_response(id, -32602, content)
      else
        local call_result = { content = content }
        if is_error then
          call_result.isError = true
        end
        response_body = M.success_response(id, call_result)
      end
      -- Auto-subscribe after successful read-like tool calls
      if ok and session_id then
        M._auto_subscribe_tool(session_id, tool_name, arguments)
      end
      if respond_fn then
        respond_fn(response_body)
      end
    end

    local result = tool_registry.call_tool(tool_name, arguments, respond_with, progress_fn)
    if result == "async" then
      return "async"
    end
    return nil
  end

  -- Resources
  if method == "resources/list" then
    local resource_registry = require("agent-nvim.mcp.resources")
    local resources = resource_registry.list()
    return M.success_response(id, { resources = resources })
  end

  if method == "resources/read" then
    local resource_registry = require("agent-nvim.mcp.resources")
    local uri = params.uri
    if not uri then
      return M.error_response(id, -32602, "Missing uri parameter")
    end
    local ok, contents = resource_registry.read(uri)
    if not ok then
      return M.error_response(id, -32002, contents)
    end
    -- Auto-subscribe: reading a resource implies interest in updates
    if session_id then
      sessions.subscribe(session_id, uri)
    end
    return M.success_response(id, { contents = contents })
  end

  if method == "resources/templates/list" then
    local resource_registry = require("agent-nvim.mcp.resources")
    local templates = resource_registry.list_templates()
    return M.success_response(id, { resourceTemplates = templates })
  end

  if method == "resources/subscribe" then
    local uri = params.uri
    if uri and session_id then
      sessions.subscribe(session_id, uri)
    end
    return M.success_response(id, {})
  end

  if method == "resources/unsubscribe" then
    local uri = params.uri
    if uri and session_id then
      sessions.unsubscribe(session_id, uri)
    end
    return M.success_response(id, {})
  end

  -- Completion
  if method == "completion/complete" then
    local completion = require("agent-nvim.mcp.completion")
    local ref = params.ref
    local argument = params.argument
    if not ref or not argument then
      return M.error_response(id, -32602, "Missing ref or argument parameter")
    end
    local result = completion.complete(ref, argument)
    return M.success_response(id, { completion = result })
  end

  -- Prompts
  if method == "prompts/list" then
    local prompt_registry = require("agent-nvim.mcp.prompts")
    local prompt_list = prompt_registry.list()
    return M.success_response(id, { prompts = prompt_list })
  end

  if method == "prompts/get" then
    local prompt_registry = require("agent-nvim.mcp.prompts")
    local name = params.name
    if not name then
      return M.error_response(id, -32602, "Missing name parameter")
    end
    local ok, result = prompt_registry.get(name, params.arguments)
    if not ok then
      return M.error_response(id, -32002, result)
    end
    return M.success_response(id, result)
  end

  return M.error_response(id, -32601, "Method not found: " .. (method or "nil"))
end

function M.success_response(id, result)
  return json.encode({
    jsonrpc = "2.0",
    id = id,
    result = result,
  })
end

function M.error_response(id, code, message)
  return json.encode({
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
    },
  })
end

return M
