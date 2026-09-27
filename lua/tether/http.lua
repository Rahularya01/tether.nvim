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

local function parse_url(url)
  local scheme, rest = tostring(url or ""):match("^(https?)://(.+)$")
  if not scheme or scheme ~= "http" then
    return nil, "only http URLs are supported"
  end
  local hostport, path = rest:match("^([^/]+)(.*)$")
  if not hostport or hostport == "" then
    return nil, "bad URL"
  end
  if path == nil or path == "" then
    path = "/"
  end
  local host, port = hostport:match("^([^:]+):(%d+)$")
  if not host then
    host = hostport
    port = "80"
  end
  return { host = host, port = tonumber(port), path = path }
end

local function response_headers(head)
  local headers = {}
  local status
  local first = true
  for line in head:gmatch("[^\r\n]+") do
    if first then
      status = tonumber(line:match("^HTTP/%d+%.%d+%s+(%d+)"))
      first = false
    else
      local key, value = line:match("^([^:%s]+)%s*:%s*(.*)$")
      if key then
        headers[key:lower()] = value
      end
    end
  end
  return status, headers
end

local function unchunk(body, eof)
  local out, i = {}, 1
  while true do
    local line_end = body:find("\r\n", i, true)
    if not line_end then
      if eof then
        return nil, "truncated chunk"
      end
      return nil
    end
    local size = tonumber(body:sub(i, line_end - 1):match("^(%x+)"), 16)
    if not size then
      return nil, "bad chunk size"
    end
    if size == 0 then
      return table.concat(out)
    end
    local start_at = line_end + 2
    local stop = start_at + size - 1
    if #body < stop + 2 then
      if eof then
        return nil, "truncated chunk"
      end
      return nil
    end
    if body:sub(stop + 1, stop + 2) ~= "\r\n" then
      return nil, "bad chunk ending"
    end
    out[#out + 1] = body:sub(start_at, stop)
    i = stop + 3
  end
end

-- nil, nil while the response is incomplete. nil, err when it cannot be parsed.
local function parse_response(buf, eof)
  local header_end = buf:find("\r\n\r\n", 1, true)
  if not header_end then
    if eof or #buf > 65536 then
      return nil, "bad response"
    end
    return nil
  end
  local status, headers = response_headers(buf:sub(1, header_end - 1))
  if not status then
    return nil, "bad response"
  end
  local rest = buf:sub(header_end + 4)
  local encoding = headers["transfer-encoding"]
  if encoding and encoding:lower():find("chunked", 1, true) then
    local body, err = unchunk(rest, eof)
    if not body then
      return nil, err
    end
    return { status = status, body = body }
  end
  local length = tonumber(headers["content-length"] or "")
  if length then
    if #rest < length then
      if eof then
        return nil, "truncated body"
      end
      return nil
    end
    return { status = status, body = rest:sub(1, length) }
  end
  if eof then
    return { status = status, body = rest }
  end
  return nil
end

-- opts: url, method, headers, body, timeout (ms). callback({ status, body, err }) on the main loop.
function M.request(opts, callback)
  opts = opts or {}
  local target, url_err = parse_url(opts.url)
  if not target then
    vim.schedule(function()
      callback({ err = url_err })
    end)
    return
  end
  local sock = vim.uv.new_tcp()
  local timer = vim.uv.new_timer()
  local acc = ""
  local settled = false
  local function finish(result)
    if settled then
      return
    end
    settled = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if sock and not sock:is_closing() then
      pcall(function()
        sock:read_stop()
        sock:close()
      end)
    end
    vim.schedule(function()
      callback(result)
    end)
  end
  local function consider(eof)
    if #acc > 8 * 1024 * 1024 then
      finish({ err = "response too large" })
      return
    end
    local parsed, err = parse_response(acc, eof)
    if parsed then
      finish(parsed)
    elseif err then
      finish({ err = err })
    elseif eof then
      finish({ err = "incomplete response" })
    end
  end
  timer:start(opts.timeout or 2000, 0, function()
    finish({ err = "timed out" })
  end)
  sock:connect(target.host, target.port, function(err)
    if err then
      finish({ err = tostring(err) })
      return
    end
    local body = opts.body or ""
    local header_lines = {
      string.format("%s %s HTTP/1.1", opts.method or "GET", target.path),
      "Host: " .. target.host .. ":" .. target.port,
      "Accept: application/json",
      "Connection: close",
    }
    for key, value in pairs(opts.headers or {}) do
      header_lines[#header_lines + 1] = key .. ": " .. value
    end
    if body ~= "" then
      header_lines[#header_lines + 1] = "Content-Length: " .. tostring(#body)
    end
    local req = table.concat(header_lines, "\r\n") .. "\r\n\r\n" .. body
    sock:write(req, function(write_err)
      if write_err then
        finish({ err = tostring(write_err) })
      end
    end)
    sock:read_start(function(read_err, data)
      if read_err then
        finish({ err = tostring(read_err) })
        return
      end
      if data then
        acc = acc .. data
        consider(false)
        return
      end
      consider(true)
    end)
  end)
end

return M
