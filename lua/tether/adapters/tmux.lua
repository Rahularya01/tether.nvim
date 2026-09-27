-- Agent CLIs running in tmux panes. tmux has no notion of agents, so a pane
-- counts when a process under it is a known agent CLI. Text is typed in with
-- `send-keys -l`, which does not press Enter.
local panes = require("tether.panes")

local M = {}

-- Command names of agent CLIs. Node-based ones run as `node .../gemini`, so the
-- first two words of each process's command line are checked.
M.agents = {
  claude = "claude",
  codex = "codex",
  gemini = "gemini",
  opencode = "opencode",
  aider = "aider",
  crush = "crush",
  amp = "amp",
  ["cursor-agent"] = "cursor-agent",
  goose = "goose",
  qwen = "qwen",
}

-- An agent in an editor's own terminal (Claude in Neovim's :terminal) is not
-- this pane's agent. Typing into the pane would type into the editor.
local HOSTS = { nvim = true, vim = true, emacs = true, tmux = true }

local function first_word(command)
  local word = (command or ""):match("^%s*(%S+)")
  return word and vim.fs.basename(word) or nil
end

local FIELDS = {
  "pane_id",
  "session_id",
  "session_name",
  "window_id",
  "window_index",
  "pane_index",
  "pane_pid",
  "pane_current_command",
  "pane_current_path",
  "pane_active",
  "window_active",
  "session_attached",
  "pane_title",
}

local function format()
  local parts = {}
  for _, field in ipairs(FIELDS) do
    parts[#parts + 1] = "#{" .. field .. "}"
  end
  return table.concat(parts, "\t")
end

-- tmux list-panes output -> one table per pane.
function M.parse_panes(stdout)
  local rows = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local values = vim.split(line, "\t", { plain = true })
    if #values >= #FIELDS then
      local row = {}
      for i, field in ipairs(FIELDS) do
        row[field] = values[i]
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

local function agent_name(command)
  if not command or command == "" then
    return nil
  end
  local words = vim.split(vim.trim(command), "%s+")
  for i = 1, math.min(2, #words) do
    local name = M.agents[vim.fs.basename(words[i])]
    if name then
      return name
    end
  end
end

-- ps -A -o pid=,ppid=,args= -> the first agent CLI under each pid.
function M.parse_processes(stdout)
  local children, args = {}, {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local pid, ppid, command = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      args[pid] = command
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
    end
  end
  return function(root)
    local queue, seen = { root }, {}
    while #queue > 0 do
      local pid = table.remove(queue, 1)
      if not seen[pid] then
        seen[pid] = true
        local name = agent_name(args[pid])
        if name then
          return name
        end
        if not HOSTS[first_word(args[pid])] then
          vim.list_extend(queue, children[pid] or {})
        end
      end
    end
  end
end

-- The tmux panes running an agent, plus where Neovim is (nil outside tmux).
function M.find(rows, agent_under, own_pane)
  local here
  for _, row in ipairs(rows) do
    if own_pane and row.pane_id == own_pane then
      here = { workspace = row.session_id, tab = row.window_id, pane = row.pane_id }
    end
  end
  local agents = {}
  for _, row in ipairs(rows) do
    local name = agent_name(row.pane_current_command) or agent_under(row.pane_pid)
    if name then
      agents[#agents + 1] = {
        agent = name,
        pane_id = row.pane_id,
        workspace_id = row.session_id,
        tab_id = row.window_id,
        cwd = row.pane_current_path,
        focused = row.pane_active == "1" and row.window_active == "1" and row.session_attached ~= "0",
        terminal_title = row.pane_title,
        label = string.format("%s:%s.%s", row.session_name, row.window_index, row.pane_index),
      }
    end
  end
  return agents, here
end

local function binary()
  if vim.fn.executable("tmux") == 1 then
    return "tmux"
  end
  for _, path in ipairs({ "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux" }) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
end

-- opts.bin: tmux binary. opts.socket: a tmux -L socket name (tests use their own server).
function M.start(opts)
  opts = opts or {}
  local bin = opts.bin or binary()
  local base = { bin }
  if opts.socket then
    vim.list_extend(base, { "-L", opts.socket })
  end
  local function tmux(args)
    return vim.list_extend(vim.list_extend({}, base), args)
  end

  local handle = {
    env = {},
    detail = bin and "no agent pane" or "tmux not installed",
    on_context = function() end,
    refresh = function() end,
    stop = function() end,
  }

  -- Agents text could go to right now, best first. Inside tmux only panes in
  -- Neovim's own session count. Where Neovim is comes from the same listing, so
  -- it stays right if the pane moves to another session.
  function handle.targets(callback)
    if not bin then
      callback({})
      return
    end
    vim.system(tmux({ "list-panes", "-a", "-F", format() }), { text = true }, function(listing)
      if not listing or listing.code ~= 0 then
        vim.schedule(function()
          handle.detail = "no tmux server"
          callback({})
        end)
        return
      end
      vim.system({ "ps", "-A", "-o", "pid=,ppid=,args=" }, { text = true }, function(ps)
        vim.schedule(function()
          local own = vim.env.TMUX and vim.env.TMUX ~= "" and vim.env.TMUX_PANE or nil
          local agents, here = M.find(M.parse_panes(listing.stdout), M.parse_processes(ps and ps.stdout), own)
          handle.here = here
          local ranked = panes.rank(agents, vim.fn.getcwd(), here, handle.last)
          handle.detail = #ranked == 0 and "no agent pane" or (#ranked .. " agent pane(s)")
          callback(ranked)
        end)
      end)
    end)
  end

  function handle.insert(pane_id, text, done)
    handle.last = pane_id
    vim.system(tmux({ "send-keys", "-t", pane_id, "-l", "--", text }), { text = true }, function(out)
      vim.schedule(function()
        if done then
          done(out and out.code == 0, ((out and out.stdout) or "") .. ((out and out.stderr) or ""))
        end
      end)
    end)
  end

  return handle
end

return M
