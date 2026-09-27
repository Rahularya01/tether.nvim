local bin = require("tether.bin")
local httparse = require("tether.httparse")
local sha1 = require("tether.sha1")

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local MAX_FRAME = 32 * 1024 * 1024

local M = {}

local function accept_key(key)
  return vim.base64.encode(sha1.raw(key .. GUID))
end

local function xor_mask(payload, mask)
  local out = {}
  for i = 1, #payload do
    out[i] = string.char(bit.bxor(payload:byte(i), mask:byte((i - 1) % 4 + 1)))
  end
  return table.concat(out)
end

function M.encode(payload, opcode)
  opcode = opcode or 0x1
  local header = string.char(bit.bor(0x80, opcode))
  local n = #payload
  if n < 126 then
    header = header .. string.char(n)
  elseif n < 65536 then
    header = header .. string.char(126) .. bin.u16be(n)
  else
    header = header .. string.char(127) .. bin.u64be(n)
  end
  return header .. payload
end

function M.decoder()
  local buf = ""
  local frag = ""
  return function(chunk)
    buf = buf .. (chunk or "")
    local messages = {}
    local control = {}
    while #buf >= 2 do
      local b1, b2 = buf:byte(1, 2)
      local fin = bit.band(b1, 0x80) ~= 0
      local opcode = bit.band(b1, 0x0f)
      local masked = bit.band(b2, 0x80) ~= 0
      local len = bit.band(b2, 0x7f)
      local offset = 3
      if len == 126 then
        if #buf < 4 then
          break
        end
        len = bin.read_u16be(buf, 3)
        offset = 5
      elseif len == 127 then
        if #buf < 10 then
          break
        end
        len = bin.read_u64be(buf, 3)
        offset = 11
      end
      if len > MAX_FRAME then
        return nil, nil, "frame too large"
      end
      local mask_len = masked and 4 or 0
      if #buf < (offset - 1) + mask_len + len then
        break
      end
      local mask
      if masked then
        mask = buf:sub(offset, offset + 3)
        offset = offset + 4
      end
      local payload = buf:sub(offset, offset + len - 1)
      buf = buf:sub(offset + len)
      if masked then
        payload = xor_mask(payload, mask)
      end
      if opcode == 0x8 or opcode == 0x9 or opcode == 0xA then
        control[#control + 1] = { opcode = opcode, payload = payload }
      elseif opcode == 0x1 or opcode == 0x2 or opcode == 0x0 then
        frag = frag .. payload
        if fin then
          if opcode ~= 0x0 or frag ~= "" then
            messages[#messages + 1] = frag
          end
          frag = ""
        end
      end
    end
    return messages, control
  end
end

function M.serve(opts)
  local server = vim.uv.new_tcp()
  local ok, err = server:bind(opts.host or "127.0.0.1", opts.port or 0)
  if not ok then
    server:close()
    return nil, err
  end
  local clients = {}
  local function forget(client)
    for i, existing in ipairs(clients) do
      if existing == client then
        table.remove(clients, i)
        break
      end
    end
    if opts.on_close then
      opts.on_close(client)
    end
  end

  server:listen(128, function()
    local sock = vim.uv.new_tcp()
    server:accept(sock)
    local buf = ""
    local upgraded = false
    local client
    local decode
    local queue = {}
    local pumping = false

    local function close()
      if sock:is_closing() then
        return
      end
      sock:read_stop()
      sock:close()
      if client then
        client.closed = true
        forget(client)
      end
    end

    local function pump()
      if pumping or not client or client.closed or #queue == 0 then
        return
      end
      pumping = true
      local text = table.remove(queue, 1)
      vim.schedule(function()
        if client.closed then
          return
        end
        opts.on_message(client, text, function()
          pumping = false
          pump()
        end)
      end)
    end

    local function on_read(read_err, data)
      if read_err or not data then
        close()
        return
      end
      if not upgraded then
        buf = buf .. data
        local request, rest, parse_err = httparse.next_request(buf)
        if parse_err then
          sock:write(httparse.response(400, "Bad Request", { Connection = "close" }, ""))
          close()
          return
        end
        if not request then
          return
        end
        buf = ""
        local headers = request.headers
        local token = headers["x-claude-code-ide-authorization"]
        if not token and headers["authorization"] then
          token = headers["authorization"]:match("^[Bb]earer%s+(.+)$") or headers["authorization"]
        end
        if opts.auth_token and token ~= opts.auth_token then
          require("tether.log").record(opts.name or "websocket", "rejected handshake")
          sock:write(httparse.response(401, "Unauthorized", { Connection = "close" }, ""))
          close()
          return
        end
        local key = headers["sec-websocket-key"]
        if request.method ~= "GET" or not key or (headers["upgrade"] or ""):lower() ~= "websocket" then
          sock:write(httparse.response(400, "Bad Request", { Connection = "close" }, ""))
          close()
          return
        end
        sock:write(httparse.response(101, "Switching Protocols", {
          Upgrade = "websocket",
          Connection = "Upgrade",
          ["Sec-WebSocket-Accept"] = accept_key(key),
        }, ""))
        upgraded = true
        decode = M.decoder()
        client = {
          closed = false,
          send = function(_, payload)
            if not client.closed and not sock:is_closing() then
              sock:write(M.encode(payload, 0x1))
            end
          end,
          close = close,
        }
        clients[#clients + 1] = client
        if opts.on_open then
          vim.schedule(function()
            opts.on_open(client)
          end)
        end
        data = rest
        if data == "" then
          return
        end
      end
      local messages, control, dec_err = decode(data)
      if dec_err then
        close()
        return
      end
      for _, item in ipairs(control or {}) do
        if item.opcode == 0x8 then
          sock:write(M.encode(item.payload, 0x8))
          close()
          return
        elseif item.opcode == 0x9 then
          sock:write(M.encode(item.payload, 0xA))
        end
      end
      for _, text in ipairs(messages or {}) do
        queue[#queue + 1] = text
      end
      pump()
    end

    sock:read_start(on_read)
  end)

  local sockname = server:getsockname()
  return {
    port = sockname.port,
    close = function()
      for _, client in ipairs(vim.list_extend({}, clients)) do
        client:close()
      end
      if not server:is_closing() then
        server:close()
      end
    end,
    clients = function()
      local alive = {}
      for _, client in ipairs(clients) do
        if not client.closed then
          alive[#alive + 1] = client
        end
      end
      return alive
    end,
  }
end

M.accept_key = accept_key

return M
