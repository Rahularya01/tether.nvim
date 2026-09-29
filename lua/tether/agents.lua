-- Agent panes as a dashboard and a statusline string.
-- Herdr already lists agents on its own timer. This module reads that snapshot
-- and asks tmux only while the dashboard is open or the statusline is in use,
-- so a tick is one listing, not one per agent.
local events = require("tether.events")
local panes = require("tether.panes")

local M = {}

-- Herdr reports these when the agent is waiting on the user. tmux has no
-- status field, so those panes show "?" and never match.
local BLOCKED = {
  blocked = true,
  waiting = true,
  needs_input = true,
  needs_permission = true,
  permission = true,
}

local QUIET_MS = 4000

local get_handles
local generation = 0
local timer
local last_status = {}
local items = {}
local line = ""
local statusline_at = 0
local dashboard_buf
local dashboard_win
local origin_win

local function notify(msg, level)
  vim.notify("tether: " .. msg, level or vim.log.levels.INFO)
end

function M.attach(handles_of)
  get_handles = handles_of
end

function M.origin()
  return origin_win
end

local function status_of(agent)
  local status = agent.agent_status
  if status == nil or status == "" then
    return "?"
  end
  return status
end

local function fit(text, width)
  text = text or ""
  if #text <= width then
    return text
  end
  return text:sub(#text - width + 1)
end

-- The last line of a pane title, which is the part still on screen.
local function title_tail(agent)
  local title = agent.terminal_title_stripped or agent.terminal_title or ""
  title = title:gsub("%s+$", "")
  local last = title:match("([^\n]*)$") or ""
  return fit(vim.trim(last), 48)
end

function M.format_statusline(list)
  local parts = {}
  for _, item in ipairs(list or {}) do
    parts[#parts + 1] = (item.agent.agent or "?") .. ":" .. status_of(item.agent)
  end
  return table.concat(parts, " ")
end

function M.rows(list)
  if not list or #list == 0 then
    return { "no agent panes" }
  end
  local lines = {
    string.format("%-8s %-12s %-18s %-24s %s", "AGENT", "STATE", "PANE", "DIRECTORY", "TITLE"),
  }
  for _, item in ipairs(list) do
    local agent = item.agent
    lines[#lines + 1] = string.format(
      "%-8s %-12s %-18s %-24s %s",
      fit(agent.agent or "", 8),
      fit(status_of(agent), 12),
      fit(agent.label or agent.pane_id or "", 18),
      fit(agent.cwd or "", 24),
      title_tail(agent)
    )
  end
  return lines
end

local function item_at(lnum)
  if #items == 0 then
    return nil
  end
  return items[lnum - 1]
end

local function render()
  if not dashboard_buf or not vim.api.nvim_buf_is_valid(dashboard_buf) then
    return
  end
  local cursor
  if dashboard_win and vim.api.nvim_win_is_valid(dashboard_win) then
    cursor = vim.api.nvim_win_get_cursor(dashboard_win)
  end
  local lines = M.rows(items)
  vim.bo[dashboard_buf].modifiable = true
  vim.api.nvim_buf_set_lines(dashboard_buf, 0, -1, false, lines)
  vim.bo[dashboard_buf].modifiable = false
  vim.bo[dashboard_buf].modified = false
  if cursor and dashboard_win and vim.api.nvim_win_is_valid(dashboard_win) then
    cursor[1] = math.min(cursor[1], #lines)
    pcall(vim.api.nvim_win_set_cursor, dashboard_win, cursor)
  end
end

local function apply(list, gen)
  if gen ~= generation then
    return
  end
  items = list
  line = M.format_statusline(list)
  local seen = {}
  for _, item in ipairs(list) do
    local key = item.source .. "\0" .. tostring(item.agent.pane_id)
    seen[key] = true
    local status = status_of(item.agent)
    local prev = last_status[key]
    if prev ~= nil and prev ~= status then
      events.emit("TetherAgent", {
        source = item.source,
        agent = item.agent.agent,
        pane_id = item.agent.pane_id,
        status = status,
        previous = prev,
      })
      if BLOCKED[status] and not BLOCKED[prev] then
        notify(string.format("%s in %s is %s", item.agent.agent, item.source, status))
      end
    end
    last_status[key] = status
  end
  for key in pairs(last_status) do
    if not seen[key] then
      last_status[key] = nil
    end
  end
  render()
end

-- Herdr's handle.agents is the listing its own timer just fetched. Calling
-- targets() here would run `herdr agent list` a second time.
local function collect(callback)
  local handles = get_handles and get_handles() or {}
  local found = {}
  local herdr = handles.herdr
  if herdr and herdr.agents then
    for _, agent in ipairs(herdr.agents) do
      found[#found + 1] = { source = "herdr", handle = herdr, agent = agent }
    end
  end
  local tmux = handles.tmux
  if not (tmux and tmux.targets) then
    callback(found)
    return
  end
  tmux.targets(function(agents)
    for _, agent in ipairs(agents or {}) do
      found[#found + 1] = { source = "tmux", handle = tmux, agent = agent }
    end
    callback(found)
  end)
end

function M.poll(callback)
  local gen = generation
  collect(function(list)
    apply(list, gen)
    if callback and gen == generation then
      callback(list)
    end
  end)
end

local function watching()
  if dashboard_buf and vim.api.nvim_buf_is_valid(dashboard_buf) then
    return true
  end
  return (vim.uv.now() - statusline_at) < QUIET_MS
end

local function ensure_timer()
  if timer or not get_handles then
    return
  end
  local gen = generation
  timer = vim.uv.new_timer()
  timer:start(2000, 2000, function()
    vim.schedule(function()
      if gen ~= generation then
        return
      end
      if not watching() then
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
        return
      end
      M.poll()
    end)
  end)
end

function M.statusline()
  statusline_at = vim.uv.now()
  ensure_timer()
  if line == "" then
    M.poll()
  end
  return line
end

local function find_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(name, 1, true) then
      return buf
    end
  end
end

function M.open()
  origin_win = vim.api.nvim_get_current_win()
  dashboard_buf = find_buf("tether://agents")
  if not dashboard_buf or not vim.api.nvim_buf_is_valid(dashboard_buf) then
    dashboard_buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, dashboard_buf, "tether://agents")
    vim.bo[dashboard_buf].buftype = "nofile"
    vim.bo[dashboard_buf].bufhidden = "wipe"
    vim.bo[dashboard_buf].swapfile = false
    vim.bo[dashboard_buf].modifiable = false
    local buf = dashboard_buf
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        if dashboard_buf == buf then
          dashboard_buf = nil
          dashboard_win = nil
        end
      end,
    })
    vim.keymap.set("n", "<CR>", function()
      local item = item_at(vim.api.nvim_win_get_cursor(0)[1])
      if item then
        require("tether").dashboard_focus(item)
      end
    end, { buffer = buf, silent = true, desc = "Tether: focus this agent pane" })
    vim.keymap.set("n", "s", function()
      local item = item_at(vim.api.nvim_win_get_cursor(0)[1])
      if item then
        require("tether").dashboard_send(item)
      end
    end, { buffer = buf, silent = true, desc = "Tether: send the current file to this agent" })
    vim.keymap.set("n", "q", function()
      if vim.api.nvim_win_is_valid(dashboard_win or -1) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(dashboard_win, true)
      end
    end, { buffer = buf, silent = true, desc = "Tether: close the agent list" })
  end
  local existing
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == dashboard_buf then
      existing = win
    end
  end
  if existing then
    vim.api.nvim_set_current_win(existing)
    dashboard_win = existing
  else
    vim.cmd("botright 12split")
    dashboard_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(dashboard_win, dashboard_buf)
  end
  vim.wo[dashboard_win].cursorline = true
  ensure_timer()
  M.poll(function()
    if dashboard_win and vim.api.nvim_win_is_valid(dashboard_win) and #items > 0 then
      local cursor = vim.api.nvim_win_get_cursor(dashboard_win)
      if cursor[1] < 2 then
        pcall(vim.api.nvim_win_set_cursor, dashboard_win, { 2, 0 })
      end
    end
  end)
end

-- A scratch list for sending one payload to several panes. Space toggles a
-- row. Enter sends to every marked row, or the row under the cursor when
-- nothing is marked.
function M.choose(list, on_done)
  local marked = {}
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "tether://send")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local win
  local function paint()
    local lines = {}
    for i, item in ipairs(list) do
      local mark = marked[i] and "*" or " "
      lines[i] = mark .. " " .. string.format("%-6s %s", item.source, panes.describe(item.agent, item.handle.here))
    end
    if #lines == 0 then
      lines[1] = "no agent panes"
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  local function finish(chosen)
    if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
    on_done(chosen or {})
  end
  paint()
  vim.keymap.set("n", "<Space>", function()
    local i = vim.api.nvim_win_get_cursor(0)[1]
    if list[i] then
      if marked[i] then
        marked[i] = nil
      else
        marked[i] = true
      end
      paint()
    end
  end, { buffer = buf, silent = true, desc = "Tether: mark this agent" })
  vim.keymap.set("n", "<CR>", function()
    local chosen = {}
    for i, item in ipairs(list) do
      if marked[i] then
        chosen[#chosen + 1] = item
      end
    end
    if #chosen == 0 then
      local item = list[vim.api.nvim_win_get_cursor(0)[1]]
      if item then
        chosen[1] = item
      end
    end
    finish(chosen)
  end, { buffer = buf, silent = true, desc = "Tether: send to the marked agents" })
  vim.keymap.set("n", "q", function()
    finish({})
  end, { buffer = buf, silent = true, desc = "Tether: cancel" })
  vim.cmd("botright 12split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].cursorline = true
end

function M.stop()
  generation = generation + 1
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  last_status = {}
  items = {}
  line = ""
  statusline_at = 0
  dashboard_buf = nil
  dashboard_win = nil
  origin_win = nil
end

return M
