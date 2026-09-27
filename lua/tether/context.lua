local util = require("tether.util")

local M = {}

local severity_name = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warning",
  [vim.diagnostic.severity.INFO] = "Information",
  [vim.diagnostic.severity.HINT] = "Hint",
}

-- path -> { seq = focus order, ms = wall clock in ms }. seq orders files; ms is what Gemini is sent.
local focus_at = {}
local focus_seq = 0
local latest_selection = nil
-- bufnr -> { name, path }. abspath calls realpath, which is too slow to run on every cursor move.
local path_cache = {}

local function now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cached = path_cache[bufnr]
  if cached and cached.name == name then
    return cached.path
  end
  local path = util.abspath(name)
  path_cache[bufnr] = { name = name, path = path }
  return path
end

local function empty_selection(pos)
  return {
    start = pos,
    ["end"] = pos,
    is_empty = true,
    text = "",
  }
end

local function column_at(bufnr, lnum, byte_col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if byte_col < 0 then
    byte_col = 0
  end
  if byte_col > #line then
    byte_col = #line
  end
  return {
    line = lnum - 1,
    character = util.utf16_len(line:sub(1, byte_col)),
    byte = byte_col,
  }
end

local function ordered_range(bufnr, a_lnum, a_col, b_lnum, b_col)
  if a_lnum > b_lnum or (a_lnum == b_lnum and a_col > b_col) then
    a_lnum, a_col, b_lnum, b_col = b_lnum, b_col, a_lnum, a_col
  end
  local start = column_at(bufnr, a_lnum, a_col)
  local stop = column_at(bufnr, b_lnum, b_col)
  return start, stop
end

local function selection_text(bufnr, start, stop)
  local ok, lines = pcall(vim.api.nvim_buf_get_text, bufnr, start.line, start.byte, stop.line, stop.byte, {})
  if not ok then
    return ""
  end
  local text = table.concat(lines, "\n")
  if #text > 16384 then
    text = text:sub(1, 16384)
  end
  return text
end

local function public_pos(pos)
  return { line = pos.line, character = pos.character }
end

local function read_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  if not visual then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local pos = column_at(bufnr, cursor[1], cursor[2])
    return {
      bufnr = bufnr,
      path = buf_path(bufnr),
      selection = empty_selection(public_pos(pos)),
    }
  end

  local anchor = vim.fn.getpos("v")
  local head = vim.fn.getpos(".")
  local a_lnum, a_col = anchor[2], anchor[3] - 1
  local b_lnum, b_col = head[2], head[3] - 1
  if mode == "V" then
    a_col = 0
    local line = vim.api.nvim_buf_get_lines(bufnr, b_lnum - 1, b_lnum, false)[1] or ""
    b_col = #line
  end
  local start, stop = ordered_range(bufnr, a_lnum, a_col, b_lnum, b_col)
  if mode == "v" or mode == "\22" then
    -- getpos columns are inclusive; nvim_buf_get_text's end column is exclusive.
    local end_line = vim.api.nvim_buf_get_lines(bufnr, stop.line, stop.line + 1, false)[1] or ""
    local byte = math.min(#end_line, stop.byte + 1)
    stop = column_at(bufnr, stop.line + 1, byte)
  end
  local selection = {
    start = public_pos(start),
    ["end"] = public_pos(stop),
    is_empty = start.line == stop.line and start.byte == stop.byte,
    text = selection_text(bufnr, start, stop),
  }
  return {
    bufnr = bufnr,
    path = buf_path(bufnr),
    selection = selection,
  }
end

function M.folders()
  local seen, list = {}, {}
  local function add(path)
    path = util.abspath(path)
    if not path or seen[path] then
      return
    end
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type ~= "directory" then
      path = vim.fs.dirname(path)
    end
    if not path or seen[path] then
      return
    end
    seen[path] = true
    list[#list + 1] = { name = util.basename(path), path = path }
  end

  for tab = 1, vim.fn.tabpagenr("$") do
    local ok, cwd = pcall(vim.fn.getcwd, -1, tab)
    if ok then
      add(cwd)
    end
  end

  local getter = vim.lsp.get_clients or vim.lsp.get_active_clients
  if getter then
    local ok, clients = pcall(getter, {})
    if ok and type(clients) == "table" then
      for _, client in ipairs(clients) do
        for _, folder in ipairs(client.workspace_folders or {}) do
          if folder.uri then
            add(vim.uri_to_fname(folder.uri))
          end
        end
      end
    end
  end

  if #list == 0 then
    add(vim.uv.cwd())
  end
  return list
end

local function file_buffers()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = buf_path(bufnr)
      if path then
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == "file" then
          buffers[#buffers + 1] = bufnr
        end
      end
    end
  end
  return buffers
end

local function buffer_info(bufnr, active)
  local path = buf_path(bufnr)
  return {
    bufnr = bufnr,
    path = path,
    name = util.basename(path),
    language = vim.bo[bufnr].filetype,
    dirty = vim.bo[bufnr].modified,
    active = active or false,
  }
end

function M.observe(kind)
  local ok, reading = pcall(read_selection)
  if ok and reading then
    if not reading.selection.is_empty then
      latest_selection = reading
    end
    if kind == "focus" then
      focus_seq = focus_seq + 1
      focus_at[reading.path] = { seq = focus_seq, ms = now_ms() }
    end
  end
end

function M.latest()
  return latest_selection
end

function M.snapshot()
  local current = read_selection()
  local active_buf = current and current.bufnr or vim.api.nvim_get_current_buf()
  local editors = {}
  local open = {}
  for _, bufnr in ipairs(file_buffers()) do
    local editor = buffer_info(bufnr, bufnr == active_buf)
    editors[#editors + 1] = editor
    open[editor.path] = true
    if not focus_at[editor.path] then
      focus_at[editor.path] = { seq = 0, ms = now_ms() }
    end
  end
  -- Forget buffers that are gone so these tables stay the size of the buffer list.
  for path in pairs(focus_at) do
    if not open[path] then
      focus_at[path] = nil
    end
  end
  for bufnr in pairs(path_cache) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      path_cache[bufnr] = nil
    end
  end
  local active
  for _, editor in ipairs(editors) do
    if editor.active then
      active = editor
      break
    end
  end
  return {
    folders = M.folders(),
    active = active,
    editors = editors,
    selection = current and current.selection or nil,
    latest = latest_selection,
    focus_at = focus_at,
  }
end

-- diagnostic.col is a byte index. Agents expect a UTF-16 column, same as selections.
local function utf16_col(bufnr, lnum, byte_col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
  if byte_col < 0 then
    byte_col = 0
  end
  if byte_col > #line then
    byte_col = #line
  end
  return util.utf16_len(line:sub(1, byte_col))
end

function M.diagnostics(path)
  path = path and util.abspath(path) or nil
  local grouped = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local file = buf_path(bufnr)
    if file then
      if not path or file == path then
        local items = {}
        for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
          local finish_line = diagnostic.end_lnum or diagnostic.lnum
          local finish_col = diagnostic.end_col or (diagnostic.col + 1)
          items[#items + 1] = {
            message = diagnostic.message,
            severity = severity_name[diagnostic.severity] or "Error",
            source = diagnostic.source or "neovim",
            code = diagnostic.code,
            range = {
              start = { line = diagnostic.lnum, character = utf16_col(bufnr, diagnostic.lnum, diagnostic.col) },
              ["end"] = { line = finish_line, character = utf16_col(bufnr, finish_line, finish_col) },
            },
          }
        end
        if path or #items > 0 then
          grouped[#grouped + 1] = {
            uri = util.file_url(file),
            diagnostics = items,
          }
        end
      end
    end
  end
  return grouped
end

local function descriptor(path, root, dirty)
  return {
    label = util.basename(path),
    path = root and util.relative(path, root) or path,
    fsPath = path,
    isDirty = dirty and true or false,
  }
end

local function codex_selection(selection)
  local start = selection.start
  local stop = selection["end"]
  local range = {
    start = { line = start.line, character = start.character },
    ["end"] = { line = stop.line, character = stop.character },
  }
  local selections = selection.is_empty and {} or { range }
  return range, selections, selection.text or ""
end

function M.codex(root)
  root = root and util.abspath(root) or nil
  local snap = M.snapshot()
  local editors = {}
  local seen = {}
  for _, editor in ipairs(snap.editors) do
    if (not root or util.under(editor.path, root)) and not seen[editor.path] then
      seen[editor.path] = true
      editors[#editors + 1] = editor
    end
  end
  -- Most recently focused first, so the 20-tab cap keeps the files in use.
  table.sort(editors, function(a, b)
    local a_focus = snap.focus_at[a.path]
    local b_focus = snap.focus_at[b.path]
    local a_seq = a_focus and a_focus.seq or 0
    local b_seq = b_focus and b_focus.seq or 0
    if a_seq ~= b_seq then
      return a_seq > b_seq
    end
    return a.path < b.path
  end)
  local tabs = {}
  for i = 1, math.min(20, #editors) do
    local editor = editors[i]
    tabs[#tabs + 1] = descriptor(editor.path, root, editor.dirty)
  end

  local ide = { openTabs = tabs }
  local active = snap.active
  local selection = snap.selection
  if active and (not root or util.under(active.path, root)) and selection then
    local range, selections, text = codex_selection(selection)
    local file = descriptor(active.path, root, active.dirty)
    file.selection = range
    file.activeSelectionContent = text
    file.selections = selections
    ide.activeFile = file
  end
  return ide
end

-- opts.trusted: nil leaves workspace trust to Gemini CLI; true or false overrides it.
function M.gemini(snap, opts)
  snap = snap or M.snapshot()
  opts = opts or {}
  local files = {}
  local order = {}
  for _, editor in ipairs(snap.editors) do
    local focus = snap.focus_at[editor.path] or { seq = 0, ms = now_ms() }
    local item = {
      path = editor.path,
      timestamp = focus.ms,
      isDirty = editor.dirty and true or false,
    }
    order[item] = focus.seq
    if editor.active then
      item.isActive = true
      local selection = snap.selection
      if selection then
        item.cursor = {
          line = selection.start.line + 1,
          character = selection.start.character + 1,
        }
        if not selection.is_empty and selection.text ~= "" then
          item.selectedText = selection.text
        end
      end
    end
    files[#files + 1] = item
  end
  table.sort(files, function(a, b)
    if order[a] ~= order[b] then
      return order[a] > order[b]
    end
    return a.timestamp > b.timestamp
  end)
  while #files > 10 do
    table.remove(files)
  end
  local state = { openFiles = files }
  if opts.trusted ~= nil then
    state.isTrusted = opts.trusted and true or false
  end
  return { workspaceState = state }
end

-- The diagnostic on the cursor line, preferring one whose range contains the cursor.
function M.cursor_diagnostic()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local col = cursor[2]
  local items = vim.diagnostic.get(0, { lnum = line })
  if #items == 0 then
    return nil
  end
  for _, item in ipairs(items) do
    local start_col = item.col or 0
    local end_line = item.end_lnum or item.lnum
    local end_col = item.end_col or (start_col + 1)
    local after_start = line > item.lnum or col >= start_col
    local before_end = line < end_line or col < end_col
    if after_start and before_end then
      return item
    end
  end
  return items[1]
end

local function interesting_node(type_name)
  return type_name:find("function", 1, true)
    or type_name:find("method", 1, true)
    or type_name:find("class", 1, true)
    or type_name:find("struct", 1, true)
    or type_name:find("enum", 1, true)
    or type_name:find("interface", 1, true)
    or type_name:find("impl_item", 1, true)
    or type_name:find("namespace", 1, true)
    or type_name:find("module", 1, true)
end

-- Innermost function, method, class, or similar node around the cursor.
-- Returns the node, or nil and a reason.
function M.enclosing_node()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil, "no syntax tree for this buffer"
  end
  if not pcall(function()
    parser:parse()
  end) then
    return nil, "no syntax tree for this buffer"
  end
  local node = vim.treesitter.get_node({ bufnr = bufnr })
  if not node then
    return nil, "no syntax tree for this buffer"
  end
  local current = node
  while current do
    if interesting_node(current:type()) then
      return current
    end
    current = current:parent()
  end
  return nil, "cursor is not inside a function or type"
end

function M._reset()
  path_cache = {}
  focus_at = {}
  focus_seq = 0
  latest_selection = nil
end

return M
