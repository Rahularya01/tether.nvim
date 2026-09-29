local events = require("tether.events")
local log = require("tether.log")
local util = require("tether.util")

local M = {}

local sessions = {}
-- path -> list of { content, on_done, opts }. Shown after the open review of that file finishes.
local queued = {}

local default_keymaps = { accept = "ga", reject = "gr", hunk = "gh", comment = "gc" }
local keymaps = {
  accept = default_keymaps.accept,
  reject = default_keymaps.reject,
  hunk = default_keymaps.hunk,
  comment = default_keymaps.comment,
}
local comment_ns = vim.api.nvim_create_namespace("tether-review-comments")

-- Set by init.lua. Called with the session and a prompt line when a rejection
-- has comments. Claude's openDiff reply stays a fixed string, so the comments
-- travel through the prompt instead.
M.on_feedback = nil

function M.configure(opts)
  if opts == false then
    keymaps = false
    return
  end
  if opts == nil then
    keymaps = {
      accept = default_keymaps.accept,
      reject = default_keymaps.reject,
      hunk = default_keymaps.hunk,
      comment = default_keymaps.comment,
    }
    return
  end
  keymaps = vim.tbl_extend("force", default_keymaps, opts)
end

local function emit(action, path)
  log.record("review", action .. " " .. path)
  events.emit("TetherReview", { action = action, path = path })
end

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

