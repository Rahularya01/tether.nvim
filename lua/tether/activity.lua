-- Edits the agent makes outside the review UI: Claude Code hooks, and a
-- filesystem watch for everything else. Hunks are against the last known good
-- text (git HEAD, or a copy taken when the turn started). Checkpoints live
-- under stdpath("state") and never touch the git index.
local util = require("tether.util")

local M = {}

local ns = vim.api.nvim_create_namespace("tether-activity")
local follow = false
local watch_handle
local user_writes = {}
local baseline = {}
local turn = {}
local turn_id
local checkpoint_root

local IGNORE = {
  [".git"] = true,
  node_modules = true,
  dist = true,
  target = true,
}

local function notify(msg, level)
  vim.notify("tether: " .. msg, level or vim.log.levels.INFO)
end

local function root_dir()
  if checkpoint_root and checkpoint_root ~= "" then
    return checkpoint_root
  end
  return vim.fn.stdpath("state") .. "/tether/checkpoints"
end

function M.configure(opts)
  opts = opts or {}
  follow = opts.follow and true or false
  if opts.checkpoints ~= nil then
    checkpoint_root = opts.checkpoints
  end
end

function M.note_user_write(path)
  path = util.abspath(path)
  if path then
    user_writes[path] = vim.uv.now()
  end
end

local function user_just_wrote(path)
  local at = user_writes[util.abspath(path) or path]
  return at and (vim.uv.now() - at) < 1000
end

