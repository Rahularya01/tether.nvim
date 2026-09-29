local context = require("tether.context")
local diff = require("tether.diff")
local log = require("tether.log")
local mcp = require("tether.mcp")
local util = require("tether.util")
local ws = require("tether.ws")

local M = {}

local function object_schema(properties, required)
  local schema = {
    type = "object",
    properties = properties and util.obj(properties) or vim.empty_dict(),
  }
  if required then
    schema.required = required
  end
  return schema
end

local function prop(desc)
  return { type = "string", description = desc }
end

local function bool_prop(desc)
  return { type = "boolean", description = desc }
end

local TOOLS = {
  {
    name = "getCurrentSelection",
    description = "Get the current text selection in the active Neovim window.",
    inputSchema = object_schema(),
  },
  {
    name = "getLatestSelection",
    description = "Get the most recent non-empty text selection.",
    inputSchema = object_schema(),
  },
  {
    name = "getOpenEditors",
    description = "List buffers currently open in Neovim.",
    inputSchema = object_schema(),
  },
  {
    name = "getWorkspaceFolders",
    description = "Get workspace folders open in Neovim.",
    inputSchema = object_schema(),
  },
  {
    name = "getDiagnostics",
    description = "Get diagnostics from Neovim.",
    inputSchema = object_schema({
      uri = prop("Optional file URI or path. Omit for every open file."),
    }),
  },
  {
    name = "openFile",
    description = "Open a file in Neovim and optionally move the cursor to a text match.",
    inputSchema = object_schema({
      filePath = prop("Absolute path to open."),
      preview = bool_prop("Unused. Neovim opens the file normally."),
      startText = prop("Plain text to place the cursor on."),
      endText = prop("Plain text that ends the selection."),
      selectToEndOfLine = bool_prop("Extend the cursor to the end of the matched line."),
      makeFrontmost = bool_prop("Jump to the file. Defaults to true."),
    }, { "filePath" }),
  },
  {
    name = "openDiff",
    description = "Open a diff and block until the user accepts or rejects it.",
    inputSchema = object_schema({
      old_file_path = prop("Original file path."),
      new_file_path = prop("File path to write if the user accepts."),
      new_file_contents = prop("Proposed file contents."),
      tab_name = prop("Label for the review. close_tab with this name rejects it."),
    }),
  },
  {
    name = "checkDocumentDirty",
    description = "Check whether a buffer has unsaved changes.",
    inputSchema = object_schema({
      filePath = prop("Absolute path."),
    }, { "filePath" }),
  },
  {
    name = "saveDocument",
    description = "Save a buffer.",
    inputSchema = object_schema({
      filePath = prop("Absolute path."),
    }, { "filePath" }),
  },
  {
    name = "close_tab",
    description = "Close a diff review by its tab_name, or a buffer by its path.",
    inputSchema = object_schema({
      tab_name = prop("openDiff tab_name, or a file path."),
    }, { "tab_name" }),
  },
  {
    name = "closeAllDiffTabs",
    description = "Reject and close every Neovim diff opened for Claude.",
    inputSchema = object_schema(),
  },
}

local function find_buf(path)
  path = util.abspath(path)
  if not path then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if util.abspath(vim.api.nvim_buf_get_name(bufnr)) == path then
      return bufnr
    end
  end
end

-- A window Claude's openFile can take over: a plain file buffer, not a
-- terminal, a review diff, or a floating window. Prefers the current window.
local function editing_window()
  local function usable(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].diff then
      return false
    end
    return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
  end
  local current = vim.api.nvim_get_current_win()
  if usable(current) then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if usable(win) then
      return win
    end
  end
  return current
end

local function selection_payload(reading, fallback_path)
  if not reading or not fallback_path then
    return vim.json.encode({ success = false, message = "No active editor found" })
  end
  local selection = reading
  return vim.json.encode({
    success = true,
    text = selection.text or "",
    filePath = fallback_path,
    fileUrl = util.file_url(fallback_path),
    selection = {
      start = selection.start,
      ["end"] = selection["end"],
      isEmpty = selection.is_empty,
    },
  })
end

