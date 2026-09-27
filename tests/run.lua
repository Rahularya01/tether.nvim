local failures = {}

local function check(cond, msg)
  if cond then
    io.write("ok  " .. msg .. "\n")
  else
    failures[#failures + 1] = msg
    io.write("FAIL " .. msg .. "\n")
  end
  io.flush()
end

local function wait_until(timeout, pred)
  return vim.wait(timeout, pred, 20)
end

local sha1 = require("tether.sha1")
local ws = require("tether.ws")
local frame = require("tether.frame")
local util = require("tether.util")

check(sha1.hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 empty")
check(sha1.hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc")
check(ws.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "websocket accept key")
check(util.utf16_len("héllo") == 5, "utf16 accent")
check(util.utf16_len("🙂") == 2, "utf16 emoji")

local encoded = frame.encode({ type = "request", requestId = "abc" })
local decoded = frame.decoder()(encoded)
check(decoded and decoded[1] and decoded[1].requestId == "abc", "codex frame roundtrip")

local root = "/tmp/tether-test-" .. tostring(vim.fn.getpid())
vim.fn.mkdir(root, "p")
local sample = root .. "/hello.lua"
local fd = io.open(sample, "w")
fd:write("print('hello')\n")
fd:close()

local tether = require("tether")
local setup_errors = tether.setup({
  adapters = { "claude", "gemini", "codex" },
  claude = { dir = root .. "/claude" },
  gemini = { dir = root .. "/gemini" },
  codex = { sockets = { root .. "/codex.sock" } },
})
check(
  #setup_errors == 0,
  "setup starts every adapter" .. (#setup_errors > 0 and (": " .. table.concat(setup_errors, "; ")) or "")
)

local state = tether.state()
check(state.claude and state.claude.port ~= nil, "claude port")
check(state.gemini and state.gemini.port ~= nil, "gemini port")
check(vim.uv.fs_stat(state.claude.lock) ~= nil, "claude lock file")
check(vim.uv.fs_stat(state.gemini.file) ~= nil, "gemini discovery file")
check(vim.uv.fs_stat(root .. "/codex.sock") ~= nil, "codex socket")
check(vim.env.ENABLE_IDE_INTEGRATION == "true", "claude env flag")
check(vim.env.CLAUDE_CODE_SSE_PORT == tostring(state.claude.port), "claude env port")
check(vim.env.GEMINI_CLI_IDE_SERVER_PORT == tostring(state.gemini.port), "gemini env port")

vim.cmd("edit " .. vim.fn.fnameescape(sample))

local function client_frame(payload)
  local mask = "\1\2\3\4"
  local masked = {}
  for i = 1, #payload do
    masked[i] = string.char(bit.bxor(payload:byte(i), mask:byte((i - 1) % 4 + 1)))
  end
  local len = #payload < 126 and string.char(0x80 + #payload)
    or (string.char(0xFE) .. require("tether.bin").u16be(#payload))
  return string.char(0x81) .. len .. mask .. table.concat(masked)
end

local function connect_tcp(port)
  local sock = vim.uv.new_tcp()
  local done, err = false, nil
  sock:connect("127.0.0.1", port, function(connect_err)
    err = connect_err
    done = true
  end)
  local ok = wait_until(2000, function()
    return done
  end)
  check(ok and not err, "tcp connect " .. tostring(port) .. " " .. tostring(err))
  return sock
end

local function collect(sock)
  local acc = ""
  sock:read_start(function(err, data)
    if data then
      acc = acc .. data
    end
    if err then
      acc = acc .. "\nERR:" .. tostring(err)
    end
  end)
  return function()
    return acc
  end
end

-- Reject a WebSocket upgrade that does not present the lock-file token.
do
  local sock = connect_tcp(state.claude.port)
  local acc = collect(sock)
  sock:write(
    "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  )
  local ok = wait_until(2000, function()
    return acc():find("401", 1, true) ~= nil
  end)
  check(ok, "claude rejects missing auth")
  sock:close()
end

local sock = connect_tcp(state.claude.port)
local acc = collect(sock)
local upgrade = table.concat({
  "GET / HTTP/1.1",
  "Host: 127.0.0.1",
  "Upgrade: websocket",
  "Connection: Upgrade",
  "Sec-WebSocket-Version: 13",
  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
  "x-claude-code-ide-authorization: " .. state.claude.token,
  "",
  "",
}, "\r\n")
sock:write(upgrade)
local upgraded = wait_until(2000, function()
  return acc():find("101", 1, true) ~= nil and acc():find("\r\n\r\n", 1, true) ~= nil
end)
check(upgraded, "claude websocket upgrade")
check(acc():find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", 1, true) ~= nil, "claude accept header")

local function ws_messages()
  local raw = acc()
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return {}
  end
  local messages = ws.decoder()(raw:sub(header_end + 4)) or {}
  local decoded = {}
  for _, text in ipairs(messages) do
    local ok, msg = pcall(vim.json.decode, text)
    if ok then
      decoded[#decoded + 1] = msg
    end
  end
  return decoded
end

local function send(msg)
  sock:write(client_frame(vim.json.encode(msg)))
end

local function wait_msg(pred, label)
  local found
  local ok = wait_until(3000, function()
    for _, msg in ipairs(ws_messages()) do
      if pred(msg) then
        found = msg
        return true
      end
    end
    return false
  end)
  check(ok, label)
  return found
end

send({
  jsonrpc = "2.0",
  id = 1,
  method = "initialize",
  params = { protocolVersion = "2025-03-26", capabilities = {}, clientInfo = { name = "test", version = "0" } },
})
local init = wait_msg(function(msg)
  return msg.id == 1 and msg.result and msg.result.serverInfo
end, "claude initialize")
check(init and init.result.serverInfo.name == "tether.nvim", "claude server name")

send({ jsonrpc = "2.0", method = "notifications/initialized" })
send({ jsonrpc = "2.0", id = 2, method = "tools/list" })
local tools = wait_msg(function(msg)
  return msg.id == 2 and msg.result and msg.result.tools
end, "claude tools/list")
local names = {}
if tools then
  for _, tool in ipairs(tools.result.tools) do
    names[tool.name] = true
  end
end
check(names.getCurrentSelection and names.openDiff and names.getDiagnostics, "claude tool names")

send({
  jsonrpc = "2.0",
  id = 3,
  method = "tools/call",
  params = { name = "getOpenEditors", arguments = {} },
})
local editors = wait_msg(function(msg)
  return msg.id == 3
end, "claude getOpenEditors")
check(editors and editors.result.content[1].text:find("hello.lua", 1, true) ~= nil, "claude sees hello.lua")

send({
  jsonrpc = "2.0",
  id = 4,
  method = "tools/call",
  params = {
    name = "openDiff",
    arguments = {
      new_file_path = sample,
      new_file_contents = "print('updated')\n",
    },
  },
})
local opened = wait_until(3000, function()
  return require("tether.diff").current(sample) ~= nil
end)
check(opened, "claude openDiff opens a review")
require("tether.diff").accept()
local saved = wait_msg(function(msg)
  return msg.id == 4 and msg.result and msg.result.content and msg.result.content[1].text == "FILE_SAVED"
end, "claude openDiff accepts")
local written = io.open(sample, "r")
local body = written and written:read("*a") or ""
if written then
  written:close()
end
check(body == "print('updated')\n", "accepted diff was written")

local function read_sample()
  local f = io.open(sample, "r")
  local text = f and f:read("*a") or ""
  if f then
    f:close()
  end
  return text
end

local function tool_text(msg)
  return msg and msg.result and msg.result.content and msg.result.content[1] and msg.result.content[1].text
end

local function call(id, name, arguments)
  send({
    jsonrpc = "2.0",
    id = id,
    method = "tools/call",
    params = { name = name, arguments = arguments or {} },
  })
end

local function open_review(id, contents, label)
  call(id, "openDiff", { new_file_path = sample, new_file_contents = contents, tab_name = label })
  return wait_until(3000, function()
    return require("tether.diff").current(sample) ~= nil
  end)
end

local function reply_text(id, label)
  return tool_text(wait_msg(function(msg)
    return msg.id == id
  end, label))
end

-- An open review must not hold up the rest of the connection.
check(open_review(10, "print('ping')\n", "review-10"), "claude second review opens")
send({ jsonrpc = "2.0", id = 11, method = "ping" })
wait_msg(function(msg)
  return msg.id == 11
end, "claude answers ping during a review")
call(12, "getCurrentSelection")
check(reply_text(12, "claude answers getCurrentSelection during a review") ~= nil, "claude tool call during a review")

-- close_tab with the review's tab_name rejects it and answers the pending openDiff.
call(13, "close_tab", { tab_name = "review-10" })
check(reply_text(13, "claude close_tab reply") == "TAB_CLOSED", "claude close_tab closes the review by label")
check(reply_text(10, "claude openDiff answered after close_tab") == "DIFF_REJECTED", "close_tab rejects the review")
check(require("tether.diff").current(sample) == nil, "review session is gone after close_tab")

-- A bare file name must not close some other buffer that shares it.
call(14, "close_tab", { tab_name = "hello.lua" })
check(reply_text(14, "claude close_tab by basename reply") == "TAB_NOT_FOUND", "close_tab ignores a bare basename")
check(vim.fn.bufloaded(sample) == 1, "close_tab left the real buffer loaded")

-- Closing the review tab by hand rejects it.
check(open_review(15, "print('closed')\n", "review-15"), "claude third review opens")
vim.cmd("tabclose")
check(reply_text(15, "claude openDiff answered after :tabclose") == "DIFF_REJECTED", ":tabclose rejects the review")
check(read_sample() == "print('updated')\n", "a rejected review leaves the file alone")

-- Accepting does not overwrite unsaved edits, and leaves 'fixendofline' as it was.
local sample_buf = vim.fn.bufnr(sample)
vim.api.nvim_buf_set_lines(sample_buf, 0, -1, false, { "-- unsaved" })
check(open_review(16, "print('noeol')", "review-16"), "claude fourth review opens")
local refused, refused_err = require("tether.diff").accept()
check(not refused and tostring(refused_err):find("unsaved", 1, true), "accept refuses to overwrite unsaved edits")
vim.api.nvim_buf_set_lines(sample_buf, 0, -1, false, { "print('updated')" })
vim.bo[sample_buf].modified = false
vim.bo[sample_buf].fixendofline = true
check(require("tether.diff").accept(sample), "accept works once the edits are gone")
check(reply_text(16, "claude openDiff answered after accept") == "FILE_SAVED", "claude hears FILE_SAVED")
check(read_sample() == "print('noeol')", "accepted proposal is written byte for byte")
check(vim.bo[sample_buf].fixendofline == true, "accept restores fixendofline")

local ns = vim.api.nvim_create_namespace("tether-test")
vim.diagnostic.set(ns, sample_buf, { { lnum = 0, col = 0, message = "boom", severity = vim.diagnostic.severity.WARN } })
call(17, "getDiagnostics", { uri = vim.uri_from_fname(sample) })
check((reply_text(17, "claude getDiagnostics reply") or ""):find("boom", 1, true), "claude getDiagnostics")
vim.diagnostic.reset(ns, sample_buf)

-- Keymaps and :TetherSend put a reference in Claude's prompt. Nothing is submitted.
check(vim.fn.maparg("<leader>af", "n") ~= "", "default keymap <leader>af")
check(vim.fn.maparg("<leader>ao", "n") ~= "", "default keymap <leader>ao in normal mode")
check(vim.fn.maparg("<leader>ao", "x") ~= "", "default keymap <leader>ao in visual mode")

local multi = root .. "/multi.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a + b + c" }, multi)
vim.cmd("edit " .. vim.fn.fnameescape(multi))

local function mention(pred, label)
  return wait_msg(function(msg)
    return msg.method == "at_mentioned" and msg.params.filePath == util.abspath(multi) and pred(msg.params)
  end, label)
end

vim.fn.maparg("<leader>af", "n", false, true).callback()
mention(function(params)
  return params.lineStart == nil and params.lineEnd == nil
end, "<leader>af mentions the whole file")

-- Define the user commands. g:tether_disable keeps the plugin file from starting a second copy.
vim.g.loaded_tether = nil
vim.cmd.source("plugin/tether.lua")
vim.cmd("2TetherSendSelection")
mention(function(params)
  return params.lineStart == 1 and params.lineEnd == 1
end, ":2TetherSendSelection mentions line 2, 0-based for Claude")

vim.api.nvim_feedkeys(vim.keycode("3GVj<Leader>ao"), "mx", false)
mention(function(params)
  return params.lineStart == 2 and params.lineEnd == 3
end, "<leader>ao in visual mode mentions the selected lines")
check(vim.fn.mode() == "n", "<leader>ao leaves visual mode")

vim.fn.maparg("<leader>ao", "n", false, true).callback()
mention(function(params)
  return params.lineStart == 2 and params.lineEnd == 3
end, "<leader>ao in normal mode reuses the last selection")

vim.cmd("1,2TetherSend")
mention(function(params)
  return params.lineStart == 0 and params.lineEnd == 1
end, ":1,2TetherSend mentions the range")
vim.cmd("4AiSend")
mention(function(params)
  return params.lineStart == 3 and params.lineEnd == 3
end, "the old :AiSend name still works")
vim.cmd("edit " .. vim.fn.fnameescape(sample))

-- Gemini CLI: MCP over HTTP plus an SSE channel for editor context.
local function http_exchange(method, path, body, token)
  local client = connect_tcp(state.gemini.port)
  local got = collect(client)
  local req = {
    method .. " " .. path .. " HTTP/1.1",
    "Host: 127.0.0.1",
    "Authorization: Bearer " .. (token or state.gemini.token),
    "Accept: application/json, text/event-stream",
    "Connection: close",
  }
  if body then
    req[#req + 1] = "Content-Type: application/json"
    req[#req + 1] = "Content-Length: " .. tostring(#body)
    req[#req + 1] = ""
    req[#req + 1] = body
  else
    req[#req + 1] = ""
    req[#req + 1] = ""
  end
  client:write(table.concat(req, "\r\n"))
  local status, response
  local ok = wait_until(3000, function()
    local raw = got()
    local header_end = raw:find("\r\n\r\n", 1, true)
    if not header_end then
      return false
    end
    local head = raw:sub(1, header_end - 1)
    status = tonumber(head:match("HTTP/1%.1 (%d+)"))
    local len = tonumber(head:lower():match("content%-length:%s*(%d+)"))
    local rest = raw:sub(header_end + 4)
    if len and #rest < len then
      return false
    end
    response = len and rest:sub(1, len) or rest
    return status ~= nil
  end)
  client:close()
  check(ok, "gemini " .. method .. " " .. path)
  return status, response
end

local denied = http_exchange(
  "POST",
  "/mcp",
  vim.json.encode({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = {},
  }),
  "wrong-token"
)
check(denied == 401, "gemini rejects a bad token")

local status, response = http_exchange(
  "POST",
  "/mcp",
  vim.json.encode({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = { protocolVersion = "2025-06-18", capabilities = {}, clientInfo = { name = "test", version = "0" } },
  })
)
check(status == 200 and response:find("tether%.nvim"), "gemini initialize")

local list_status, list_body = http_exchange(
  "POST",
  "/mcp",
  vim.json.encode({
    jsonrpc = "2.0",
    id = 2,
    method = "tools/list",
  })
)
check(
  list_status == 200 and list_body:find("openDiff", 1, true) and list_body:find("closeDiff", 1, true),
  "gemini tools"
)

local sse = connect_tcp(state.gemini.port)
local sse_acc = collect(sse)
sse:write(table.concat({
  "GET /mcp HTTP/1.1",
  "Host: 127.0.0.1",
  "Authorization: Bearer " .. state.gemini.token,
  "Accept: text/event-stream",
  "",
  "",
}, "\r\n"))
local sse_up = wait_until(2000, function()
  return sse_acc():find("text/event-stream", 1, true) ~= nil
end)
check(sse_up, "gemini sse channel")

local note_status = http_exchange(
  "POST",
  "/mcp",
  vim.json.encode({
    jsonrpc = "2.0",
    method = "notifications/initialized",
  })
)
check(note_status == 202, "gemini initialized notification")
local saw_context = wait_until(2000, function()
  return sse_acc():find("ide/contextUpdate", 1, true) ~= nil and sse_acc():find("hello.lua", 1, true) ~= nil
end)
check(saw_context, "gemini receives editor context")
sse:close()
check(
  wait_until(2000, function()
    return state.gemini.client_count() == 0
  end),
  "gemini forgets a closed event stream"
)
check(not sse_acc():find("isTrusted", 1, true), "gemini leaves workspace trust to the CLI by default")
check(
  require("tether.context").gemini(nil, { trusted = false }).workspaceState.isTrusted == false,
  "gemini trust can be set in config"
)

-- Discovery files from a Neovim that crashed are removed. Other IDEs' files are left alone.
do
  local dir = root .. "/gemini-sweep"
  vim.fn.mkdir(dir, "p")
  local stale = dir .. "/gemini-ide-server-999999-1.json"
  local other = dir .. "/gemini-ide-server-999999-2.json"
  vim.fn.writefile({ vim.json.encode({ port = 1, ideInfo = { name = "neovim" } }) }, stale)
  vim.fn.writefile({ vim.json.encode({ port = 2, ideInfo = { name = "vscode" } }) }, other)
  local swept = require("tether.adapters.gemini").start({ dir = dir })
  check(vim.uv.fs_stat(stale) == nil, "gemini sweeps a stale Neovim discovery file")
  check(vim.uv.fs_stat(other) ~= nil, "gemini keeps another IDE's discovery file")
  swept.stop()
end

-- Codex TUI: length-prefixed JSON over the unix socket.
local pipe = vim.uv.new_pipe(false)
local connected, connect_err = false, nil
pipe:connect(root .. "/codex.sock", function(err)
  connect_err = err
  connected = true
end)
check(wait_until(2000, function()
  return connected
end) and not connect_err, "codex connect " .. tostring(connect_err))
local codex_acc = ""
pipe:read_start(function(err, data)
  if data then
    codex_acc = codex_acc .. data
  end
end)
pipe:write(frame.encode({
  type = "request",
  requestId = "req-1",
  sourceClientId = "codex-tui",
  version = 0,
  method = "ide-context",
  params = { workspaceRoot = root },
}))
local codex_ok = wait_until(2000, function()
  local msgs = frame.decoder()(codex_acc)
  return msgs and msgs[1] and msgs[1].requestId == "req-1"
end)
local codex_msg = frame.decoder()(codex_acc)
codex_msg = codex_msg and codex_msg[1]
check(codex_ok and codex_msg and codex_msg.resultType == "success", "codex ide-context")
local active = codex_msg and codex_msg.result and codex_msg.result.ideContext and codex_msg.result.ideContext.activeFile
check(active and util.abspath(active.fsPath) == util.abspath(sample), "codex active file")
check(active and active.path == "hello.lua", "codex relative path")
check(active and active.activeSelectionContent == "", "codex empty selection")
check(state.codex.client_count() == 1, "codex counts its client")
pipe:close()
check(
  wait_until(2000, function()
    return state.codex.client_count() == 0
  end),
  "codex forgets a closed client"
)

-- A socket another IDE is serving is left alone, then taken over once it goes away.
do
  local busy = root .. "/busy.sock"
  local other = vim.uv.new_pipe(false)
  other:bind(busy)
  other:listen(8, function()
    local c = vim.uv.new_pipe(false)
    other:accept(c)
    c:close()
  end)
  local codex = require("tether.adapters.codex").start({ sockets = { busy } })
  check(
    wait_until(2000, function()
      return #codex.errors == 1 and codex.errors[1]:find("another IDE", 1, true) ~= nil
    end),
    "codex leaves a socket another IDE is serving"
  )
  check(#codex.sockets == 0, "codex did not bind the busy socket")
  other:close()
  check(
    wait_until(5000, function()
      return codex.sockets[1] == busy
    end),
    "codex takes the socket over after the other IDE exits"
  )
  codex.stop()
  check(vim.uv.fs_stat(busy) == nil, "codex removes the socket it took over")
end

-- OpenCode: attach to a server that is already running, via its state file.
do
  local state_dir = root .. "/opencode-state"
  vim.fn.mkdir(state_dir, "p")
  local appended
  local mock = require("tether.http").serve({
    host = "127.0.0.1",
    port = 0,
    on_request = function(request, respond)
      local expected = "Basic " .. vim.base64.encode("opencode:secret-token")
      if request.headers.authorization ~= expected then
        respond({ status = 401, body = "" })
        return
      end
      if request.path == "/global/health" then
        respond({
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = vim.json.encode({ healthy = true, version = "test" }),
        })
      elseif request.path == "/tui/append-prompt" then
        appended = request.body
        respond({ status = 200, headers = { ["Content-Type"] = "application/json" }, body = "true" })
      else
        respond({ status = 404, body = "" })
      end
    end,
  })
  local reg = io.open(state_dir .. "/server.json", "w")
  reg:write(vim.json.encode({
    url = "http://127.0.0.1:" .. mock.port,
    pid = vim.fn.getpid(),
    version = "test",
  }))
  reg:close()
  local secret = io.open(state_dir .. "/password", "w")
  secret:write("secret-token")
  secret:close()

  local found = require("tether.adapters.opencode").start({ dir = state_dir })
  local attached = wait_until(3000, function()
    return found.connected
  end)
  check(attached and found.version == "test", "opencode finds the running server")
  local sent = found.append(sample)
  local pushed = wait_until(3000, function()
    return appended ~= nil
  end)
  check(sent and pushed and appended:find("hello.lua", 1, true) ~= nil, "opencode receives editor context")
  found.stop()
  mock.close()

  local dead_dir = root .. "/opencode-dead"
  vim.fn.mkdir(dead_dir, "p")
  local dead_file = io.open(dead_dir .. "/server.json", "w")
  dead_file:write(vim.json.encode({ url = "http://127.0.0.1:9", pid = 999999 }))
  dead_file:close()
  local dead = require("tether.adapters.opencode").start({ dir = dead_dir })
  check(not dead.connected and dead.detail == "no running server", "opencode ignores a dead server")
  dead.stop()
end

local herdr = require("tether.adapters.herdr")
local agents = {
  { agent = "cursor", pane_id = "w1:p1", cwd = "/work/tether.nvim", focused = true, agent_status = "working" },
  { agent = "claude", pane_id = "w1:p3", cwd = "/work/tether.nvim", focused = false, agent_status = "idle" },
  { agent = "claude", pane_id = "w9:p1", cwd = "/other", focused = false, agent_status = "idle" },
}
local chosen = herdr.choose(agents, "/work/tether.nvim")
check(chosen and chosen.pane_id == "w1:p3", "herdr picks the Claude pane in this project")
check(herdr.choose(agents, "/somewhere/else") == nil, "herdr ignores Claude in another directory")

-- Inside Herdr, only Claude panes in Neovim's own workspace are candidates.
do
  local spread = {
    {
      agent = "claude",
      pane_id = "w2:p1",
      workspace_id = "w2",
      tab_id = "w2:t1",
      cwd = "/work/tether.nvim",
      focused = true,
      agent_status = "idle",
    },
    {
      agent = "claude",
      pane_id = "w1:p5",
      workspace_id = "w1",
      tab_id = "w1:t2",
      cwd = "/work/tether.nvim",
      agent_status = "working",
    },
    {
      agent = "claude",
      pane_id = "w1:p6",
      workspace_id = "w1",
      tab_id = "w1:t1",
      cwd = "/elsewhere",
      agent_status = "working",
    },
  }
  local here = { workspace = "w1", tab = "w1:t9", pane = "w1:p1" }
  check(herdr.choose(spread, "/work/tether.nvim", here).pane_id == "w1:p5", "herdr never picks another workspace")
  here.tab = "w1:t1"
  check(herdr.choose(spread, "/work/tether.nvim", here).pane_id == "w1:p6", "herdr prefers Claude in the same tab")
  check(
    herdr.choose(spread, "/work/tether.nvim", { workspace = "w3" }) == nil,
    "herdr finds nothing in an empty workspace"
  )
  check(
    herdr.choose(
      { { agent = "claude", pane_id = "w1:p1", workspace_id = "w1" } },
      "/work/tether.nvim",
      { workspace = "w1", pane = "w1:p1" }
    ) == nil,
    "herdr never picks Neovim's own pane"
  )
end

-- Herdr: every agent in Neovim's workspace is offered in a picker, and the choice
-- gets the reference typed in with send-text, which does not press Enter.
do
  local log = root .. "/herdr.log"
  local listing = root .. "/herdr-agents.json"
  local fake = root .. "/herdr"
  local function agents(list)
    vim.fn.writefile({ vim.json.encode({ result = { agents = list } }) }, listing)
  end
  local function calls()
    return vim.uv.fs_stat(log) and table.concat(vim.fn.readfile(log), "\n") or ""
  end
  vim.fn.writefile({
    "#!/bin/sh",
    'printf "%s\\n" "$*" >> ' .. vim.fn.shellescape(log),
    'if [ "$1" = agent ] && [ "$2" = list ]; then',
    "  cat " .. vim.fn.shellescape(listing),
    "fi",
  }, fake)
  vim.uv.fs_chmod(fake, 493)
  local claude_pane =
    { agent = "claude", pane_id = "w1:p3", workspace_id = "w1", tab_id = "w1:t2", agent_status = "idle" }
  local codex_pane =
    { agent = "codex", pane_id = "w1:p4", workspace_id = "w1", tab_id = "w1:t3", agent_status = "idle" }
  local elsewhere = { agent = "claude", pane_id = "w2:p1", workspace_id = "w2", tab_id = "w2:t1", focused = true }
  agents({ codex_pane, elsewhere, claude_pane })

  -- Run from the project directory so references are relative, as they are in real use.
  local previous_cwd = vim.fn.getcwd()
  vim.cmd.cd(root)
  tether.setup({
    adapters = { "herdr" },
    herdr = { bin = fake, here = { workspace = "w1", tab = "w1:t1", pane = "w1:p1" } },
  })
  vim.cmd("edit " .. vim.fn.fnameescape(multi))

  local offered, answer
  local real_select = tether.select
  tether.select = function(items, opts, on_choice)
    offered = { items = items, prompt = opts.prompt, lines = vim.tbl_map(opts.format_item, items) }
    on_choice(answer and items[answer] or nil)
  end
  local function send_and_wait(kind, range, expect)
    offered = nil
    tether.send(kind, range)
    return wait_until(3000, function()
      return expect()
    end)
  end

  answer = 2
  check(
    send_and_wait("selection", { 2, 3 }, function()
      return calls():find("send-text w1:p4", 1, true) ~= nil
    end),
    "herdr sends to the agent picked in the dialog"
  )
  check(offered and #offered.items == 2, "herdr offers only the agents in Neovim's workspace")
  check(offered and offered.items[1].agent.pane_id == "w1:p3", "herdr lists Claude first")
  check(offered and offered.lines[2]:find("codex", 1, true) ~= nil, "herdr picker names the agent")
  check(calls():find("send-text w1:p4 multi.lua:2-3 ", 1, true) ~= nil, "a non-Claude agent gets a plain path:lines")
  check(calls():find("agent prompt", 1, true) == nil, "herdr does not submit the prompt")

  answer = 1
  check(send_and_wait("file", nil, function()
    return offered ~= nil
  end) and offered.items[1].agent.pane_id == "w1:p4", "the agent used last is offered first")
  check(
    wait_until(3000, function()
      return calls():find("send-text w1:p4 multi.lua ", 1, true) ~= nil
    end),
    "Enter on the first entry repeats the last agent"
  )

  answer = nil
  local function sends()
    return select(2, calls():gsub("send%-text", ""))
  end
  local before = sends()
  send_and_wait("file", nil, function()
    return offered ~= nil
  end)
  vim.wait(200)
  check(sends() == before, "cancelling the picker sends nothing")

  -- One agent: pick = "always" (the default) still asks.
  agents({ claude_pane })
  answer = 1
  send_and_wait("selection", { 1, 1 }, function()
    return calls():find("send-text w1:p3 @multi.lua#L1 ", 1, true) ~= nil
  end)
  check(offered and #offered.items == 1, "with one agent the picker still asks by default")
  check(calls():find("send-text w1:p3 @multi.lua#L1 ", 1, true) ~= nil, "Claude gets an @path#L reference")

  -- Claude Code reads a quoted reference for a path with spaces.
  local spaced = root .. "/my notes.lua"
  vim.fn.writefile({ "return 1" }, spaced)
  vim.cmd("edit " .. vim.fn.fnameescape(spaced))
  send_and_wait("selection", { 1, 1 }, function()
    return calls():find('send-text w1:p3 @"my notes.lua#L1" ', 1, true) ~= nil
  end)
  check(
    calls():find('send-text w1:p3 @"my notes.lua#L1" ', 1, true) ~= nil,
    'a path with spaces is sent as @"my notes.lua#L1"'
  )
  vim.cmd("edit " .. vim.fn.fnameescape(multi))

  -- pick = "auto" skips the picker when there is only one agent.
  tether.setup({
    adapters = { "herdr" },
    pick = "auto",
    herdr = { bin = fake, here = { workspace = "w1", tab = "w1:t1", pane = "w1:p1" } },
  })
  check(send_and_wait("selection", { 2, 2 }, function()
    return calls():find("send-text w1:p3 @multi.lua#L2 ", 1, true) ~= nil
  end) and offered == nil, 'pick = "auto" sends to a lone agent without asking')
  tether.select = real_select
  vim.cmd.cd(previous_cwd)
end

-- tmux: panes count as agents when a known agent CLI runs in them.
do
  local tmux_adapter = require("tether.adapters.tmux")
  local rows = tmux_adapter.parse_panes(table.concat({
    table.concat({ "%1", "$1", "work", "@1", "0", "0", "100", "nvim", "/p", "1", "1", "1", "" }, "\t"),
    table.concat({ "%2", "$1", "work", "@1", "0", "1", "200", "zsh", "/p", "0", "1", "1", "Claude Code" }, "\t"),
    table.concat({ "%3", "$1", "work", "@2", "1", "0", "300", "node", "/p", "1", "0", "1", "" }, "\t"),
    table.concat({ "%4", "$2", "other", "@3", "0", "0", "400", "claude", "/p", "1", "1", "0", "" }, "\t"),
  }, "\n"))
  check(#rows == 4 and rows[2].pane_title == "Claude Code", "tmux list-panes output is parsed")
  local under = tmux_adapter.parse_processes(table.concat({
    "  100     1 nvim",
    "  110   100 /bin/zsh",
    "  111   110 claude",
    "  200     1 -zsh",
    "  201   200 claude --resume",
    "  300     1 node /opt/homebrew/bin/gemini",
  }, "\n"))
  check(under("200") == "claude", "tmux finds Claude under a pane's shell")
  check(under("300") == "gemini", "tmux finds a node-based agent by its script name")
  check(under("100") == nil, "tmux ignores Claude inside Neovim's own terminal")
  local found, here = tmux_adapter.find(rows, under, "%1")
  check(here and here.workspace == "$1" and here.tab == "@1", "tmux knows which session Neovim is in")
  local ranked = require("tether.panes").rank(found, "/p", here)
  check(#ranked == 2 and ranked[1].pane_id == "%2", "tmux offers agents in Neovim's session, same window first")
  check(ranked[1].label == "work:0.1", "tmux labels panes as session:window.pane")
end

-- tmux end to end, on a private server: pick an agent pane and type into it without Enter.
if vim.fn.executable("tmux") == 1 then
  local socket = "tether-test-" .. vim.fn.getpid()
  local function tmux(args)
    return vim.system(vim.list_extend({ "tmux", "-L", socket, "-f", "/dev/null" }, args), { text = true }):wait()
  end
  local bin = root .. "/agents"
  vim.fn.mkdir(bin, "p")
  for _, name in ipairs({ "claude", "codex" }) do
    -- Records the line only if Enter arrives. The test expects it never does.
    vim.fn.writefile({ "#!/bin/sh", "read line", 'echo "$line" > "$0.submitted"', "sleep 300" }, bin .. "/" .. name)
    vim.uv.fs_chmod(bin .. "/" .. name, 493)
  end
  tmux({ "new-session", "-d", "-s", "work", "-x", "200", "-y", "50", "-c", root, "sh" })
  tmux({ "split-window", "-t", "work", "-c", root, bin .. "/claude" })
  tmux({ "new-window", "-t", "work", "-c", root, bin .. "/codex" })
  tmux({ "new-session", "-d", "-s", "other", "-c", root, bin .. "/claude" })
  local nvim_pane = vim.trim(tmux({ "display-message", "-p", "-t", "work:0.0", "#{pane_id}" }).stdout or "")
  local claude_pane = vim.trim(tmux({ "display-message", "-p", "-t", "work:0.1", "#{pane_id}" }).stdout or "")

  local saved_tmux, saved_pane = vim.env.TMUX, vim.env.TMUX_PANE
  vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/" .. socket .. ",1,0", nvim_pane
  local previous_cwd = vim.fn.getcwd()
  vim.cmd.cd(root)

  local handle = require("tether.adapters.tmux").start({ socket = socket })
  local listed
  wait_until(5000, function()
    handle.targets(function(agents)
      listed = agents
    end)
    vim.wait(300, function()
      return listed ~= nil
    end)
    return listed and #listed == 2
  end)
  check(listed and #listed == 2, "tmux lists the two agents in Neovim's session")
  check(listed and listed[1] and listed[1].pane_id == claude_pane, "tmux puts Claude in Neovim's window first")

  tether.setup({ adapters = { "tmux" }, tmux = { socket = socket } })
  vim.cmd("edit " .. vim.fn.fnameescape(multi))
  local real_select = tether.select
  local offered
  tether.select = function(items, opts, on_choice)
    offered = vim.tbl_map(opts.format_item, items)
    on_choice(items[1])
  end
  tether.send("selection", { 2, 3 })
  local typed = wait_until(5000, function()
    local screen = tmux({ "capture-pane", "-p", "-t", claude_pane }).stdout or ""
    return screen:find("@multi.lua#L2-3", 1, true) ~= nil
  end)
  check(typed, "tmux types the reference into the Claude pane")
  check(offered and offered[1]:find("^tmux") and offered[1]:find("work:0.1", 1, true), "tmux picker shows the pane")
  vim.wait(300)
  check(vim.uv.fs_stat(bin .. "/claude.submitted") == nil, "tmux does not press Enter")

  tether.select = real_select
  vim.env.TMUX, vim.env.TMUX_PANE = saved_tmux, saved_pane
  vim.cmd.cd(previous_cwd)
  tmux({ "kill-server" })
else
  io.write("skip tmux end to end: tmux is not installed\n")
end

tether.stop()
check(not tether.is_running(), "stop clears listeners")
check(vim.uv.fs_stat(root .. "/codex.sock") == nil, "codex socket removed")
check(vim.env.CLAUDE_CODE_SSE_PORT == nil, "claude env cleared")
check(vim.fn.maparg("<leader>af", "n") == "", "stop removes the keymaps")

if #failures > 0 then
  io.write(string.format("\n%d failed\n", #failures))
  io.flush()
  vim.cmd("cquit 1")
else
  io.write("\nall passed\n")
  io.flush()
  vim.cmd("qa!")
end