local function git_show(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  local top = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
  if vim.v.shell_error ~= 0 or not top or top == "" then
    return nil
  end
  top = util.abspath(top) or top
  local abs = util.abspath(path)
  local rel
  if abs and abs:sub(1, #top) == top then
    rel = abs:sub(#top + 2)
  end
  if not rel or rel == "" then
    return nil
  end
  local text = vim.fn.system({ "git", "-C", top, "show", "HEAD:" .. rel })
  if vim.v.shell_error ~= 0 then
    return ""
  end
  return text
end

local function remember_baseline(path)
  path = util.abspath(path)
  if not path or baseline[path] then
    return path
  end
  local text = git_show(path)
  if text == nil then
    local f = io.open(path, "rb")
    text = f and f:read("*a") or ""
    if f then
      f:close()
    end
  end
  baseline[path] = text
  turn[path] = true
  if not turn_id then
    turn_id = tostring(vim.uv.hrtime())
  end
  return path
end

local function buf_for(path)
  path = util.abspath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and util.abspath(vim.api.nvim_buf_get_name(buf)) == path then
      return buf
    end
  end
end

local function current_text(path)
  local buf = buf_for(path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    if vim.bo[buf].endofline then
      text = text .. "\n"
    end
    return text, buf
  end
  local f = io.open(path, "rb")
  if not f then
    return "", nil
  end
  local text = f:read("*a") or ""
  f:close()
  return text, nil
end

local function hunks_between(before, after)
  local ok, hunks = pcall(vim.diff, before or "", after or "", { result_type = "indices", algorithm = "histogram" })
  if not ok or type(hunks) ~= "table" then
    return {}
  end
  return hunks
end

local function decorate(path)
  local buf = buf_for(path)
  if not buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local before = baseline[path] or ""
  local after = current_text(path)
  for _, hunk in ipairs(hunks_between(before, after)) do
    local start_b, count_b = hunk[3], hunk[4]
    local line = count_b == 0 and start_b or (start_b - 1)
    line = math.max(0, line)
    local last = vim.api.nvim_buf_line_count(buf)
    if line < last then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, 0, {
        sign_text = "▌",
        sign_hl_group = count_b == 0 and "DiffDelete" or "DiffChange",
        invalidate = true,
      })
    end
  end
end

local function open_follow(path)
  if not follow then
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.seen(path)
  path = util.abspath(path)
  return path ~= nil and baseline[path] ~= nil
end

function M.file_event(path, source)
  path = util.abspath(path)
  if not path or user_just_wrote(path) then
    return
  end
  remember_baseline(path)
  open_follow(path)
  decorate(path)
  return source
end

local function payload_path(payload)
  local input = payload.tool_input or payload.toolInput or {}
  if type(input) ~= "table" then
    return nil
  end
  local path = input.file_path or input.filePath or input.path
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return path
end

function M.event(payload)
  if type(payload) ~= "table" then
    return false
  end
  local name = payload.hook_event_name or payload.hookEventName or ""
  if name == "Stop" then
    return M.finish_turn()
  end
  local path = payload_path(payload)
  if not path then
    return false
  end
  M.file_event(path, "claude")
  return true
end

local function ignored(path)
  for segment in path:gmatch("[^/]+") do
    if IGNORE[segment] then
      return true
    end
  end
end

function M.start_watch(dir)
  M.stop_watch()
  dir = util.abspath(dir or vim.fn.getcwd())
  if not dir then
    return
  end
  local handle = vim.uv.new_fs_event()
  local ok = handle:start(dir, { recursive = true }, function(err, filename)
    if err or not filename or filename == "" or ignored(filename) then
      return
    end
    vim.schedule(function()
      local path = filename:sub(1, 1) == "/" and filename or (dir .. "/" .. filename)
      M.file_event(path, "agent")
    end)
  end)
  if not ok then
    handle:close()
    notify("could not watch " .. dir, vim.log.levels.WARN)
    return
  end
  watch_handle = handle
end

function M.stop_watch()
  if watch_handle then
    watch_handle:stop()
    watch_handle:close()
    watch_handle = nil
  end
end

local function write_checkpoint()
  if not turn_id or next(turn) == nil then
    return nil
  end
  local dir = root_dir() .. "/" .. turn_id
  vim.fn.mkdir(dir, "p")
  local files = {}
  for path in pairs(turn) do
    local rel = path:gsub("^/", "")
    local dest = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
    util.write_private(dest, baseline[path] or "")
    files[#files + 1] = path
  end
  table.sort(files)
  util.write_private(dir .. "/manifest.json", vim.json.encode({ files = files }))
  local finished = turn_id
  turn = {}
  turn_id = nil
  baseline = {}
  return finished
end

function M.finish_turn()
  local id = write_checkpoint()
  if not id then
    return false
  end
  notify("checkpoint " .. id)
  return id
end

local function latest_checkpoint()
  local dir = root_dir()
  local names = vim.fn.readdir(dir)
  if type(names) ~= "table" or #names == 0 then
    return nil
  end
  table.sort(names)
  return dir .. "/" .. names[#names]
end

function M.undo_turn()
  local dir = latest_checkpoint()
  if not dir then
    return nil, "no agent turn to undo"
  end
  local ok, lines = pcall(vim.fn.readfile, dir .. "/manifest.json")
  if not ok or not lines then
    return nil, "checkpoint has no manifest"
  end
  local decoded_ok, manifest = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(manifest) ~= "table" then
    return nil, "checkpoint manifest is unreadable"
  end
  for _, path in ipairs(manifest.files or {}) do
    local rel = path:gsub("^/", "")
    local src = dir .. "/" .. rel
    local f = io.open(src, "rb")
    local text = f and f:read("*a") or ""
    if f then
      f:close()
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    util.write_private(path, text)
    local buf = buf_for(path)
    if buf and not vim.bo[buf].modified then
      vim.cmd("checktime")
    end
    baseline[path] = nil
    decorate(path)
  end
  return dir
end

function M.revert_hunk()
  local path = util.abspath(vim.api.nvim_buf_get_name(0))
  if not path or not baseline[path] then
    return nil, "no agent edit to revert here"
  end
  local after, buf = current_text(path)
  if not buf then
    return nil, "the file is not open"
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk
  for _, item in ipairs(hunks_between(baseline[path], after)) do
    local start_b, count_b = item[3], item[4]
    if count_b > 0 and line >= start_b and line <= start_b + count_b - 1 then
      hunk = item
      break
    end
    if count_b == 0 and (line == start_b or line == start_b + 1) then
      hunk = item
      break
    end
  end
  if not hunk then
    return nil, "no agent hunk under the cursor"
  end
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  local old = vim.split(baseline[path], "\n", { plain = true })
  if baseline[path]:sub(-1) == "\n" then
    old[#old] = nil
  end
  local restored = {}
  if count_a > 0 then
    for i = start_a, start_a + count_a - 1 do
      restored[#restored + 1] = old[i] or ""
    end
  end
  local from, to
  if count_b == 0 then
    from, to = start_b, start_b
  else
    from = start_b - 1
    to = start_b - 1 + count_b
  end
  vim.api.nvim_buf_set_lines(buf, from, to, false, restored)
  decorate(path)
  return true
end

function M.stop()
  M.stop_watch()
  user_writes = {}
end

return M