local function call_tool(name, args, reply, push)
  args = args or {}
  if name == "getCurrentSelection" then
    local snap = context.snapshot()
    local path = snap.active and snap.active.path
    reply(mcp.text(selection_payload(snap.selection, path)))
  elseif name == "getLatestSelection" then
    local snap = context.snapshot()
    local latest = snap.latest
    local reading = latest and latest.selection or snap.selection
    local path = (latest and latest.path) or (snap.active and snap.active.path)
    if not reading then
      reply(mcp.text(vim.json.encode({ success = false, message = "No selection available" })))
    else
      reply(mcp.text(selection_payload(reading, path)))
    end
  elseif name == "getOpenEditors" then
    local snap = context.snapshot()
    local tabs = {}
    for _, editor in ipairs(snap.editors) do
      tabs[#tabs + 1] = {
        uri = util.file_url(editor.path),
        isActive = editor.active,
        label = editor.name,
        languageId = editor.language,
        isDirty = editor.dirty,
      }
    end
    reply(mcp.text(vim.json.encode({ tabs = tabs })))
  elseif name == "getWorkspaceFolders" then
    local folders = context.folders()
    local encoded = {}
    for _, folder in ipairs(folders) do
      encoded[#encoded + 1] = {
        name = folder.name,
        uri = util.file_url(folder.path),
        path = folder.path,
      }
    end
    reply(mcp.text(vim.json.encode({
      success = true,
      folders = encoded,
      rootPath = folders[1] and folders[1].path or "",
    })))
  elseif name == "getDiagnostics" then
    local target = args.uri and util.abspath(args.uri) or nil
    reply(mcp.text(vim.json.encode(context.diagnostics(target))))
  elseif name == "openFile" then
    local path = util.abspath(args.filePath or args.path)
    if not path then
      reply(mcp.text(vim.json.encode({ success = false, message = "filePath is required" }), true))
      return
    end
    local front = args.makeFrontmost ~= false
    if front then
      vim.api.nvim_set_current_win(editing_window())
      local edited, edit_err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
      if not edited then
        reply(mcp.text(vim.json.encode({ success = false, message = tostring(edit_err) }), true))
        return
      end
      if type(args.startText) == "string" and args.startText ~= "" then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          local start_at, finish_at = line:find(args.startText, 1, true)
          if start_at then
            if type(args.endText) == "string" and args.endText ~= "" then
              local end_at = line:find(args.endText, start_at, true)
              if end_at then
                finish_at = end_at + #args.endText - 1
              end
            elseif args.selectToEndOfLine then
              finish_at = #line
            end
            pcall(vim.api.nvim_buf_set_mark, 0, "<", i, start_at - 1, {})
            pcall(vim.api.nvim_buf_set_mark, 0, ">", i, math.max(start_at - 1, finish_at - 1), {})
            vim.api.nvim_win_set_cursor(0, { i, start_at - 1 })
            break
          end
        end
      end
      reply(mcp.text("Opened file: " .. path))
    else
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      reply(mcp.text(vim.json.encode({
        success = true,
        filePath = path,
        languageId = vim.bo[bufnr].filetype,
        lineCount = vim.api.nvim_buf_line_count(bufnr),
      })))
    end
  elseif name == "checkDocumentDirty" then
    local path = util.abspath(args.filePath)
    local bufnr = path and find_buf(path) or nil
    if not bufnr then
      reply(mcp.text(vim.json.encode({
        success = false,
        message = "Document not open: " .. tostring(args.filePath),
      })))
      return
    end
    reply(mcp.text(vim.json.encode({
      success = true,
      filePath = path,
      isDirty = vim.bo[bufnr].modified,
      isUntitled = false,
    })))
  elseif name == "saveDocument" then
    local path = util.abspath(args.filePath)
    local bufnr = path and find_buf(path) or nil
    if not bufnr then
      reply(mcp.text(vim.json.encode({
        success = false,
        message = "Document not open: " .. tostring(args.filePath),
      })))
      return
    end
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("write")
    end)
    if not ok then
      reply(mcp.text(vim.json.encode({ success = false, message = tostring(err) }), true))
      return
    end
    reply(mcp.text(vim.json.encode({
      success = true,
      filePath = path,
      saved = true,
      message = "Document saved successfully",
    })))
  elseif name == "close_tab" then
    local wanted = args.tab_name
    if type(wanted) ~= "string" or wanted == "" then
      reply(mcp.text("tab_name is required", true))
      return
    end
    -- Claude closes a review by the tab_name it passed to openDiff.
    if diff.reject_label(wanted) then
      reply(mcp.text("TAB_CLOSED"))
      return
    end
    local target = util.abspath(wanted)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and target and util.abspath(name) == target then
        if vim.bo[bufnr].modified then
          reply(mcp.text("TAB_DIRTY"))
          return
        end
        vim.cmd("bdelete " .. bufnr)
        reply(mcp.text("TAB_CLOSED"))
        return
      end
    end
    reply(mcp.text("TAB_NOT_FOUND"))
  elseif name == "closeAllDiffTabs" then
    local count = diff.reject_all()
    reply(mcp.text("CLOSED_" .. count .. "_DIFF_TABS"))
  elseif name == "openDiff" then
    local path =
      util.abspath(args.new_file_path or args.newFilePath or args.filePath or args.old_file_path or args.oldFilePath)
    local contents = args.new_file_contents or args.newFileContents or args.newContent
    if not path or type(contents) ~= "string" then
      reply(mcp.text("openDiff requires a file path and new file contents", true))
      return
    end
    local opened, err = diff.open(path, contents, function(accepted)
      reply(mcp.text(accepted and "FILE_SAVED" or "DIFF_REJECTED"))
      if push then
        push()
      end
    end, { label = args.tab_name, adapter = "claude" })
    if not opened then
      reply(mcp.text(tostring(err), true))
    end
  else
    reply(mcp.text("Unknown tool: " .. tostring(name), true))
  end
