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

local function discovery_dirs(tether)
  local state = tether.is_running() and tether.state() or {}
  local claude = state.claude and state.claude.dir
  if not claude then
    local home = os.getenv("CLAUDE_CONFIG_DIR") or ((os.getenv("HOME") or "") .. "/.claude")
    claude = home .. "/ide"
  end
  local gemini = state.gemini and state.gemini.dir
  if not gemini then
    gemini = (vim.uv.os_tmpdir() or "/tmp") .. "/gemini/ide"
  end
  return claude, gemini
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
  else
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

  local waiting = require("tether.diff").waiting()
  if #waiting == 0 then
    report("ok", "no review waiting")
  else
    local parts = {}
    for _, item in ipairs(waiting) do
      local note = item.path
      if item.queued > 0 then
        note = string.format("%s (+%d waiting)", item.path, item.queued)
      end
      parts[#parts + 1] = note
    end
    report("warn", "review waiting: " .. table.concat(parts, ", "))
  end

  local claude_dir, gemini_dir = discovery_dirs(tether)
  local claude_stale = require("tether.adapters.claude").stale(claude_dir)
  if #claude_stale == 0 then
    report("ok", "no stale Claude lock files")
  else
    report("warn", #claude_stale .. " stale Claude lock file(s) in " .. claude_dir)
  end
  local gemini_stale = require("tether.adapters.gemini").stale(gemini_dir)
  if #gemini_stale == 0 then
    report("ok", "no stale Gemini discovery files")
  else
    report("warn", #gemini_stale .. " stale Gemini discovery file(s) in " .. gemini_dir)
  end
end

return M
