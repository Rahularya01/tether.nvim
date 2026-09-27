local function report(kind, msg)
  local health = vim.health
  if kind == "start" then
    if health.start then
      health.start(msg)
    else
      health.report_start(msg)
    end
  elseif kind == "ok" then
    if health.ok then
      health.ok(msg)
    else
      health.report_ok(msg)
    end
  elseif kind == "warn" then
    if health.warn then
      health.warn(msg)
    else
      health.report_warn(msg)
    end
  else
    if health.error then
      health.error(msg)
    else
      health.report_error(msg)
    end
  end
end

local M = {}

function M.check()
  local tether = require("tether")
  report("start", "tether.nvim")
  if vim.fn.has("win32") == 1 then
    report("error", "Windows is not supported. tether.nvim needs /dev/urandom and Unix sockets")
    return
  end
  if vim.fn.has("nvim-0.11") == 0 then
    report("error", "Neovim 0.11 or newer is required")
    return
  end
  if not tether.is_running() then
    report("warn", "not running. :TetherStart or require('tether').setup()")
    return
  end
  report("ok", "running")
  for _, line in ipairs(tether.status()) do
    report("ok", line)
  end
  local script = tether.env_script()
  if script ~= "" then
    report("ok", "terminal environment is set for new Neovim terminals")
  else
    report("warn", "no harness environment variables are set")
  end
end

return M