end

local function selection_changed(snap)
  if not snap.active or not snap.selection then
    return nil
  end
  return {
    jsonrpc = "2.0",
    method = "selection_changed",
    params = {
      text = snap.selection.text or "",
      filePath = snap.active.path,
      fileUrl = util.file_url(snap.active.path),
      selection = {
        start = snap.selection.start,
        ["end"] = snap.selection["end"],
        isEmpty = snap.selection.is_empty,
      },
    },
  }
end

-- Lock files left by a Neovim that exited without deleting them.
function M.stale(dir)
  local stale = {}
  local scanner = vim.uv.fs_scandir(dir)
  if not scanner then
    return stale
  end
  while true do
    local name = vim.uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if name:match("%.lock$") then
      local path = dir .. "/" .. name
      local fd = io.open(path, "r")
      if fd then
        local raw = fd:read("*a")
        fd:close()
        local ok, data = pcall(vim.json.decode, raw or "")
        if ok and type(data) == "table" and data.ideName == "Neovim" and not util.pid_alive(data.pid) then
          stale[#stale + 1] = path
        end
      end
    end
  end
  return stale
end

local function sweep(dir)
  for _, path in ipairs(M.stale(dir)) do
    vim.uv.fs_unlink(path)
  end
end

function M.start(opts)
  opts = opts or {}
  local home = os.getenv("CLAUDE_CONFIG_DIR") or ((os.getenv("HOME") or "") .. "/.claude")
  local dir = opts.dir or (home .. "/ide")
  util.mkdir(dir, 448)
  sweep(dir)

  local token = util.token(16)
  local handle = {
    token = token,
    dir = dir,
    clients = 0,
  }

  -- init.lua sets handle.on_change to hear about clients connecting and dropping.
  local function changed()
    if handle.on_change then
      vim.schedule(handle.on_change)
    end
  end

  local server
  local function push(force, get)
    if not server then
      return
    end
    local clients = server.clients()
    if #clients == 0 then
      return
    end
    local message = selection_changed(get and get() or context.snapshot())
    if not message then
      return
    end
    local body = vim.json.encode(message)
    if body == handle.last and not force then
      return
    end
    handle.last = body
    for _, client in ipairs(clients) do
      client:send(body)
    end
  end

  local function broadcast(method, params)
    if not server then
      return
    end
    local body = vim.json.encode({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
    for _, client in ipairs(server.clients()) do
      client:send(body)
    end
  end

  local handlers = {
    request = {
      initialize = function(params, reply)
        local version = params.protocolVersion or "2025-03-26"
        reply({
          protocolVersion = version,
          capabilities = { tools = vim.empty_dict() },
          serverInfo = mcp.server_info,
        })
      end,
      ["tools/list"] = function(_, reply)
        reply({ tools = TOOLS })
      end,
      ["tools/call"] = function(params, reply)
        log.record("claude", "tools/call " .. tostring(params.name))
        call_tool(params.name, params.arguments, reply, push)
      end,
      ping = function(_, reply)
        reply(vim.empty_dict())
      end,
    },
    notify = {
      ["notifications/initialized"] = function()
        push(true)
      end,
      initialized = function()
        push(true)
      end,
      ide_connected = function()
        push(true)
      end,
    },
  }

  server, handle.err = ws.serve({
    host = "127.0.0.1",
    port = 0,
    name = "claude",
    auth_token = token,
    on_open = changed,
    on_close = changed,
    on_message = function(client, text, done)
      -- Replies are matched by id, so the next message does not wait for this one.
      -- openDiff replies only after a review, and pings or close_tab must still get through.
      local ok, message = pcall(vim.json.decode, text)
      if ok then
        mcp.dispatch(message, handlers, function(response)
          if response then
            client:send(vim.json.encode(response))
          end
        end)
      end
      done()
    end,
  })
  if not server then
    return nil, handle.err
  end

  handle.port = server.port
  handle.lock = string.format("%s/%d.lock", dir, server.port)
  local function write_lock()
    local folders = {}
    for _, folder in ipairs(context.folders()) do
      folders[#folders + 1] = folder.path
    end
    util.write_private(
      handle.lock,
      vim.json.encode({
        pid = vim.fn.getpid(),
        workspaceFolders = folders,
        ideName = "Neovim",
        transport = "ws",
        runningInWindows = false,
        authToken = token,
      })
    )
  end
  write_lock()

  handle.env = {
    CLAUDE_CODE_SSE_PORT = tostring(server.port),
    ENABLE_IDE_INTEGRATION = "true",
  }
  handle.on_context = function(get)
    push(false, get)
  end
  handle.refresh = write_lock
  handle.send = broadcast
  handle.stop = function()
    server.close()
    vim.uv.fs_unlink(handle.lock)
  end
  handle.client_count = function()
    return #server.clients()
  end
  handle.describe = function()
    return string.format("127.0.0.1:%s  clients=%d", tostring(handle.port), #server.clients())
  end
  return handle
end

return M
