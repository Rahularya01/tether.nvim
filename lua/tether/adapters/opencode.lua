local util = require("tether.util")

local M = {}

local function state_dir(opts)
  if opts.dir and opts.dir ~= "" then
    return opts.dir
  end
  local home = vim.uv.os_homedir() or os.getenv("HOME") or ""
  local xdg = os.getenv("XDG_STATE_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/opencode"
  end
  return home .. "/.local/state/opencode"
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local decoded_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(data) == "table" then
    return data
  end
end

local function registration(dir)
  for _, name in ipairs({ "server.json", "service.json" }) do
    local data = read_json(dir .. "/" .. name)
    if data and type(data.url) == "string" and data.url ~= "" then
      return data
    end
  end
end

local function password_for(dir, data, opts)
  if opts.password and opts.password ~= "" then
    return opts.password
  end
  if type(data.password) == "string" and data.password ~= "" then
    return data.password
  end
  local ok, lines = pcall(vim.fn.readfile, dir .. "/password")
  if ok and lines and lines[1] and lines[1] ~= "" then
    return lines[1]
  end
end

local function request(url, username, password, method, body, callback)
  local cmd = {
    "curl",
    "-sS",
    "--max-time",
    "2",
    "-X",
    method or "GET",
    "-H",
    "Accept: application/json",
  }
  if password and password ~= "" then
    table.insert(cmd, "--user")
    table.insert(cmd, (username or "opencode") .. ":" .. password)
  end
  if body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, body)
  end
  table.insert(cmd, url)
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      callback(out or {})
    end)
  end)
end

function M.start(opts)
  opts = opts or {}
  local dir = state_dir(opts)
  local username = opts.username or "opencode"
  local handle = {
    dir = dir,
    connected = false,
    detail = "no running server",
    env = {},
  }
  local scanning = false

  local function set_detail(text, connected)
    handle.detail = text
    handle.connected = connected and true or false
  end

  local function apply(info, secret)
    local base = info.url:gsub("/$", "")
    local function finish()
      scanning = false
    end
    request(base .. "/global/health", username, secret, "GET", nil, function(out)
      local ok, body = pcall(vim.json.decode, out.stdout or "")
      if out.code == 0 and ok and type(body) == "table" and (body.healthy == true or body.version) then
        handle.url = base
        handle.password = secret
        handle.version = body.version
        handle.pid = info.pid
        set_detail(base .. (body.version and ("  v" .. body.version) or ""), true)
        finish()
        return
      end
      request(base .. "/api/info", username, secret, "GET", nil, function(legacy)
        local legacy_ok, info_body = pcall(vim.json.decode, legacy.stdout or "")
        if legacy.code == 0 and legacy_ok and type(info_body) == "table" and info_body.version then
          handle.url = base
          handle.password = secret
          handle.version = info_body.version
          handle.pid = info.pid
          set_detail(base .. "  v" .. info_body.version, true)
        else
          handle.url = nil
          set_detail("server at " .. base .. " did not answer", false)
        end
        finish()
      end)
    end)
  end

  local function scan()
    if scanning then
      return
    end
    if opts.url and opts.url ~= "" then
      scanning = true
      apply({ url = opts.url, pid = vim.fn.getpid() }, opts.password)
      return
    end
    local info = registration(dir)
    if not info then
      handle.url = nil
      set_detail("no running server", false)
      return
    end
    if info.pid and not util.pid_alive(info.pid) then
      handle.url = nil
      set_detail("no running server", false)
      return
    end
    scanning = true
    apply(info, password_for(dir, info, opts))
  end

  handle.scan = scan
  handle.append = function(text)
    if not handle.connected or not handle.url then
      return nil, "no running OpenCode server"
    end
    local directory = vim.uri_encode(vim.fn.getcwd())
    local url = handle.url .. "/tui/append-prompt?directory=" .. directory
    request(url, username, handle.password, "POST", vim.json.encode({ text = text }), function(out)
      if out.code ~= 0 then
        vim.notify("tether: OpenCode did not accept editor context", vim.log.levels.WARN)
      end
    end)
    return true
  end
  handle.stop = function()
    if handle.timer then
      handle.timer:stop()
      handle.timer:close()
      handle.timer = nil
    end
  end
  handle.on_context = function() end
  handle.refresh = scan

  scan()
  handle.timer = vim.uv.new_timer()
  handle.timer:start(2000, 2000, function()
    vim.schedule(scan)
  end)
  return handle
end

return M
