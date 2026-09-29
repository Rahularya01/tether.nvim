local context = require("tether.context")
local events = require("tether.events")
local log = require("tether.log")

local M = {}

local adapters = {
  claude = require("tether.adapters.claude"),
  gemini = require("tether.adapters.gemini"),
  codex = require("tether.adapters.codex"),
  opencode = require("tether.adapters.opencode"),
  herdr = require("tether.adapters.herdr"),
  tmux = require("tether.adapters.tmux"),
}

local ALL = { "claude", "gemini", "codex", "opencode", "herdr", "tmux" }
-- Adapters that find agent CLIs in terminal panes, in the order the picker lists them.
local PANE_SOURCES = { "herdr", "tmux" }

local activity = require("tether.activity")
local agents = require("tether.agents")
local hooks = require("tether.hooks")
local panes = require("tether.panes")
local worktree = require("tether.worktree")
local util = require("tether.util")
local diff = require("tether.diff")

local running = false
local handles = {}
-- "always" asks which agent gets the text every time. "auto" asks only when there are several.
local pick = "always"
-- { source, pane_id } of the agent picked last. It is listed first next time.
local last_target
-- agent name -> the same shape, so a review comment can find that agent's pane.
local last_by_agent = {}
-- Assigned after the send path exists. setup() installs it on the diff module.
local on_feedback
local mapped = {}

-- Set to false to skip one, or keymaps = false to skip all of them.
M.default_keymaps = {
  send_file = "<leader>af",
  send_selection = "<leader>ao",
  send_diagnostic = "<leader>ad",
  send_node = "<leader>an",
  send_prompt = "<leader>ap",
  send_many = "<leader>am",
  send_quickfix = "<leader>aq",
  send_diff = "<leader>ag",
  send_terminal = "<leader>at",
  send_references = "<leader>ar",
  focus = "<leader>aj",
}
local env_keys = {}
local timer
local watch
local group
local focus_after = false
-- When true, a send writes an edited buffer first so line numbers match the file.
local save_on_send = false
local client_counts = {}
-- Tests set this so a persisted last agent does not leak in from the machine.
M._state_file = nil

local function set_env(key, value)
  vim.env[key] = value
  env_keys[key] = true
end

local function clear_env()
  for key in pairs(env_keys) do
    vim.env[key] = nil
  end
  env_keys = {}
end

local function clear_keymaps()
  for _, map in ipairs(mapped) do
    pcall(vim.keymap.del, map[1], map[2])
  end
  mapped = {}
end

