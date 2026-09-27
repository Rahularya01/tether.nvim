-- Binary helpers. This Neovim build does not ship Lua's string.pack.
local M = {}

function M.u16be(n)
  n = math.floor(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

function M.u32be(n)
  n = math.floor(n) % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

function M.u32le(n)
  n = math.floor(n) % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

function M.u64be(n)
  n = math.floor(n)
  local hi = math.floor(n / 4294967296)
  local lo = n % 4294967296
  return M.u32be(hi) .. M.u32be(lo)
end

function M.read_u16be(buf, index)
  local a, b = buf:byte(index, index + 1)
  return a * 256 + b
end

function M.read_u32be(buf, index)
  local a, b, c, d = buf:byte(index, index + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.read_u32le(buf, index)
  local a, b, c, d = buf:byte(index, index + 3)
  return ((d * 256 + c) * 256 + b) * 256 + a
end

function M.read_u64be(buf, index)
  local hi = M.read_u32be(buf, index)
  local lo = M.read_u32be(buf, index + 4)
  return hi * 4294967296 + lo
end

return M
