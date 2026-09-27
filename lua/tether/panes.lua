-- Agent panes in terminal multiplexers (Herdr, tmux): which ones text can go
-- to, in what order, and how the picker shows them.
-- An agent is { agent, pane_id, workspace_id, tab_id, cwd, focused,
-- agent_status, terminal_title, label }. Only agent and pane_id are required.
local util = require("tether.util")

local M = {}

-- Every agent pane text could go to, best first.
-- here is where Neovim runs: { workspace, tab, pane }. For Herdr the workspace
-- is a Herdr workspace; for tmux it is the tmux session. With here set, only
-- panes in the same workspace count. Without it (Neovim runs outside the
-- multiplexer) there is no workspace to go by, so the pane's directory must match.
-- Order: the pane used last, same tab, Claude, same project directory,
-- focused, idle.
function M.rank(agents, cwd, here, last)
  cwd = util.abspath(cwd)
  local function related(agent)
    local there = agent.cwd and util.abspath(agent.cwd)
    return there and cwd and (there == cwd or util.under(there, cwd) or util.under(cwd, there)) or false
  end
  local matches = {}
  for _, agent in ipairs(agents or {}) do
    local ok = type(agent.agent) == "string" and agent.pane_id and agent.pane_id ~= (here and here.pane)
    if ok and here then
      ok = agent.workspace_id == here.workspace
    elseif ok then
      ok = related(agent)
    end
    if ok then
      matches[#matches + 1] = agent
    end
  end
  local function rank(agent)
    return {
      last ~= nil and agent.pane_id == last,
      here and here.tab and agent.tab_id == here.tab or false,
      agent.agent == "claude",
      related(agent),
      agent.focused and true or false,
      agent.agent_status == "idle",
    }
  end
  table.sort(matches, function(a, b)
    local ra, rb = rank(a), rank(b)
    for k = 1, #ra do
      if ra[k] ~= rb[k] then
        return ra[k]
      end
    end
    return (a.pane_id or "") < (b.pane_id or "")
  end)
  return matches
end

-- One line per agent for the picker.
function M.describe(agent, here)
  local title = agent.terminal_title_stripped or agent.terminal_title or ""
  local where = agent.label or agent.pane_id
  if here and agent.tab_id == here.tab then
    where = where .. ", this tab"
  end
  local line = string.format("%-8s %-8s %s", agent.agent, agent.agent_status or "", where)
  if title ~= "" then
    line = line .. "  " .. title
  end
  return line
end

return M
