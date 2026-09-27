-- SHA-1 (FIPS 180-1). Returns raw 20-byte digests for the WebSocket handshake.
local bin = require("tether.bin")
local bit = bit

local MOD = 4294967296

local function u32(x)
  local n = x % MOD
  if n < 0 then
    n = n + MOD
  end
  return n
end

local function rol(x, n)
  local v = bit.band(x, 0xffffffff)
  return bit.bor(bit.lshift(v, n), bit.rshift(v, 32 - n))
end

local function bxor(a, b, c, d)
  local v = bit.bxor(a, b, c)
  if d ~= nil then
    v = bit.bxor(v, d)
  end
  return v
end

local M = {}

function M.raw(message)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local msg = message .. "\128"
  local pad = (56 - (#msg % 64)) % 64
  msg = msg .. string.rep("\0", pad) .. bin.u64be(#message * 8)

  for i = 1, #msg, 64 do
    local w = {}
    for j = 0, 15 do
      w[j] = bin.read_u32be(msg, i + j * 4)
    end
    for j = 16, 79 do
      w[j] = u32(rol(bxor(w[j - 3], w[j - 8], w[j - 14], w[j - 16]), 1))
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for j = 0, 79 do
      local f, k
      if j <= 19 then
        f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
        k = 0x5A827999
      elseif j <= 39 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif j <= 59 then
        f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temp = u32(u32(rol(a, 5)) + u32(f) + e + k + w[j])
      e, d, c, b, a = d, c, u32(rol(b, 30)), a, temp
    end
    h0 = u32(h0 + a)
    h1 = u32(h1 + b)
    h2 = u32(h2 + c)
    h3 = u32(h3 + d)
    h4 = u32(h4 + e)
  end

  return bin.u32be(h0) .. bin.u32be(h1) .. bin.u32be(h2) .. bin.u32be(h3) .. bin.u32be(h4)
end

function M.hex(message)
  return (M.raw(message):gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

return M
