local context = require("tether.context")
local frame = require("tether.frame")
local log = require("tether.log")
local util = require("tether.util")

local M = {}

-- Is another process accepting on this socket? Calls back on the main loop.
-- With no socket file there is nothing to ask, so it answers at once.
local function probe(path, callback)
  if not vim.uv.fs_stat(path) then
    callback(false)
    return
  end
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(path, function(err)
    pcall(function()
      pipe:close()
    end)
    vim.schedule(function()
      callback(err == nil)
    end)
  end)
end

local function default_sockets()
  local sockets = {}
  local home = os.getenv("CODEX_HOME") or ((os.getenv("HOME") or "") .. "/.codex")
  sockets[#sockets + 1] = home .. "/ipc/ipc.sock"
  local uid = vim.uv.getuid and vim.uv.getuid() or nil
  if uid then
    local tmp = vim.uv.os_tmpdir() or "/tmp"
    sockets[#sockets + 1] = string.format("%s/codex-ipc/ipc-%d.sock", tmp, uid)
  end
  return sockets
end

local function handle_message(message)
  if type(message) ~= "table" then
    return nil
  end
  if message.type == "client-discovery-request" then
    return {
      type = "client-discovery-response",
      requestId = message.requestId,
      response = { canHandle = true },
    }
  end
  if message.type ~= "request" then
    return nil
  end
  if message.method ~= "ide-context" then
    -- Codex's socket only asks for editor context. A new method shows up here.
    log.record("codex", "no handler for " .. tostring(message.method))
    return {
      type = "response",
      requestId = message.requestId,
      resultType = "error",
      error = "no-handler-for-request",
    }
  end
  local root = message.params and message.params.workspaceRoot
  return {
    type = "response",
    requestId = message.requestId,
    resultType = "success",
    method = "ide-context",
    handledByClientId = "neovim",
    result = {
      type = "broadcast",
      ideContext = context.codex(root),
    },
  }
end

local function listen(path, clients)
  local parent = vim.fn.fnamemodify(path, ":h")
  util.mkdir(parent, 448)
  pcall(vim.uv.fs_unlink, path)
  local pipe = vim.uv.new_pipe(false)
  local ok, err = pipe:bind(path)
  if not ok then
    pipe:close()
    return nil, path .. ": " .. tostring(err)
  end
  pcall(vim.uv.fs_chmod, path, 384)
  pipe:listen(128, function()
    local client = vim.uv.new_pipe(false)
    pipe:accept(client)
    clients[client] = true
    local function close()
      clients[client] = nil
      if not client:is_closing() then
        client:close()
      end
    end
    local decode = frame.decoder()
    client:read_start(function(read_err, data)
      if read_err or not data then
        close()
        return
      end
      local messages = decode(data)
      if not messages then
        close()
        return
      end
      vim.schedule(function()
        for _, message in ipairs(messages) do
          local response = handle_message(message)
          if response and not client:is_closing() then
            local encoded = frame.encode(response)
            if encoded then
              client:write(encoded)
            end
          end
        end
      end)
    end)
  end)
  return pipe
end

function M.start(opts)
  opts = opts or {}
  local wanted = opts.sockets or default_sockets()
  local pipes = {}
  local blocked = {}
  local probing = {}
  local clients = {}
  local stopped = false
  local handle = {
    sockets = {},
    errors = {},
    env = {},
    on_context = function() end,
    refresh = function() end,
  }

  local function sync_status()
    handle.sockets, handle.errors = {}, {}
    for _, path in ipairs(wanted) do
      if pipes[path] then
        handle.sockets[#handle.sockets + 1] = path
      elseif blocked[path] then
        handle.errors[#handle.errors + 1] = blocked[path]
      end
    end
  end

  local function try(path)
    if stopped or pipes[path] or probing[path] then
      return
    end
    probing[path] = true
    probe(path, function(alive)
      probing[path] = nil
      if stopped or pipes[path] then
        return
      end
      if alive then
        blocked[path] = path .. " is already served by another IDE"
      else
        local pipe, err = listen(path, clients)
        pipes[path] = pipe
        blocked[path] = err
      end
      sync_status()
    end)
  end

  for _, path in ipairs(wanted) do
    try(path)
  end

  -- Another editor may own a socket now and let it go later. Take it over then.
  handle.timer = vim.uv.new_timer()
  handle.timer:start(
    2000,
    2000,
    vim.schedule_wrap(function()
      for _, path in ipairs(wanted) do
        try(path)
      end
    end)
  )

  handle.stop = function()
    stopped = true
    if handle.timer then
      handle.timer:stop()
      handle.timer:close()
      handle.timer = nil
    end
    for client in pairs(clients) do
      if not client:is_closing() then
        client:close()
      end
    end
    clients = {}
    for path, pipe in pairs(pipes) do
      if not pipe:is_closing() then
        pipe:close()
      end
      vim.uv.fs_unlink(path)
    end
    pipes = {}
    sync_status()
  end
  handle.client_count = function()
    local n = 0
    for _ in pairs(clients) do
      n = n + 1
    end
    return n
  end
  return handle
end

return M
