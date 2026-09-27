-- User autocmds other plugins and statuslines can listen for.
-- TetherClient  { adapter, clients } when a harness connects or drops.
-- TetherReview  { action = "open"|"hunk"|"accept"|"reject", path }
local M = {}

function M.emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    data = data or {},
    modeline = false,
  })
end

return M
