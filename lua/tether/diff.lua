local util = require("tether.util")

local M = {}

local sessions = {}

local function split_lines(content)
  content = content or ""
  local eol = content:sub(-1) == "\n"
  local lines = vim.split(content, "\n", { plain = true })
  if eol then
    lines[#lines] = nil
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines, eol
end

local function session_text(session)
  local lines = vim.api.nvim_buf_get_lines(session.proposed, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[session.proposed].endofline then
    text = text .. "\n"
  end
  return text
end

local function forget(session)
  if sessions[session.path] == session then
    sessions[session.path] = nil
  end
end

local function teardown(session)
  forget(session)
  if not vim.api.nvim_tabpage_is_valid(session.tab) then
    return
  end
  pcall(vim.api.nvim_set_current_tabpage, session.tab)
  if vim.fn.tabpagenr("$") > 1 and vim.api.nvim_get_current_tabpage() == session.tab then
    pcall(vim.cmd.tabclose)
  else
    if vim.api.nvim_win_is_valid(session.proposed_win) then
      pcall(vim.api.nvim_win_close, session.proposed_win, true)
    end
    if vim.api.nvim_win_is_valid(session.original_win) then
      pcall(vim.api.nvim_win_call, session.original_win, vim.cmd.diffoff)
    end
  end
end

local function finish(session, accepted, content)
  if session.done then
    return
  end
  session.done = true
  forget(session)
  teardown(session)
  session.on_done(accepted, content or "")
end

-- opts.label names the review so a harness can close it later (Claude's tab_name).
function M.open(path, new_content, on_done, opts)
  opts = opts or {}
  path = util.abspath(path)
  if not path then
    return nil, "filePath is required"
  end
  if sessions[path] then
    finish(sessions[path], false, "")
  end

  local lines, eol = split_lines(new_content)
  local ok, err = pcall(function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local original = vim.api.nvim_get_current_buf()
    local original_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local proposed = vim.api.nvim_create_buf(false, true)
    local proposed_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(proposed_win, proposed)
    vim.api.nvim_buf_set_lines(proposed, 0, -1, false, lines)
    local label = "tether-diff://" .. path
    pcall(vim.api.nvim_buf_set_name, proposed, label)
    vim.bo[proposed].buftype = "nofile"
    vim.bo[proposed].bufhidden = "wipe"
    vim.bo[proposed].swapfile = false
    vim.bo[proposed].modifiable = true
    vim.bo[proposed].filetype = vim.bo[original].filetype
    vim.bo[proposed].endofline = eol
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(original_win)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(proposed_win)
    local session = {
      path = path,
      label = opts.label,
      tab = tab,
      original = original,
      original_win = original_win,
      proposed = proposed,
      proposed_win = proposed_win,
      eol = eol,
      on_done = on_done,
    }
    sessions[path] = session
    -- Closing the review any other way (:q, :tabclose, :bwipeout) counts as a rejection,
    -- so the harness is never left waiting on a diff that is gone.
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = proposed,
      once = true,
      callback = function()
        vim.schedule(function()
          finish(session, false, "")
        end)
      end,
    })
  end)
  if not ok then
    return nil, tostring(err)
  end
  vim.api.nvim_echo({
    { "Review " .. path .. "  :TetherAccept  :TetherReject", "ModeMsg" },
  }, false, {})
  return true
end

local function find(path)
  if path then
    path = util.abspath(path)
    return sessions[path]
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, session in pairs(sessions) do
    if session.tab == tab then
      return session
    end
  end
  local only
  for _, session in pairs(sessions) do
    if only then
      return nil
    end
    only = session
  end
  return only
end

function M.current(path)
  return find(path)
end

function M.accept(path)
  local session = find(path)
  if not session then
    return nil, "no diff to accept"
  end
  local original_valid = vim.api.nvim_buf_is_valid(session.original) and vim.bo[session.original].buftype == ""
  if original_valid and vim.bo[session.original].modified then
    return nil,
      session.path
        .. " has unsaved changes that accepting would overwrite. Write or undo them, then :TetherAccept, or :TetherReject."
  end
  local text = session_text(session)
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(session.path, ":h"), "p")
    if not original_valid then
      vim.cmd("edit " .. vim.fn.fnameescape(session.path))
      session.original = vim.api.nvim_get_current_buf()
    end
    local buf = session.original
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].endofline = text:sub(-1) == "\n"
    -- Write the proposal byte for byte, then give the user back their own setting.
    local fix = vim.bo[buf].fixendofline
    vim.bo[buf].fixendofline = false
    local wrote, werr = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("write")
    end)
    vim.bo[buf].fixendofline = fix
    if not wrote then
      error(werr, 0)
    end
  end)
  if not ok then
    vim.notify("tether: could not write " .. session.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return nil, tostring(err)
  end
  finish(session, true, text)
  return true
end

function M.reject(path)
  local session = find(path)
  if not session then
    return nil, "no diff to reject"
  end
  finish(session, false, session_text(session))
  return true
end

function M.close(path)
  path = util.abspath(path)
  local session = path and sessions[path] or nil
  if not session then
    local f = path and io.open(path, "rb") or nil
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return text
  end
  local text = session_text(session)
  session.done = true
  teardown(session)
  return text
end

function M.reject_label(label)
  if type(label) ~= "string" or label == "" then
    return false
  end
  for path, session in pairs(sessions) do
    if session.label == label then
      return M.reject(path) == true
    end
  end
  return false
end

function M.reject_all()
  local paths = {}
  for path in pairs(sessions) do
    paths[#paths + 1] = path
  end
  for _, path in ipairs(paths) do
    M.reject(path)
  end
  return #paths
end

return M