local function set_keymaps(config)
  clear_keymaps()
  if config == false then
    return
  end
  config = vim.tbl_extend("force", M.default_keymaps, config or {})
  local function map(modes, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(modes, lhs, rhs, { desc = desc, silent = true })
    for _, mode in ipairs(modes) do
      mapped[#mapped + 1] = { mode, lhs }
    end
  end
  map({ "n" }, config.send_file, function()
    M.send("file")
  end, "Tether: add file to the prompt")
  map({ "n", "x" }, config.send_selection, function()
    M.send("selection")
  end, "Tether: add selection to the prompt")
  map({ "n" }, config.send_diagnostic, function()
    M.send("diagnostic")
  end, "Tether: add the diagnostic under the cursor to the prompt")
  map({ "n" }, config.send_node, function()
    M.send("node")
  end, "Tether: add the function or type under the cursor to the prompt")
  map({ "n", "x" }, config.send_prompt, function()
    M.send_prompt()
  end, "Tether: add an instruction with the file or selection")
  map({ "n" }, config.send_many, function()
    M.send_many("file")
  end, "Tether: add the file to several agents")
  map({ "x" }, config.send_many, function()
    M.send_many("selection")
  end, "Tether: add the selection to several agents")
  map({ "n" }, config.send_quickfix, function()
    M.send("quickfix")
  end, "Tether: add the quickfix list to the prompt")
  map({ "n" }, config.send_diff, function()
    M.send_diff("unstaged")
  end, "Tether: add the unstaged diff to the prompt")
  map({ "n" }, config.send_terminal, function()
    M.send_terminal()
  end, "Tether: add the end of a terminal buffer to the prompt")
  map({ "n" }, config.send_references, function()
    M.send_references()
  end, "Tether: add the definition and references under the cursor")
  map({ "n" }, config.focus, function()
    M.focus()
  end, "Tether: focus the last agent pane")
end

function M.is_running()
  return running
end

function M.state()
  return handles
end

function M.stop()
  agents.stop()
  activity.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if watch then
    watch:stop()
    watch:close()
    watch = nil
  end
  client_counts = {}
  if group then
    vim.api.nvim_clear_autocmds({ group = group })
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  for _, handle in pairs(handles) do
    if handle.stop then
      pcall(handle.stop)
    end
  end
  handles = {}
  clear_env()
  clear_keymaps()
  running = false
end

local function push()
  -- One snapshot per push, built only if an adapter with a client asks for it.
  local snap
  local function get()
    snap = snap or context.snapshot()
    return snap
  end
  for _, handle in pairs(handles) do
    if handle.on_context then
      pcall(handle.on_context, get)
    end
  end
end

local function schedule_push()
  if not timer then
    return
  end
  timer:stop()
  timer:start(50, 0, vim.schedule_wrap(push))
end

local function state_file()
  if M._state_file and M._state_file ~= "" then
    return M._state_file
  end
  return vim.fn.stdpath("state") .. "/tether-last.json"
end

local function load_last()
  local ok, lines = pcall(vim.fn.readfile, state_file())
  if not ok or not lines or #lines == 0 then
    return
  end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(data) == "table" and type(data.source) == "string" and data.pane_id then
    last_target = { source = data.source, pane_id = data.pane_id, agent = data.agent }
    if type(data.by_agent) == "table" then
      last_by_agent = data.by_agent
    elseif data.agent then
      last_by_agent[data.agent] = last_target
    end
  end
end

local function remember(item)
  last_target = { source = item.source, pane_id = item.agent.pane_id, agent = item.agent.agent }
  if item.agent.agent then
    last_by_agent[item.agent.agent] = {
      source = item.source,
      pane_id = item.agent.pane_id,
      agent = item.agent.agent,
    }
  end
  pcall(
    util.write_private,
    state_file(),
    vim.json.encode({
      source = last_target.source,
      pane_id = last_target.pane_id,
      agent = last_target.agent,
      by_agent = last_by_agent,
    })
  )
end

local function watch_clients()
  for name, handle in pairs(handles) do
    local n = 0
    if handle.client_count then
      n = handle.client_count() or 0
    elseif handle.connected then
      n = 1
    end
    local prev = client_counts[name]
    if prev ~= n then
      client_counts[name] = n
      if not (prev == nil and n == 0) then
        log.record(name, "clients=" .. tostring(n))
        events.emit("TetherClient", { adapter = name, clients = n })
      end
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  if running then
    M.stop()
  end
  local enabled = opts.adapters or ALL
  pick = opts.pick or "always"
  focus_after = opts.focus and true or false
  save_on_send = opts.save_on_send and true or false
  diff.configure(opts.review_keymaps)
  load_last()
  local failures = {}
  for _, name in ipairs(enabled) do
    local factory = adapters[name]
    if not factory then
      failures[#failures + 1] = name .. ": unknown adapter"
    else
      local handle, err = factory.start(opts[name] or {})
      if not handle then
        failures[#failures + 1] = name .. ": " .. tostring(err)
        log.record(name, "failed to start: " .. tostring(err))
      else
        log.record(name, "listening")
        handles[name] = handle
        -- Adapters call this when a client connects or drops, so the count is not only polled.
        handle.on_change = function()
          if running then
            watch_clients()
          end
        end
        for key, value in pairs(handle.env or {}) do
          set_env(key, value)
        end
      end
    end
  end

  group = vim.api.nvim_create_augroup("tether.nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged" }, {
    group = group,
    callback = function()
      context.observe("selection")
      schedule_push()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      context.observe("focus")
      schedule_push()
    end,
  })
  vim.api.nvim_create_autocmd({ "DirChanged", "BufWritePost", "DiagnosticChanged" }, {
    group = group,
    callback = function(ev)
      if ev.event == "BufWritePost" then
        activity.note_user_write(ev.file)
      end
      for _, handle in pairs(handles) do
        if handle.refresh then
          pcall(handle.refresh)
        end
      end
      schedule_push()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TetherAgent",
    callback = function(ev)
      worktree.on_status(ev.data)
    end,
  })

  set_keymaps(opts.keymaps)
  agents.attach(function()
    return handles
  end)
  if vim.v.servername and vim.v.servername ~= "" then
    set_env("TETHER_NVIM_SERVER", vim.v.servername)
  end
  activity.configure({ follow = opts.follow_edits, checkpoints = opts.checkpoints })
  activity.stop()
  if opts.watch then
    activity.start_watch(opts.watch == true and vim.fn.getcwd() or opts.watch)
  end
  worktree.configure({ registry = opts.worktrees })
  diff.on_feedback = function(session, text)
    if on_feedback then
      on_feedback(session, text)
    end
  end
  timer = vim.uv.new_timer()
  watch = vim.uv.new_timer()
  -- Adapters report changes themselves. This is the safety net.
  watch:start(2000, 2000, vim.schedule_wrap(watch_clients))
  running = true
  context.observe("focus")
  push()
  watch_clients()
  return failures
end

function M.status()
  local lines = {}
  if not running then
    lines[1] = "tether.nvim is stopped"
  else
    lines[1] = "tether.nvim is attached"
    for _, name in ipairs(ALL) do
      local handle = handles[name]
      if not handle then
        lines[#lines + 1] = "  " .. name .. ": off"
      else
        local detail = handle.describe and handle.describe() or handle.detail
        lines[#lines + 1] = "  " .. name .. ": " .. (detail or "not connected")
      end
    end
  end
  local waiting = diff.waiting()
  if #waiting > 0 then
    local parts = {}
    for _, item in ipairs(waiting) do
      local note = item.path
      if item.queued > 0 then
        note = string.format("%s (+%d waiting)", item.path, item.queued)
      end
      parts[#parts + 1] = note
    end
    lines[#lines + 1] = "  reviews: " .. table.concat(parts, ", ")
  end
  return lines
end

function M.env_script()
  local lines = {}
  for key in pairs(env_keys) do
    local value = vim.env[key]
    if value and value ~= "" then
      lines[#lines + 1] = "export " .. key .. "=" .. value
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

local function notify(msg, level)
  vim.notify("tether: " .. msg, level or vim.log.levels.INFO)
end

local function shorten(text)
  text = (text or ""):gsub("%s+", " ")
  if #text > 180 then
    return text:sub(1, 180) .. "..."
  end
  return text
end

local severity_name = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warning",
  [vim.diagnostic.severity.INFO] = "Information",
  [vim.diagnostic.severity.HINT] = "Hint",
}

local function severity_label(item)
  return severity_name[item.severity] or "Error"
end

-- What to send: the whole file, or lines first..last of it (1-based).
-- range is { line1, line2 } from a command. Without it, use the live visual
-- selection, or the last one ('< and '>) from normal mode.
-- A buffer with no path on disk still sends its text.
local function target(kind, range)
  local snap = context.snapshot()
  local path = snap.active and snap.active.path
  if kind == "quickfix" then
    local list = vim.fn.getqflist()
    if #list == 0 then
      return nil, "quickfix list is empty"
    end
    local lines = {}
    for _, item in ipairs(list) do
      local name = ""
      if item.bufnr and item.bufnr > 0 then
        name = vim.api.nvim_buf_get_name(item.bufnr)
      end
      if name == "" then
        name = item.filename or ""
      end
      if name ~= "" then
        name = vim.fn.fnamemodify(name, ":.")
      end
      lines[#lines + 1] = string.format("%s:%s: %s", name, tostring(item.lnum or 0), item.text or "")
    end
    return { text = table.concat(lines, "\n"), note = "quickfix" }
  end
  if kind == "diagnostic" then
    if not path then
      return nil, "this buffer is not a file on disk"
    end
    local item = context.cursor_diagnostic()
    if not item then
      return nil, "no diagnostic under the cursor"
    end
    local first = item.lnum + 1
    local last = (item.end_lnum or item.lnum) + 1
    return {
      path = path,
      first = first,
      last = last,
      text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n"),
      note = string.format("[%s] %s", severity_label(item), shorten(item.message)),
    }
  end
  if kind == "node" then
    if not path then
      return nil, "this buffer is not a file on disk"
    end
    local node, why = context.enclosing_node()
    if not node then
      return nil, why
    end
    local start_row, _, end_row, end_col = node:range()
    local first = start_row + 1
    local last = end_row + 1
    if end_col == 0 and last > first then
      last = last - 1
    end
    return {
      path = path,
      first = first,
      last = last,
      text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n"),
    }
  end
  if kind == "file" then
    if path then
      return { path = path }
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    if text == "" then
      return nil, "this buffer is empty"
    end
    return { text = text }
  end
  local first, last
  if range then
    first, last = range[1], range[2]
  else
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      first, last = vim.fn.line("v"), vim.fn.line(".")
    else
      first, last = vim.fn.line("'<"), vim.fn.line("'>")
      if first == 0 or last == 0 then
        return nil, "no selection. Select some lines first"
      end
    end
  end
  if first > last then
    first, last = last, first
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
  if not path and text == "" then
    return nil, "this buffer is not a file on disk"
  end
  return { path = path, first = first, last = last, text = text }
end

-- @path or @path#L3-5, the reference Claude Code expands when the prompt is sent.
local function lines(t)
  if not t.first then
    return ""
  end
  if t.last ~= t.first then
    return t.first .. "-" .. t.last
  end
  return tostring(t.first)
end

-- The directory paths are written relative to: where the receiving agent runs when we
-- know it, otherwise Neovim's working directory.
local function base_dir(agent)
  return agent and agent.cwd and agent.cwd ~= "" and agent.cwd or vim.fn.getcwd()
end

-- @path#L3-5. Claude Code reads a path with spaces as @"my file.lua#L3-5".
local function reference(t, root)
  if not t.path then
    return t.text or ""
  end
  local path = util.relative(t.path, root or vim.fn.getcwd())
  local range = t.first and ("#L" .. lines(t)) or ""
  if path:find("%s") then
    return '@"' .. path .. range .. '"'
  end
  return "@" .. path .. range
end

local function leave_visual()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

-- path or path:3-5, for agents other than Claude. A buffer with no path sends its text.
local function plain(t, root)
  if not t.path then
    return t.text or ""
  end
  local path = util.relative(t.path, root or vim.fn.getcwd())
  if path:find("%s") then
    path = '"' .. path .. '"'
  end
  if t.first then
    return path .. ":" .. lines(t)
  end
  return path
end

local function mention_label(t, ref)
  if t.path then
    return ref
  end
  return "the buffer text"
end

local function with_note(t, ref)
  if t.note and t.note ~= "" then
    return ref .. " " .. t.note
  end
  return ref
end

-- Claude Code over its IDE connection, then OpenCode. Used when no pane agent is available.
local function send_direct(t, ref)
  local shown = mention_label(t, ref)
  local claude = handles.claude
  if t.path and claude and claude.send and claude.client_count and claude.client_count() > 0 then
    -- Claude Code takes 0-based lines here and shows them 1-based.
    claude.send("at_mentioned", {
      filePath = t.path,
      lineStart = t.first and (t.first - 1) or nil,
      lineEnd = t.last and (t.last - 1) or nil,
    })
    notify("added " .. with_note(t, shown) .. " to the Claude Code prompt. Press Enter there to send it")
    return true
  end

  local opencode = handles.opencode
  if opencode and opencode.append then
    local text
    if not t.path then
      text = (t.text or "") .. "\n"
    else
      text = with_note(t, ref) .. " "
      if t.text and t.text ~= "" and not t.note then
        text = ref .. "\n" .. t.text .. "\n"
      end
    end
    local started = opencode.append(text, function(ok, err)
      if ok then
        notify("added " .. with_note(t, shown) .. " to the OpenCode prompt. Press Enter there to send it")
      else
        notify(tostring(err), vim.log.levels.WARN)
      end
    end)
    if started ~= false then
      return true
    end
  end

  local why = "nothing to send to. No agent pane in Herdr or tmux, no Claude Code connection, and no OpenCode server"
  if not t.path then
    why = "this buffer is not a file on disk, and no agent pane or OpenCode server can take its text"
  end
  notify(why, vim.log.levels.WARN)
  return false
end

local function focus_pane(item)
  if not item.handle.focus then
    notify(item.source .. " cannot focus a pane", vim.log.levels.WARN)
    return
  end
  item.handle.focus(item.agent.pane_id, function(ok, message)
    if not ok then
      notify(
        string.format("could not focus %s in %s\n%s", item.agent.agent, item.source, tostring(message)),
        vim.log.levels.WARN
      )
    end
  end)
end

local function send_pane(item, t, ref)
  local agent = item.agent
  local root = base_dir(agent)
  local body = (t.path and agent.agent == "claude") and reference(t, root) or plain(t, root)
  local text = with_note(t, body)
  local shown = mention_label(t, text)
  remember(item)
  local where = item.source .. " " .. (agent.label or agent.pane_id)
  item.handle.insert(agent.pane_id, text .. " ", function(ok, message)
    if ok then
      notify(string.format("added %s to %s in %s. Press Enter there to send it", shown, agent.agent, where))
      if focus_after then
        focus_pane(item)
      end
    else
      notify(
        string.format("%s in %s did not take %s\n%s", agent.agent, where, shown, tostring(message)),
        vim.log.levels.WARN
      )
    end
  end)
end

-- Every agent in Herdr and tmux panes, as { source, handle, agent }. Calls back once all have answered.
local function pane_targets(callback)
  local sources = {}
  for _, name in ipairs(PANE_SOURCES) do
    local handle = handles[name]
    if handle and handle.targets and handle.insert then
      sources[#sources + 1] = { name = name, handle = handle }
    end
  end
  local pending = #sources
  if pending == 0 then
    callback({})
    return
  end
  local found = {}
  for i, source in ipairs(sources) do
    source.handle.targets(function(agents)
      found[i] = agents
      pending = pending - 1
      if pending > 0 then
        return
      end
      local items = {}
      for k, src in ipairs(sources) do
        for _, agent in ipairs(found[k] or {}) do
          local item = { source = src.name, handle = src.handle, agent = agent }
          if last_target and last_target.source == src.name and last_target.pane_id == agent.pane_id then
            table.insert(items, 1, item)
          else
            items[#items + 1] = item
          end
        end
      end
      callback(items)
    end)
  end
end

-- Typing a long diff or terminal tail through send-keys is slow and easy to
-- garble. Past this size the text is written to a file and the pane gets the path.
local TEXT_LIMIT = 1500

local function spill(t)
  local text = t.text
  if t.path or type(text) ~= "string" or #text <= TEXT_LIMIT then
    return t
  end
  local dir = vim.fn.stdpath("cache") .. "/tether"
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/send-%d.txt", dir, vim.uv.hrtime())
  if not util.write_private(path, text) then
    return t
  end
  return { path = path, note = t.note }
end

local function warn_unsaved(t)
  -- The agent reads the file on disk, so line numbers from an edited buffer can point at other lines.
  if t.path and t.first and vim.bo.modified then
    if save_on_send then
      vim.cmd("silent update")
    else
      notify(
        "the buffer has unsaved changes, so these line numbers may not match the file. :w first, or set save_on_send = true",
        vim.log.levels.WARN
      )
    end
  end
end

local function ref_of(t)
  return t.path and reference(t) or "the buffer text"
end

-- Put a prepared target into an agent's prompt. Nothing is submitted.
local function dispatch(t)
  t = spill(t)
  local ref = ref_of(t)
  local prompt_ref = t.path and with_note(t, ref) or ref

  pane_targets(function(items)
    if #items == 0 then
      send_direct(t, ref)
      return
    end
    if #items == 1 and pick ~= "always" then
      send_pane(items[1], t, ref)
      return
    end
    M.select(items, {
      prompt = "Add " .. prompt_ref .. " to",
      format_item = function(item)
        return string.format("%-6s %s", item.source, panes.describe(item.agent, item.handle.here))
      end,
    }, function(item)
      if item then
        send_pane(item, t, ref)
      end
    end)
  end)
  return true
end

-- Put a file or selection into an agent's prompt. Nothing is submitted: the
-- reference waits in the prompt until you press Enter there.
-- kind is "file", "selection", "diagnostic", "node", or "quickfix".
-- Agents in Herdr and tmux panes come first. A picker asks which one gets the
-- text (with pick = "auto", only when there are several). With none, it goes to
-- Claude Code, then OpenCode.
function M.send(kind, range)
  local t, err = target(kind, range)
  leave_visual()
  if not t then
    notify(err, vim.log.levels.WARN)
    return false
  end
  warn_unsaved(t)
  return dispatch(t)
end

-- The picker. Tests replace it; vim.ui.select is whatever UI the user has set up.
function M.select(items, opts, on_choice)
  vim.ui.select(items, opts, on_choice)
end

function M.send_file()
  return M.send("file")
end

function M.send_selection(range)
  return M.send("selection", range)
end

-- :TetherSend. With a range it sends those lines, otherwise the file.
function M.mention(range)
  local mode = vim.fn.mode()
  if range or mode == "v" or mode == "V" or mode == "\22" then
    return M.send("selection", range)
  end
  return M.send("file")
end

function M.accept()
  return diff.accept()
end

function M.accept_hunk()
  return diff.accept_hunk()
end

function M.reject()
  return diff.reject()
end

function M.reviews()
  local items = diff.waiting()
  if #items == 0 then
    notify("no review open", vim.log.levels.WARN)
    return false
  end
  if #items == 1 then
    local ok, err = diff.jump(items[1].path)
    if not ok then
      notify(err or "no review open", vim.log.levels.WARN)
    end
    return ok and true or false
  end
  M.select(items, {
    prompt = "Reviews",
    format_item = function(item)
      if item.queued > 0 then
        return string.format("%s  +%d waiting", item.path, item.queued)
      end
      return item.path
    end,
  }, function(item)
    if item then
      local ok, err = diff.jump(item.path)
      if not ok then
        notify(err or "no review open", vim.log.levels.WARN)
      end
    end
  end)
  return true
end

function M.focus()
  if not last_target then
    notify("no agent pane to focus. Send something first", vim.log.levels.WARN)
    return false
  end
  local handle = handles[last_target.source]
  if not handle or not handle.focus then
    notify("cannot focus " .. tostring(last_target.source), vim.log.levels.WARN)
    return false
  end
  handle.focus(last_target.pane_id, function(ok, message)
    if not ok then
      notify("could not focus " .. tostring(last_target.pane_id) .. "\n" .. tostring(message), vim.log.levels.WARN)
    end
  end)
  return true
end

function M.show_log()
  return log.show()
end

function M.send_diagnostic()
  return M.send("diagnostic")
end

function M.send_node()
  return M.send("node")
end

function M.agent_event(payload)
  return activity.event(payload)
end

function M.agent_event_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  pcall(vim.fn.delete, path)
  if not ok or not lines then
    return 0
  end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok then
    activity.event(data)
  end
  return 1
end

function M.revert_hunk()
  local ok, err = activity.revert_hunk()
  if not ok then
    notify(err or "no agent hunk under the cursor", vim.log.levels.WARN)
  end
  return ok and true or false
end

function M.undo_turn()
  local dir, err = activity.undo_turn()
  if not dir then
    notify(err or "no agent turn to undo", vim.log.levels.WARN)
    return false
  end
  notify("restored " .. dir)
  return true
end

function M.install_hooks()
  local path, err = hooks.install()
  if not path then
    notify(err or "could not install Claude hooks", vim.log.levels.WARN)
    return false
  end
  notify("installed Claude hooks in " .. path)
  return true
end

function M.remove_hooks()
  local path, err = hooks.remove()
  if not path then
    notify(err or "could not remove Claude hooks", vim.log.levels.WARN)
    return false
  end
  notify("removed Claude hooks from " .. path)
  return true
end

function M.watch(dir)
  activity.start_watch(dir)
end

function M.spawn(kind)
  local started, err = worktree.spawn(kind, handles, function(record, message)
    if record and record.pane_id then
      notify(string.format("started %s in %s (%s)", record.kind, record.dir, record.pane_id))
    elseif record then
      notify("worktree " .. record.dir .. (message and message ~= "" and ("\n" .. message) or ""))
    end
  end)
  if not started then
    notify(err or "could not create a worktree", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.worktree_clean()
  local items = worktree.list()
  if #items == 0 then
    notify("no tether worktrees", vim.log.levels.WARN)
    return false
  end
  M.select(items, {
    prompt = "Remove worktree",
    format_item = function(item)
      return item.kind .. "  " .. item.dir
    end,
  }, function(item)
    if not item then
      return
    end
    local ok, clean_err = worktree.clean(item.dir)
    if not ok then
      notify(clean_err or "could not remove the worktree", vim.log.levels.WARN)
    else
      notify("removed " .. item.dir)
    end
  end)
  return true
end

function M.statusline()
  return agents.statusline()
end

function M.agents()
  agents.open()
end

function M.dashboard_focus(item)
  focus_pane(item)
end

-- `s` in the dashboard sends the file in the window the list was opened from.
function M.dashboard_send(item)
  local origin = agents.origin()
  local dash = vim.api.nvim_get_current_win()
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  local t, err = target("file")
  if dash and vim.api.nvim_win_is_valid(dash) then
    vim.api.nvim_set_current_win(dash)
  end
  if not t then
    notify(err, vim.log.levels.WARN)
    return false
  end
  warn_unsaved(t)
  t = spill(t)
  send_pane(item, t, ref_of(t))
  return true
end

function M.send_prompt()
  local mode = vim.fn.mode()
  local range
  if mode == "v" or mode == "V" or mode == "\22" then
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    range = { first, last }
    leave_visual()
  end
  vim.ui.input({ prompt = "Instruction: " }, function(text)
    if not text or vim.trim(text) == "" then
      return
    end
    local t, err = range and target("selection", range) or target("file")
    if not t then
      notify(err, vim.log.levels.WARN)
      return
    end
    t.note = text
    warn_unsaved(t)
    dispatch(t)
  end)
  return true
end

function M.send_many(kind, range)
  local t, err = target(kind or "file", range)
  leave_visual()
  if not t then
    notify(err, vim.log.levels.WARN)
    return false
  end
  warn_unsaved(t)
  t = spill(t)
  local ref = ref_of(t)
  pane_targets(function(items)
    if #items == 0 then
      send_direct(t, ref)
      return
    end
    agents.choose(items, function(chosen)
      for _, item in ipairs(chosen) do
        send_pane(item, t, ref)
      end
    end)
  end)
  return true
end

function M.send_diff(how, base)
  local args = { "git", "diff", "--no-color", "--no-ext-diff" }
  local note = "unstaged diff"
  if how == "staged" then
    args[#args + 1] = "--staged"
    note = "staged diff"
  elseif how == "base" then
    if type(base) ~= "string" or base == "" then
      notify("pass a base ref: :TetherSendDiff base main", vim.log.levels.WARN)
      return false
    end
    args[#args + 1] = base
    note = "diff against " .. base
  end
  vim.system(args, { text = true, cwd = vim.fn.getcwd() }, function(out)
    vim.schedule(function()
      if not out or out.code ~= 0 then
        notify("git diff failed\n" .. vim.trim((out and out.stderr) or ""), vim.log.levels.WARN)
        return
      end
      if vim.trim(out.stdout or "") == "" then
        notify("that diff is empty", vim.log.levels.WARN)
        return
      end
      dispatch({ text = out.stdout, note = note })
    end)
  end)
  return true
end

local function terminal_buffer()
  if vim.bo.buftype == "terminal" then
    return vim.api.nvim_get_current_buf()
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      return buf
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      return buf
    end
  end
end

function M.send_terminal(n)
  n = tonumber(n) or 40
  if n < 1 then
    n = 40
  end
  local buf = terminal_buffer()
  if not buf then
    notify("no terminal buffer", vim.log.levels.WARN)
    return false
  end
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- A terminal buffer is a grid, so the rows under the cursor are empty.
  while #all > 0 and all[#all] == "" do
    all[#all] = nil
  end
  local start_at = math.max(1, #all - n + 1)
  local tail = {}
  for i = start_at, #all do
    tail[#tail + 1] = all[i]
  end
  if #tail == 0 then
    notify("the terminal buffer is empty", vim.log.levels.WARN)
    return false
  end
  return dispatch({ text = table.concat(tail, "\n"), note = "terminal" })
end

local function reference_lines(results, encoding)
  local lines = {}
  for _, res in pairs(results or {}) do
    if res.result then
      local ok, located = pcall(vim.lsp.util.locations_to_items, res.result, encoding)
      if ok then
        for _, item in ipairs(located) do
          local text = (item.text or ""):gsub("%s+", " ")
          lines[#lines + 1] = string.format("%s:%d: %s", item.filename or "", item.lnum or 0, text)
        end
      end
    end
  end
  return lines
end

function M.send_references()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    notify("no LSP client for this buffer", vim.log.levels.WARN)
    return false
  end
  local encoding = clients[1].offset_encoding or "utf-16"
  local params = vim.lsp.util.make_position_params(0, encoding)
  local ref_params = vim.tbl_extend("force", vim.deepcopy(params), { context = { includeDeclaration = true } })
  local pending = 2
  local lines = {}
  local function finish_one(results)
    vim.list_extend(lines, reference_lines(results, encoding))
    pending = pending - 1
    if pending > 0 then
      return
    end
    if #lines == 0 then
      notify("no definition or references for the symbol under the cursor", vim.log.levels.WARN)
      return
    end
    dispatch({ text = table.concat(lines, "\n"), note = "definition and references" })
  end
  vim.lsp.buf_request_all(0, "textDocument/definition", params, finish_one)
  vim.lsp.buf_request_all(0, "textDocument/references", ref_params, finish_one)
  return true
end

-- Comments on a rejected review go to the last pane of that agent. With none
-- remembered, the picker asks once. Claude's MCP reply stays DIFF_REJECTED.
on_feedback = function(session, text)
  local agent_name = session.adapter
  local t = { text = text }
  pane_targets(function(items)
    local remembered = agent_name and last_by_agent[agent_name]
    local match
    if remembered then
      for _, item in ipairs(items) do
        if item.source == remembered.source and item.agent.pane_id == remembered.pane_id then
          match = item
          break
        end
      end
    end
    if not match and agent_name then
      for _, item in ipairs(items) do
        if item.agent.agent == agent_name then
          match = item
          break
        end
      end
    end
    if match then
      send_pane(match, t, text)
      return
    end
    if #items == 0 then
      notify("the rejection has comments, and no agent pane can take them", vim.log.levels.WARN)
      return
    end
    M.select(items, {
      prompt = "Send the rejection to",
      format_item = function(item)
        return string.format("%-6s %s", item.source, panes.describe(item.agent, item.handle.here))
      end,
    }, function(item)
      if item then
        send_pane(item, t, text)
      end
    end)
  end)
end

return M
