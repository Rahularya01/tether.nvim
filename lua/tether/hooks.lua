-- Claude Code hooks that report Edit, Write, and MultiEdit back to this Neovim.
-- Installing edits ~/.claude/settings.json. The command prints the diff, then
-- writes it. :TetherRemoveHooks takes the same entries back out.
local util = require("tether.util")

local M = {}

local MARK = "tether-claude-hook.sh"

local settings_path

local function settings_file()
  if settings_path and settings_path ~= "" then
    return settings_path
  end
  return vim.fn.expand("~/.claude/settings.json")
end

function M.configure(opts)
  opts = opts or {}
  if opts.settings ~= nil then
    settings_path = opts.settings
  end
end

function M.script_path()
  return vim.fn.stdpath("state") .. "/tether/" .. MARK
end

local SCRIPT = [[#!/bin/sh
# Claude Code hook installed by tether.nvim. Payload arrives on stdin.
server="${TETHER_NVIM_SERVER:-}"
if [ -z "$server" ]; then
  exit 0
fi
dir="${TMPDIR:-/tmp}/tether-events-$$"
mkdir -p "$dir" || exit 0
file="$dir/event.json"
cat > "$file" || exit 0
nvim --server "$server" --remote-expr "v:lua.require('tether').agent_event_file('$file')" >/dev/null 2>&1 || true
rm -f "$file"
]]

local function read_settings(path)
  if vim.uv.fs_stat(path) == nil then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return {}
  end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(data) ~= "table" then
    return nil, "could not read " .. path .. " as JSON"
  end
  return data
end

local function pretty(value)
  return vim.json.encode(value)
end

local function ours(entry)
  local command = entry and entry.command
  return type(command) == "string" and command:find(MARK, 1, true) ~= nil
end

local function strip(list)
  local kept = {}
  for _, group in ipairs(list or {}) do
    local hooks = {}
    for _, hook in ipairs(group.hooks or {}) do
      if not ours(hook) then
        hooks[#hooks + 1] = hook
      end
    end
    if #hooks > 0 then
      local copy = vim.tbl_extend("force", {}, group)
      copy.hooks = hooks
      kept[#kept + 1] = copy
    end
  end
  return kept
end

local function with_hook(data, include)
  data = vim.deepcopy(data or {})
  data.hooks = type(data.hooks) == "table" and data.hooks or {}
  data.hooks.PostToolUse = strip(data.hooks.PostToolUse)
  data.hooks.Stop = strip(data.hooks.Stop)
  if include then
    local command = M.script_path()
    local hook = { type = "command", command = command }
    data.hooks.PostToolUse[#data.hooks.PostToolUse + 1] = {
      matcher = "Edit|Write|MultiEdit",
      hooks = { hook },
    }
    data.hooks.Stop[#data.hooks.Stop + 1] = { hooks = { { type = "command", command = command } } }
  end
  if #data.hooks.PostToolUse == 0 then
    data.hooks.PostToolUse = nil
  end
  if #data.hooks.Stop == 0 then
    data.hooks.Stop = nil
  end
  if data.hooks.PostToolUse == nil and data.hooks.Stop == nil and next(data.hooks) == nil then
    data.hooks = nil
  end
  return data
end

local function show_diff(before, after)
  local diff = vim.diff(pretty(before), pretty(after), { result_type = "unified" })
  if not diff or diff == "" then
    vim.api.nvim_echo({ { "tether: Claude hooks already match", "Normal" } }, true, {})
    return
  end
  vim.api.nvim_echo({ { diff, "Normal" } }, true, {})
end

local function write_script()
  local path = M.script_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = util.write_private(path, SCRIPT, 493)
  if not ok then
    return nil, err
  end
  return path
end

-- Prints the settings diff, then writes it. include false removes the hooks.
local function apply(include)
  local path = settings_file()
  local current, err = read_settings(path)
  if not current then
    return nil, err
  end
  if include then
    local script, serr = write_script()
    if not script then
      return nil, serr
    end
  end
  local updated = with_hook(current, include)
  show_diff(current, updated)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, werr = util.write_private(path, pretty(updated) .. "\n")
  if not ok then
    return nil, werr
  end
  return path
end

-- The settings table after adding or removing tether's hook entries.
function M.plan(data, include)
  return with_hook(data, include)
end

function M.install()
  if not vim.v.servername or vim.v.servername == "" then
    return nil, "this Neovim has no server name, so a hook cannot call back into it"
  end
  return apply(true)
end

function M.remove()
  return apply(false)
end

return M
