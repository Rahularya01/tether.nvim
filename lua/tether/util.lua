local M = {}

function M.token(nbytes)
  nbytes = nbytes or 16
  local f, err = io.open("/dev/urandom", "rb")
  if not f then
    error("tether: cannot read /dev/urandom: " .. tostring(err))
  end
  local data = f:read(nbytes)
  f:close()
  if not data or #data ~= nbytes then
    error("tether: short read from /dev/urandom")
  end
  return (data:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

function M.mkdir(path, mode)
  mode = mode or 448 -- 0700
  vim.fn.mkdir(path, "p", mode)
  pcall(vim.uv.fs_chmod, path, mode)
end

function M.write_private(path, contents, mode)
  mode = mode or 384 -- 0600
  local tmp = path .. ".tmp-" .. tostring(vim.uv.hrtime())
  local fd, err = vim.uv.fs_open(tmp, "w", mode)
  if not fd then
    return nil, err
  end
  local ok, werr = vim.uv.fs_write(fd, contents)
  vim.uv.fs_close(fd)
  if not ok then
    vim.uv.fs_unlink(tmp)
    return nil, werr
  end
  pcall(vim.uv.fs_chmod, tmp, mode)
  local renamed, rerr = vim.uv.fs_rename(tmp, path)
  if not renamed then
    vim.uv.fs_unlink(tmp)
    return nil, rerr
  end
  pcall(vim.uv.fs_chmod, path, mode)
  return true
end

function M.pid_alive(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  if not ok then
    return false
  end
  return result == 0 or result == true
end

function M.abspath(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 7) == "file://" then
    path = vim.uri_to_fname(path)
  end
  path = vim.fs.normalize(vim.fs.abspath(path))
  local real = vim.uv.fs_realpath(path)
  if real then
    return vim.fs.normalize(real)
  end
  -- Keep unsaved paths in the same namespace as their parent. On macOS /tmp
  -- is /private/tmp, and harnesses compare the two as prefixes.
  local parent = vim.fs.dirname(path)
  local real_parent = parent and vim.uv.fs_realpath(parent)
  if real_parent then
    return vim.fs.normalize(real_parent .. "/" .. vim.fs.basename(path))
  end
  return path
end

function M.relative(path, root)
  local file = M.abspath(path)
  local base = root and M.abspath(root) or nil
  if not file or not base then
    return file
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  if file:sub(1, #base) == base then
    return file:sub(#base + 1)
  end
  return file
end

function M.under(path, root)
  local file = M.abspath(path)
  local base = root and M.abspath(root) or nil
  if not file or not base then
    return false
  end
  if file == base then
    return true
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return file:sub(1, #base) == base
end

function M.file_url(path)
  return vim.uri_from_fname(M.abspath(path))
end

function M.basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

-- UTF-16 code units, which is what VS Code selection columns use.
function M.utf16_len(s)
  local n, i = 0, 1
  while i <= #s do
    local c = s:byte(i)
    if not c then
      break
    elseif c < 0x80 then
      n, i = n + 1, i + 1
    elseif c < 0xE0 then
      n, i = n + 1, i + 2
    elseif c < 0xF0 then
      n, i = n + 1, i + 3
    else
      n, i = n + 2, i + 4
    end
  end
  return n
end

function M.obj(t)
  if t == nil or next(t) == nil then
    return vim.empty_dict()
  end
  return t
end

function M.json(value)
  return vim.json.encode(value)
end

function M.log(enabled, msg)
  if not enabled then
    return
  end
  vim.schedule(function()
    vim.notify("tether: " .. msg, vim.log.levels.DEBUG)
  end)
end

return M
