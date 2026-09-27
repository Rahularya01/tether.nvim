local httparse = require("tether.httparse")

local M = {}

local STATUS = {
  [200] = "OK",
  [202] = "Accepted",
  [204] = "No Content",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [500] = "Internal Server Error",
}

function M.sse(json)
  local lines = { "event: message" }
  for line in (json .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = "data: " .. line
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

function M.serve(opts)
  local server = vim.uv.new_tcp()
  local ok, err = server:bind(opts.host or "127.0.0.1", opts.port or 0)
  if not ok then
    server:close()
    return nil, err
  end
  local sockets = {}

  local function track(sock)
    sockets[#sockets + 1] = sock
  end

  local function untrack(sock)
    for i, existing in ipairs(sockets) do
      if existing == sock then
        table.remove(sockets, i)
        break
      end
    end
  end

  server:listen(128, function()
    local sock = vim.uv.new_tcp()
    server:accept(sock)
    track(sock)
    local buf = ""
    local mode = "http"
    local paused = false
    local reading = false
    local on_close

    local function close()
      if sock:is_closing() then
        return
      end
      mode = "closed"
      sock:read_stop()
      sock:close()
      untrack(sock)
      if on_close then
        vim.schedule(on_close)
      end
    end

    local on_read
    local process

    local function ensure_read()
      if mode == "closed" or reading then
        return
      end
      reading = true
      sock:read_start(on_read)
    end

    local function write_response(res)
      local status = res.status or 200
      local headers = {}
      for k, v in pairs(res.headers or {}) do
        headers[k] = v
      end
      if res.stream then
        headers["Content-Type"] = "text/event-stream"
        headers["Cache-Control"] = "no-cache"
        headers["Connection"] = "keep-alive"
        headers["Content-Length"] = nil
        local lines = { string.format("HTTP/1.1 %d %s", status, STATUS[status] or "OK") }
        for k, v in pairs(headers) do
          if v ~= nil then
            lines[#lines + 1] = k .. ": " .. v
          end
        end
        sock:write(table.concat(lines, "\r\n") .. "\r\n\r\n")
        mode = "sse"
        on_close = res.on_close
        paused = false
        ensure_read()
        return {
          write = function(payload)
            if mode == "sse" and not sock:is_closing() then
              sock:write(M.sse(payload))
            end
          end,
          close = close,
        }
      end
      local body = res.body or ""
      sock:write(httparse.response(status, STATUS[status] or "OK", headers, body))
      if headers["Connection"] == "close" or res.close then
        close()
        return
      end
      paused = false
      ensure_read()
      process()
    end

    process = function()
      if paused or mode ~= "http" then
        return
      end
      local request, rest, parse_err = httparse.next_request(buf)
      if parse_err then
        sock:write(httparse.response(400, "Bad Request", { Connection = "close" }, ""))
        close()
        return
      end
      if not request then
        return
      end
      buf = rest
      paused = true
      if reading then
        sock:read_stop()
        reading = false
      end
      vim.schedule(function()
        if mode == "closed" then
          return
        end
        local ok_call, call_err = pcall(opts.on_request, request, write_response)
        if not ok_call then
          write_response({
            status = 500,
            headers = { ["Content-Type"] = "text/plain", Connection = "close" },
            body = tostring(call_err),
            close = true,
          })
        end
      end)
    end

    on_read = function(read_err, data)
      if read_err or not data then
        close()
        return
      end
      if mode ~= "http" then
        return
      end
      buf = buf .. data
      if #buf > 32 * 1024 * 1024 then
        close()
        return
      end
      process()
    end

    ensure_read()
  end)

  local sockname = server:getsockname()
  return {
    port = sockname.port,
    close = function()
      for _, sock in ipairs(vim.list_extend({}, sockets)) do
        if not sock:is_closing() then
          sock:read_stop()
          sock:close()
        end
      end
      if not server:is_closing() then
        server:close()
      end
    end,
  }
end

return M