local function buf_text(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[buf].endofline then
    text = text .. "\n"
  end
  return text
end

local function session_text(session)
  return buf_text(session.proposed)
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

local function promote(path)
  local queue = queued[path]
  if not queue or #queue == 0 then
    queued[path] = nil
    return
  end
  local next_review = table.remove(queue, 1)
  if #queue == 0 then
    queued[path] = nil
  end
  vim.schedule(function()
    local opened, err = M.open(path, next_review.content, next_review.on_done, next_review.opts)
    if not opened then
      next_review.on_done(false, "")
      vim.notify("tether: could not open the next review of " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function comment_summary(session)
  local parts = {}
  for _, comment in ipairs(session.comments or {}) do
    parts[#parts + 1] = string.format("L%d: %s", comment.line, comment.text)
  end
  return table.concat(parts, "; ")
end

local function finish(session, accepted, content)
  if session.done then
    return
  end
  session.done = true
  local path = session.path
  local summary = (not accepted) and comment_summary(session) or ""
  forget(session)
  teardown(session)
  session.on_done(accepted, content or "")
  emit(accepted and "accept" or "reject", path)
  if summary ~= "" and M.on_feedback then
    pcall(M.on_feedback, session, string.format("I rejected the change to %s: %s", path, summary))
  end
  promote(path)
end

local function review_hint()
  if keymaps == false then
    return ":TetherAccept  :TetherAcceptHunk  :TetherReject"
  end
  local accept = (keymaps.accept and keymaps.accept ~= "") and keymaps.accept or ":TetherAccept"
  local hunk = (keymaps.hunk and keymaps.hunk ~= "") and keymaps.hunk or ":TetherAcceptHunk"
  local reject = (keymaps.reject and keymaps.reject ~= "") and keymaps.reject or ":TetherReject"
  local hint = accept .. " accept   " .. hunk .. " hunk   " .. reject .. " reject"
  if keymaps.comment and keymaps.comment ~= "" then
    hint = hint .. "   " .. keymaps.comment .. " comment"
  end
  return hint
end

local function bind_review(session)
  if keymaps == false then
    return
  end
  local function bind(lhs, fn, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = session.proposed, silent = true, desc = desc })
  end
  bind(keymaps.accept, function()
    local ok, err = M.accept(session.path)
    if not ok then
      vim.notify("tether: " .. (err or "no diff to accept"), vim.log.levels.WARN)
    end
  end, "Tether: accept review")
  bind(keymaps.reject, function()
    local ok, err = M.reject(session.path)
    if not ok then
      vim.notify("tether: " .. (err or "no diff to reject"), vim.log.levels.WARN)
    end
  end, "Tether: reject review")
  bind(keymaps.hunk, function()
    local ok, err = M.accept_hunk(session.path)
    if not ok then
      vim.notify("tether: " .. (err or "no hunk to accept"), vim.log.levels.WARN)
    end
  end, "Tether: accept the hunk under the cursor")
  if keymaps.comment and keymaps.comment ~= "" then
    vim.keymap.set({ "n", "x" }, keymaps.comment, function()
      local ok, err = M.comment(session.path)
      if not ok then
        vim.notify("tether: " .. (err or "no diff to comment on"), vim.log.levels.WARN)
      end
    end, { buffer = session.proposed, silent = true, desc = "Tether: comment on this proposal" })
  end
end

-- opts.label names the review so a harness can close it later (Claude's tab_name).
function M.open(path, new_content, on_done, opts)
  opts = opts or {}
  path = util.abspath(path)
  if not path then
    return nil, "filePath is required"
  end
  if sessions[path] then
    queued[path] = queued[path] or {}
    queued[path][#queued[path] + 1] = { content = new_content, on_done = on_done, opts = opts }
    vim.notify(
      "tether: a review of " .. path .. " is already open. This one opens when that review finishes.",
      vim.log.levels.INFO
    )
    return true
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
      adapter = opts.adapter,
      comments = {},
    }
    sessions[path] = session
    bind_review(session)
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
    { "Review " .. path .. "  " .. review_hint(), "ModeMsg" },
  }, false, {})
  emit("open", path)
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

-- Open reviews, plus how many more are waiting behind each file.
function M.waiting()
  local items = {}
  local seen = {}
  for path in pairs(sessions) do
    seen[path] = true
    items[#items + 1] = { path = path, queued = queued[path] and #queued[path] or 0 }
  end
  for path, queue in pairs(queued) do
    if not seen[path] and #queue > 0 then
      items[#items + 1] = { path = path, queued = #queue }
    end
  end
  table.sort(items, function(a, b)
    return a.path < b.path
  end)
  return items
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
  local reported
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
    -- Format-on-save may have changed the buffer during :write. Report that text.
    reported = buf_text(buf)
  end)
  if not ok then
    vim.notify("tether: could not write " .. session.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return nil, tostring(err)
  end
  finish(session, true, reported)
  return true
end

-- vim.diff indices are 1-based. A count of 0 means `start` is the line just
-- before an insertion or deletion (and may be 0 at the top of the file).
local function buffer_hunks(original, proposed)
  local before = table.concat(vim.api.nvim_buf_get_lines(original, 0, -1, false), "\n")
  local after = table.concat(vim.api.nvim_buf_get_lines(proposed, 0, -1, false), "\n")
  local ok, hunks = pcall(vim.diff, before, after, { result_type = "indices", algorithm = "histogram" })
  if not ok or type(hunks) ~= "table" then
    return {}
  end
  return hunks
end

local function hunk_at(hunks, line, from_proposed)
  local loose
  for _, hunk in ipairs(hunks) do
    local start = from_proposed and hunk[3] or hunk[1]
    local count = from_proposed and hunk[4] or hunk[2]
    if count > 0 and line >= start and line <= start + count - 1 then
      return hunk
    end
    if count == 0 and (line == start or line == start + 1) then
      loose = loose or hunk
    end
  end
  return loose
end

local function apply_hunk(session, hunk)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  local new_lines = {}
  if count_b > 0 then
    new_lines = vim.api.nvim_buf_get_lines(session.proposed, start_b - 1, start_b - 1 + count_b, false)
  end
  local from, to
  if count_a == 0 then
    from, to = start_a, start_a
  else
    from = start_a - 1
    to = start_a - 1 + count_a
  end
  vim.api.nvim_buf_set_lines(session.original, from, to, false, new_lines)
end

local function write_original(session)
  local buf = session.original
  local fix = vim.bo[buf].fixendofline
  vim.bo[buf].fixendofline = false
  local wrote, werr = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("write")
  end)
  vim.bo[buf].fixendofline = fix
  if not wrote then
    error(werr, 0)
  end
  return buf_text(buf)
end

-- Write the hunk under the cursor and leave the rest of the review open.
-- When that was the last difference, the review finishes as an accept.
function M.accept_hunk(path)
  local session = find(path)
  if not session then
    return nil, "no diff to accept"
  end
  local original_valid = vim.api.nvim_buf_is_valid(session.original) and vim.bo[session.original].buftype == ""
  if original_valid and vim.bo[session.original].modified then
    return nil,
      session.path
        .. " has unsaved changes that accepting would overwrite. Write or undo them, then :TetherAcceptHunk, or :TetherReject."
  end
  local cur = vim.api.nvim_get_current_buf()
  local from_proposed = cur == session.proposed
  if cur ~= session.proposed and cur ~= session.original then
    from_proposed = true
  end
  local hunks = buffer_hunks(session.original, session.proposed)
  local hunk = hunk_at(hunks, vim.api.nvim_win_get_cursor(0)[1], from_proposed)
  if not hunk then
    return nil, "no hunk under the cursor"
  end
  local reported
  local ok, err = pcall(function()
    apply_hunk(session, hunk)
    reported = write_original(session)
  end)
  if not ok then
    vim.notify("tether: could not write " .. session.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return nil, tostring(err)
  end
  pcall(vim.cmd, "diffupdate")
  local left = buffer_hunks(session.original, session.proposed)
  if #left == 0 then
    finish(session, true, reported)
    return true
  end
  emit("hunk", session.path)
  vim.api.nvim_echo({
    { "Accepted a hunk of " .. session.path .. "  " .. #left .. " still open", "ModeMsg" },
  }, false, {})
  return true
end

function M.add_comment(path, line, text)
  local session = find(path)
  if not session then
    return nil, "no diff to comment on"
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil, "empty comment"
  end
  line = tonumber(line) or 1
  session.comments = session.comments or {}
  session.comments[#session.comments + 1] = { line = line, text = text }
  if vim.api.nvim_buf_is_valid(session.proposed) then
    pcall(vim.api.nvim_buf_set_extmark, session.proposed, comment_ns, math.max(0, line - 1), 0, {
      virt_text = { { " " .. text, "Comment" } },
      virt_text_pos = "eol",
    })
  end
  return true
end

function M.comment(path)
  local session = find(path)
  if not session then
    return nil, "no diff to comment on"
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.ui.input({ prompt = "Comment: " }, function(text)
    if text then
      M.add_comment(session.path, line, text)
    end
  end)
  return true
end

function M.jump(path)
  path = util.abspath(path)
  local session = path and sessions[path] or nil
  if not session or not vim.api.nvim_tabpage_is_valid(session.tab) then
    return nil, "no open review"
  end
  vim.api.nvim_set_current_tabpage(session.tab)
  if vim.api.nvim_win_is_valid(session.proposed_win) then
    vim.api.nvim_set_current_win(session.proposed_win)
  end
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
  promote(path)
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
  for path, queue in pairs(queued) do
    for i, item in ipairs(queue) do
      if item.opts and item.opts.label == label then
        table.remove(queue, i)
        if #queue == 0 then
          queued[path] = nil
        end
        item.on_done(false, "")
        return true
      end
    end
  end
  return false
end

function M.reject_all()
  local count = 0
  for path, queue in pairs(queued) do
    queued[path] = nil
    for _, item in ipairs(queue) do
      count = count + 1
      item.on_done(false, "")
    end
  end
  local paths = {}
  for path in pairs(sessions) do
    paths[#paths + 1] = path
  end
  for _, path in ipairs(paths) do
    if M.reject(path) then
      count = count + 1
    end
  end
  return count
end

return M
