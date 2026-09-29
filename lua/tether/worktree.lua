-- One git worktree per agent pane. Closing the pane leaves the worktree in
-- place. :TetherWorktreeClean removes one after it has no uncommitted work.
local diff = require("tether.diff")
local util = require("tether.util")

local M = {}

local registry_path
local directory
local spawned = {}

local function notify(msg, level)
  vim.notify("tether: " .. msg, level or vim.log.levels.INFO)
end

local function registry()
  if registry_path and registry_path ~= "" then
    return registry_path
  end
  return vim.fn.stdpath("state") .. "/tether/worktrees.json"
end

function M.configure(opts)
  opts = opts or {}
  if opts.registry ~= nil then
    registry_path = opts.registry
  end
  if opts.directory ~= nil then
    directory = opts.directory
  end
end

local function worktree_parent()
  if directory and directory ~= "" then
    return directory
  end
  return vim.fn.stdpath("state") .. "/tether/worktrees"
end

local function read_registry()
  local ok, lines = pcall(vim.fn.readfile, registry())
  if not ok or not lines or #lines == 0 then
    return {}
  end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(data) == "table" then
    return data
  end
  return {}
end

local function write_registry(data)
  vim.fn.mkdir(vim.fn.fnamemodify(registry(), ":h"), "p")
  util.write_private(registry(), vim.json.encode(data))
end

function M.list()
  return read_registry()
end

local function git(cwd, args)
  return vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
end

local function toplevel()
  local out = git(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
  if out.code ~= 0 then
    return nil, vim.trim(out.stderr or "not a git repository")
  end
  return vim.trim(out.stdout or "")
end

local function pane_id(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout or "")
  if ok and type(decoded) == "table" then
    local result = decoded.result or decoded
    if type(result) == "table" then
      return result.pane_id or result.paneId or result.id
    end
  end
  local line = vim.trim(stdout or "")
  if line ~= "" and not line:find("\n") then
    return line
  end
end

-- Creates the worktree, then asks Herdr or tmux to open the agent there.
-- handles is the tether adapter table. kind is the agent name, such as "claude".
function M.spawn(kind, handles, done)
  if type(kind) ~= "string" or kind == "" then
    return nil, "name an agent, for example :TetherSpawn claude"
  end
  local top, err = toplevel()
  if not top then
    return nil, err
  end
  local sha = git(top, { "rev-parse", "HEAD" })
  if sha.code ~= 0 then
    return nil, vim.trim(sha.stderr or "git rev-parse failed")
  end
  local id = kind .. "-" .. tostring(vim.uv.hrtime())
  local dir = worktree_parent() .. "/" .. id
  local branch = "tether/" .. id
  local added = git(top, { "worktree", "add", "-b", branch, dir, "HEAD" })
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr or "git worktree add failed")
  end
  local record = {
    kind = kind,
    dir = dir,
    branch = branch,
    base = vim.trim(sha.stdout or ""),
    top = top,
  }
  local function finish(source, pane, message)
    if pane then
      record.source = source
      record.pane_id = pane
      spawned[source .. "\0" .. pane] = record
    end
    local all = read_registry()
    all[#all + 1] = record
    write_registry(all)
    if done then
      done(record, message)
    end
    return record
  end
  local herdr = handles and handles.herdr
  if herdr and herdr.spawn then
    herdr.spawn(dir, kind, function(ok, pane, message)
      vim.schedule(function()
        if ok and pane then
          finish("herdr", pane, message)
        else
          finish(nil, nil, message or "herdr did not open a pane")
          notify("worktree " .. dir .. "\n" .. tostring(message or "start the agent there yourself"))
        end
      end)
    end)
    return true
  end
  local tmux = handles and handles.tmux
  if tmux and tmux.spawn then
    tmux.spawn(dir, kind, function(ok, pane, message)
      vim.schedule(function()
        if ok and pane then
          finish("tmux", pane, message)
        else
          finish(nil, nil, message or "tmux did not open a pane")
          notify("worktree " .. dir .. "\n" .. tostring(message or ""))
        end
      end)
    end)
    return true
  end
  finish(nil, nil, nil)
  notify("worktree " .. dir .. "\ncd " .. dir .. " && " .. kind)
  return record
end

local function dirty(dir)
  local out = git(dir, { "status", "--porcelain" })
  return out.code ~= 0 or vim.trim(out.stdout or "") ~= ""
end

function M.clean(dir)
  local all = read_registry()
  local kept = {}
  local found
  for _, record in ipairs(all) do
    if record.dir == dir then
      found = record
    else
      kept[#kept + 1] = record
    end
  end
  if not found then
    return nil, "that worktree was not created by tether"
  end
  if dirty(dir) then
    return nil, dir .. " has uncommitted work"
  end
  local removed = git(found.top or dir, { "worktree", "remove", dir })
  if removed.code ~= 0 then
    return nil, vim.trim(removed.stderr or "git worktree remove failed")
  end
  write_registry(kept)
  return true
end

-- When a spawned agent goes idle after working, open the branch diff.
function M.on_status(data)
  if type(data) ~= "table" or data.status ~= "idle" or data.previous ~= "working" then
    return false
  end
  local record = spawned[(data.source or "") .. "\0" .. tostring(data.pane_id)]
  if not record then
    return false
  end
  local names = git(record.dir, { "diff", "--name-only", record.base .. "...HEAD" })
  if names.code ~= 0 then
    notify("could not diff " .. record.branch, vim.log.levels.WARN)
    return false
  end
  local files = {}
  for line in (names.stdout or ""):gmatch("[^\n]+") do
    files[#files + 1] = record.dir .. "/" .. line
  end
  if #files == 0 then
    notify(record.kind .. " finished with no commits on " .. record.branch)
    return false
  end
  vim.fn.setqflist({}, "r", {
    title = "tether " .. record.branch,
    items = vim.tbl_map(function(path)
      return { filename = path, lnum = 1, text = record.branch }
    end, files),
  })
  local opened = 0
  for i, path in ipairs(files) do
    if i > 8 then
      break
    end
    local f = io.open(path, "rb")
    local text = f and f:read("*a") or ""
    if f then
      f:close()
    end
    local ok = diff.open(path, text, function() end, { adapter = record.kind })
    if ok then
      opened = opened + 1
    end
  end
  notify(string.format("%s finished. %d file(s) on %s", record.kind, #files, record.branch))
  return opened > 0
end

return M
