local M = {}

-- What tether.nvim tells an MCP client it is, in the initialize reply.
M.server_info = { name = "tether.nvim", version = "0.4.0" }

function M.ok(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

function M.err(id, code, message)
  return {
    jsonrpc = "2.0",
    id = id,
    error = { code = code, message = message },
  }
end

function M.text(text, is_error)
  local result = { content = { { type = "text", text = text } } }
  if is_error then
    result.isError = true
  end
  return result
end

function M.empty()
  return { content = {} }
end

-- handlers.request[method](params, reply)
-- handlers.notify[method](params)
-- reply(result_table) for success. Throw or reply(nil, code, message) for errors.
function M.dispatch(message, handlers, reply)
  if type(message) ~= "table" or message.jsonrpc ~= "2.0" or type(message.method) ~= "string" then
    if type(message) == "table" and message.id ~= nil then
      reply(M.err(message.id, -32600, "Invalid Request"))
    else
      reply(nil)
    end
    return
  end

  if message.id == nil then
    local notify = handlers.notify and handlers.notify[message.method]
    if notify then
      local ok, err = pcall(notify, message.params or vim.empty_dict())
      if not ok and handlers.on_error then
        handlers.on_error(err)
      end
    end
    reply(nil)
    return
  end

  local request = handlers.request and handlers.request[message.method]
  if not request then
    reply(M.err(message.id, -32601, "Method not found: " .. message.method))
    return
  end

  local replied = false
  local function once(result, code, message_text)
    if replied then
      return
    end
    replied = true
    if code then
      reply(M.err(message.id, code, message_text or "error"))
    else
      reply(M.ok(message.id, result))
    end
  end

  local ok, err = pcall(request, message.params or vim.empty_dict(), once)
  if not ok then
    once(nil, -32603, tostring(err))
  end
end

return M
