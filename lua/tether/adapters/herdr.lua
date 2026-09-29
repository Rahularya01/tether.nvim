local panes = require("tether.panes")

local M = {}

local function binary()
  if vim.fn.executable("herdr") == 1 then
    return "herdr"
  end
  for _, path in ipairs({ "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr" }) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
end

-- Where this Neovim runs. Herdr sets these in every pane it starts.
function M.here()
  local workspace = vim.env.HERDR_WORKSPACE_ID
  if not workspace or workspace == "" then
    return nil
  end
  return { workspace = workspace, tab = vim.env.HERDR_TAB_ID, pane = vim.env.HERDR_PANE_ID }
end

M.rank = panes.rank

function M.choose(agents, cwd, here, last)
  return panes.rank(agents, cwd, here, last)[1]
end

M.describe = panes.describe

function M.start(opts)
  opts = opts or {}
  local bin = opts.bin or binary()
  -- opts.here: a { workspace, tab, pane } table, or false to ignore Herdr's environment.
  local here = opts.here
  if here == nil then
    here = M.here()
  end
  here = here or nil
  local handle = {
    env = {},
    here = here,
    detail = bin and "no agent pane" or "herdr not installed",
    on_context = function() end,
  }
  local scanning = false

  local function list(callback)
    if not bin then
      callback({})
      return
    end
    vim.system({ bin, "agent", "list" }, { text = true }, function(out)
      vim.schedule(function()
        if not out or out.code ~= 0 then
          handle.detail = "herdr did not answer"
          callback({})
          return
        end
        local ok, decoded = pcall(vim.json.decode, out.stdout or "")
        local agents = ok and type(decoded) == "table" and decoded.result and decoded.result.agents or {}
        local ranked = M.rank(agents, vim.fn.getcwd(), here, handle.last)
        handle.agents = ranked
        if #ranked == 0 then
          handle.detail = here and ("no agent pane in workspace " .. here.workspace) or "no agent pane for this project"
        else
          local names = {}
          for _, agent in ipairs(ranked) do
            names[#names + 1] = agent.agent .. " " .. agent.pane_id
          end
          handle.detail = table.concat(names, ", ")
        end
        callback(ranked)
      end)
    end)
  end

  local function scan()
    if scanning then
      return
    end
    scanning = true
    list(function()
      scanning = false
    end)
  end

  -- The agents text could go to right now, best first. Always a fresh list.
  handle.targets = list

  -- Types text into a pane's input without pressing Enter. The user submits it.
  function handle.focus(pane_id, done)
    if not bin then
      if done then
        done(false, handle.detail)
      end
      return
    end
    vim.system({ bin, "agent", "focus", pane_id }, { text = true }, function(out)
      vim.schedule(function()
        local focused = out and out.code == 0
        local message = ((out and out.stdout) or "") .. ((out and out.stderr) or "")
        if done then
          done(focused, message)
        end
      end)
    end)
  end

  local function pane_from(stdout)
    local ok, decoded = pcall(vim.json.decode, stdout or "")
    if ok and type(decoded) == "table" then
      local result = decoded.result or decoded
      if type(result) == "table" then
        return result.pane_id or result.paneId or result.id
      end
    end
    local line = vim.trim(stdout or "")
    if line ~= "" and not line:find("\n") then
      return line
    end
  end

  -- New pane in dir, then start the agent in it. done(ok, pane_id, message).
  function handle.spawn(dir, kind, done)
    if not bin then
      if done then
        done(false, nil, handle.detail)
      end
      return
    end
    vim.system(
      { bin, "pane", "split", "--cwd", dir, "--direction", "right", "--no-focus" },
      { text = true },
      function(split)
        vim.schedule(function()
          local pane = split and split.code == 0 and pane_from(split.stdout) or nil
          if not pane then
            if done then
              done(false, nil, vim.trim(((split and split.stdout) or "") .. ((split and split.stderr) or "")))
            end
            return
          end
          vim.system({ bin, "agent", "start", kind, "--kind", kind, "--pane", pane }, { text = true }, function(started)
            vim.schedule(function()
              local message = vim.trim(((started and started.stdout) or "") .. ((started and started.stderr) or ""))
              if done then
                done(started and started.code == 0, pane, message)
              end
            end)
          end)
        end)
      end
    )
  end

  function handle.insert(pane_id, text, done)
    if not bin then
      if done then
        done(false, handle.detail)
      end
      return
    end
    handle.last = pane_id
    vim.system({ bin, "pane", "send-text", pane_id, text }, { text = true }, function(out)
      vim.schedule(function()
        local sent = out and out.code == 0
        local message = ((out and out.stdout) or "") .. ((out and out.stderr) or "")
        if done then
          done(sent, message)
        end
      end)
    end)
  end

  function handle.stop()
    if handle.timer then
      handle.timer:stop()
      handle.timer:close()
      handle.timer = nil
    end
  end

  handle.refresh = scan
  if bin then
    scan()
    handle.timer = vim.uv.new_timer()
    handle.timer:start(2000, 2000, function()
      vim.schedule(scan)
    end)
  end
  return handle
end

return M
