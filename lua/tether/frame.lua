-- Codex IDE context frames: little-endian u32 length, then UTF-8 JSON.
local bin = require("tether.bin")
local MAX = 8 * 1024 * 1024

local M = {}

function M.encode(message)
  local payload = type(message) == "string" and message or vim.json.encode(message)
  if #payload > MAX then
    return nil, "frame too large"
  end
  return bin.u32le(#payload) .. payload
end

function M.decoder()
  local buf = ""
  return function(chunk)
    if chunk then
      buf = buf .. chunk
    end
    local out = {}
    while #buf >= 4 do
      local n = bin.read_u32le(buf, 1)
      if n > MAX then
        return nil, "frame too large"
      end
      if #buf < 4 + n then
        break
      end
      local payload = buf:sub(5, 4 + n)
      buf = buf:sub(5 + n)
      local ok, msg = pcall(vim.json.decode, payload)
      if not ok then
        return nil, "invalid json"
      end
      out[#out + 1] = msg
    end
    return out
  end
end

return M
