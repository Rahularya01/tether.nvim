local context = require("tether.context")

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

local panes = require("tether.panes")
local util = require("tether.util")

local running = false
local handles = {}
-- "always" asks which agent gets the text every time. "auto" asks only when there are several.
local pick = "always"
-- { source, pane_id } of the agent picked last. It is listed first next time.
local last_target
local mapped = {}

-- Set to false to skip one, or keymaps = false to skip both.
M.default_keymaps = {
  send_file = "<leader>af",
  send_selection = "<leader>ao",
}
local env_keys = {}
local timer
local group

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
end

function M.is_running()
  return running
end

function M.state()
  return handles
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
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

function M.setup(opts)
  opts = opts or {}
  if running then
    M.stop()
  end
  local enabled = opts.adapters or ALL
  pick = opts.pick or (opts.herdr and opts.herdr.pick) or "always"
  local failures = {}
  for _, name in ipairs(enabled) do
    local factory = adapters[name]
    if not factory then
      failures[#failures + 1] = name .. ": unknown adapter"
    else
      local handle, err = factory.start(opts[name] or {})
      if not handle then
        failures[#failures + 1] = name .. ": " .. tostring(err)
      else
        handles[name] = handle
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
    callback = function()
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

  set_keymaps(opts.keymaps)
  timer = vim.uv.new_timer()
  running = true
  context.observe("focus")
  push()
  return failures
end

function M.status()
  local lines = {}
  if not running then
    lines[1] = "tether.nvim is stopped"
    return lines
  end
  lines[1] = "tether.nvim is attached"
  for _, name in ipairs(ALL) do
    local handle = handles[name]
    if not handle then
      lines[#lines + 1] = "  " .. name .. ": off"
    elseif name == "opencode" or name == "herdr" or name == "tmux" then
      lines[#lines + 1] = "  " .. name .. ": " .. (handle.detail or "not connected")
    elseif name == "codex" then
      local detail = #handle.sockets > 0 and table.concat(handle.sockets, ", ") or "no socket"
      detail = detail .. "  clients=" .. handle.client_count()
      if #handle.errors > 0 then
        detail = detail .. "  (" .. table.concat(handle.errors, "; ") .. ", retrying)"
      end
      lines[#lines + 1] = "  codex: " .. detail
    else
      lines[#lines + 1] = string.format(
        "  %s: 127.0.0.1:%s  clients=%d",
        name,
        tostring(handle.port),
        handle.client_count and handle.client_count() or 0
      )
    end
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

-- What to send: the whole file, or lines first..last of it (1-based).
-- range is { line1, line2 } from a command. Without it, use the live visual
-- selection, or the last one ('< and '>) from normal mode.
local function target(kind, range)
  local snap = context.snapshot()
  if not snap.active then
    return nil, "this buffer is not a file on disk"
  end
  local t = { path = snap.active.path }
  if kind == "file" then
    return t
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
  t.first, t.last = first, last
  t.text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
  return t
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

-- @path#L3-5. Claude Code reads a path with spaces as @"my file.lua#L3-5".
local function reference(t)
  local path = util.relative(t.path, vim.fn.getcwd())
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

-- path or path:3-5, for agents other than Claude.
local function plain(t)
  local path = util.relative(t.path, vim.fn.getcwd())
  if path:find("%s") then
    path = '"' .. path .. '"'
  end
  if t.first then
    return path .. ":" .. lines(t)
  end
  return path
end

-- Claude Code over its IDE connection, then OpenCode. Used when Herdr has no agent.
local function send_direct(t, ref)
  local claude = handles.claude
  if claude and claude.send and claude.client_count and claude.client_count() > 0 then
    -- Claude Code takes 0-based lines here and shows them 1-based.
    claude.send("at_mentioned", {
      filePath = t.path,
      lineStart = t.first and (t.first - 1) or nil,
      lineEnd = t.last and (t.last - 1) or nil,
    })
    notify("added " .. ref .. " to the Claude Code prompt. Press Enter there to send it")
    return true
  end

  local opencode = handles.opencode
  if opencode and opencode.append then
    local text = ref .. " "
    if t.text and t.text ~= "" then
      text = ref .. "\n" .. t.text .. "\n"
    end
    if opencode.append(text) then
      notify("added " .. ref .. " to the OpenCode prompt. Press Enter there to send it")
      return true
    end
  end

  notify(
    "nothing to send to. No agent pane in Herdr or tmux, no Claude Code connection, and no OpenCode server",
    vim.log.levels.WARN
  )
  return false
end

local function send_pane(item, t, ref)
  local agent = item.agent
  local text = agent.agent == "claude" and ref or plain(t)
  last_target = { source = item.source, pane_id = agent.pane_id }
  local where = item.source .. " " .. (agent.label or agent.pane_id)
  item.handle.insert(agent.pane_id, text .. " ", function(ok, message)
    if ok then
      notify(string.format("added %s to %s in %s. Press Enter there to send it", text, agent.agent, where))
    else
      notify(
        string.format("%s in %s did not take %s\n%s", agent.agent, where, text, tostring(message)),
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

-- Put a file or selection into an agent's prompt. Nothing is submitted: the
-- reference waits in the prompt until you press Enter there.
-- kind is "file" or "selection".
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
  local ref = reference(t)

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
      prompt = "Add " .. ref .. " to",
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
  return require("tether.diff").accept()
end

function M.reject()
  return require("tether.diff").reject()
end

return M
