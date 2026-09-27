-- A short ring of protocol events for :TetherLog. File contents and tokens stay out of it.
local M = {}

local MAX = 200
local lines = {}

function M.record(source, message)
  lines[#lines + 1] = string.format("%s  %-8s  %s", os.date("%H:%M:%S"), source or "tether", message)
  while #lines > MAX do
    table.remove(lines, 1)
  end
end

function M.get()
  return vim.list_extend({}, lines)
end

function M.clear()
  lines = {}
end

function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  local body = #lines > 0 and vim.list_extend({}, lines) or { "tether: no protocol events yet" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "log"
  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

return M
