local M = {}

function M.headers(head)
  local headers = {}
  local first = true
  local request
  for line in head:gmatch("[^\r\n]+") do
    if first then
      local method, target, version = line:match("^(%u+)%s+(%S+)%s+HTTP/(%d+%.%d+)$")
      if not method then
        return nil, "bad request line"
      end
      local path, query = target:match("^([^?]+)%??(.*)$")
      request = {
        method = method,
        target = target,
        path = path,
        query = query or "",
        version = version,
        headers = headers,
      }
      first = false
    else
      local k, v = line:match("^([^:%s]+)%s*:%s*(.*)$")
      if k then
        headers[k:lower()] = v
      end
    end
  end
  return request
end

-- Pull one complete HTTP/1.1 request out of buf.
-- Returns request, remainder. Returns nil if the request is incomplete.
function M.next_request(buf, max_body)
  max_body = max_body or (32 * 1024 * 1024)
  local header_end = buf:find("\r\n\r\n", 1, true)
  if not header_end then
    if #buf > 65536 then
      return nil, buf, "headers too large"
    end
    return nil, buf
  end
  local request, err = M.headers(buf:sub(1, header_end - 1))
  if not request then
    return nil, buf, err
  end
  local rest = buf:sub(header_end + 4)
  local length = tonumber(request.headers["content-length"] or "0") or 0
  if length < 0 or length > max_body then
    return nil, buf, "body too large"
  end
  if #rest < length then
    return nil, buf
  end
  request.body = rest:sub(1, length)
  return request, rest:sub(length + 1)
end

function M.response(status, reason, headers, body)
  body = body or ""
  local lines = { string.format("HTTP/1.1 %d %s", status, reason) }
  headers = headers or {}
  -- 101 responses must not include a body. A Content-Length here breaks some clients.
  if status ~= 101 and not headers["Content-Length"] and not headers["content-length"] then
    headers["Content-Length"] = tostring(#body)
  end
  if not headers["Connection"] then
    headers["Connection"] = "keep-alive"
  end
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  if status == 101 then
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

return M
