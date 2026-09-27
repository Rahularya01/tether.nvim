set rtp^=.
let g:loaded_tether = 1
let g:tether_disable = 1
lua << EOF
local ok, err = xpcall(function()
  dofile("tests/run.lua")
end, debug.traceback)
if not ok then
  io.write("\n" .. tostring(err) .. "\n")
  io.flush()
  vim.cmd("cquit 1")
end
EOF
