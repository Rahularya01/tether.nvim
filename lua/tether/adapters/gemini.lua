local context = require("tether.context")
local diff = require("tether.diff")
local http = require("tether.http")
local mcp = require("tether.mcp")
local util = require("tether.util")

local M = {}

local function tool_schema()
  return {
    {
      name = "openDiff",
      description = "(IDE Tool) Open a diff view to create or modify a file.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = { type = "string", description = "Absolute path of the file to diff." },
          newContent = { type = "string", description = "Proposed contents of the file." },
        },
        required = { "filePath", "newContent" },
      },
    },
    {
      name = "closeDiff",
      description = "(IDE Tool) Close an open diff view for a specific file.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = { type = "string", description = "Absolute path whose diff should close." },
        },
        required = { "filePath" },
      },
    },
  }
end

-- Remove discovery files left by Neovims that exited without cleaning up.
local function sweep(dir)
  local scanner = vim.uv.fs_scandir(dir)
  if not scanner then
    return
  end
  while true do
    local name = vim.uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local pid = tonumber(name:match("^gemini%-ide%-server%-(%d+)%-%d+%.json$"))
    if pid and not util.pid_alive(pid) then
      local path = dir .. "/" .. name
      local ok, lines = pcall(vim.fn.readfile, path)
      local decoded_ok, data = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
      if decoded_ok and type(data) == "table" and type(data.ideInfo) == "table" and data.ideInfo.name == "neovim" then
        vim.uv.fs_unlink(path)
      end
    end
  end
end

function M.start(opts)
  opts = opts or {}
  local dir = opts.dir or ((vim.uv.os_tmpdir() or "/tmp") .. "/gemini/ide")
  util.mkdir(dir, 448)
  sweep(dir)
  local token = util.token(16)
  local streams = {}
  local ready = false
  local handle = { token = token, dir = dir }

  local function send_note(method, params)
    local body = vim.json.encode({
      jsonrpc = "2.0",
      method = method,
      params = params,
    })
    for i = #streams, 1, -1 do
      local stream = streams[i]
      local ok = pcall(stream.write, body)
      if not ok then
        table.remove(streams, i)
      end
    end
  end

  local function push(force, get)
    if not ready or #streams == 0 then
      return
    end
    local params = context.gemini(get and get() or nil, { trusted = opts.trusted })
    local body = vim.json.encode(params)
    if body == handle.last and not force then
      return
    end
    handle.last = body
    send_note("ide/contextUpdate", params)
  end

  local handlers = {
    request = {
      initialize = function(params, reply)
        reply({
          protocolVersion = params.protocolVersion or "2025-06-18",
          capabilities = { tools = vim.empty_dict() },
          serverInfo = { name = "tether.nvim", version = "0.2.0" },
        })
      end,
      ["tools/list"] = function(_, reply)
        reply({ tools = tool_schema() })
      end,
      ["tools/call"] = function(params, reply)
        local args = params.arguments or {}
        if params.name == "openDiff" then
          local path = util.abspath(args.filePath)
          if not path or type(args.newContent) ~= "string" then
            reply(mcp.text("openDiff requires filePath and newContent", true))
            return
          end
          local opened, err = diff.open(path, args.newContent, function(accepted, content)
            if accepted then
              send_note("ide/diffAccepted", { filePath = path, content = content })
            else
              send_note("ide/diffRejected", { filePath = path })
            end
            push()
          end)
          if not opened then
            reply(mcp.text(tostring(err), true))
          else
            reply(mcp.empty())
          end
        elseif params.name == "closeDiff" then
          local path = util.abspath(args.filePath)
          local content = path and diff.close(path) or nil
          if content == nil then
            reply(mcp.text("No diff open for " .. tostring(args.filePath), true))
          else
            reply(mcp.text(vim.json.encode({ content = content })))
          end
        else
          reply(mcp.text("Unknown tool: " .. tostring(params.name), true))
        end
      end,
      ping = function(_, reply)
        reply(vim.empty_dict())
      end,
    },
    notify = {
      ["notifications/initialized"] = function()
        ready = true
        push(true)
      end,
      initialized = function()
        ready = true
        push(true)
      end,
    },
  }

  local server = http.serve({
    host = "127.0.0.1",
    port = 0,
    on_request = function(request, respond)
      local header = request.headers["authorization"] or ""
      local got = header:match("^[Bb]earer%s+(.+)$") or header
      if got ~= token then
        respond({ status = 401, headers = { Connection = "close" }, body = "", close = true })
        return
      end
      if request.path ~= "/mcp" then
        respond({ status = 404, body = "" })
        return
      end
      if request.method == "OPTIONS" then
        respond({ status = 204, body = "" })
        return
      end
      if request.method == "GET" then
        local stream
        stream = respond({
          status = 200,
          stream = true,
          headers = {},
          on_close = function()
            for i = #streams, 1, -1 do
              if streams[i] == stream then
                table.remove(streams, i)
              end
            end
          end,
        })
        streams[#streams + 1] = stream
        if ready then
          push(true)
        end
        return
      end
      if request.method ~= "POST" then
        respond({ status = 405, body = "" })
        return
      end
      local ok, message = pcall(vim.json.decode, request.body ~= "" and request.body or "null")
      if not ok or type(message) ~= "table" then
        respond({
          status = 400,
          headers = { ["Content-Type"] = "application/json" },
          body = vim.json.encode(mcp.err(nil, -32700, "Parse error")),
        })
        return
      end
      local messages = message[1] ~= nil and message or { message }
      local responses = {}
      local pending = #messages
      if pending == 0 then
        respond({ status = 202, body = "" })
        return
      end
      local function finish_one(response)
        if response then
          responses[#responses + 1] = response
        end
        pending = pending - 1
        if pending > 0 then
          return
        end
        if #responses == 0 then
          respond({ status = 202, body = "" })
          return
        end
        local body = #responses == 1 and vim.json.encode(responses[1]) or vim.json.encode(responses)
        respond({
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = body,
        })
      end
      for _, item in ipairs(messages) do
        mcp.dispatch(item, handlers, finish_one)
      end
    end,
  })
  if not server then
    return nil, "gemini http server failed"
  end

  handle.port = server.port
  handle.file = string.format("%s/gemini-ide-server-%d-%d.json", dir, vim.fn.getpid(), server.port)
  local function write_discovery()
    local paths = {}
    for _, folder in ipairs(context.folders()) do
      paths[#paths + 1] = folder.path
    end
    util.write_private(
      handle.file,
      vim.json.encode({
        port = server.port,
        workspacePath = table.concat(paths, ":"),
        authToken = token,
        ideInfo = { name = "neovim", displayName = "Neovim" },
      })
    )
  end
  write_discovery()

  handle.env = { GEMINI_CLI_IDE_SERVER_PORT = tostring(server.port) }
  handle.on_context = function(get)
    push(false, get)
  end
  handle.refresh = write_discovery
  handle.stop = function()
    server.close()
    vim.uv.fs_unlink(handle.file)
  end
  handle.client_count = function()
    return #streams
  end
  return handle
end

return M
