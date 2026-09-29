-- User autocmds other plugins and statuslines can listen for.
-- TetherClient  { adapter, clients } when a harness connects or drops.
-- TetherReview  { action = "open"|"hunk"|"accept"|"reject", path }
-- TetherAgent   { source, agent, pane_id, status, previous } when a pane's status changes.
local M = {}

function M.emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    data = data or {},
    modeline = false,
  })
end

return M
