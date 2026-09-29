if vim.g.loaded_tether then
  return
end
vim.g.loaded_tether = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("tether.nvim needs Neovim 0.11 or newer", vim.log.levels.WARN)
  return
end

local function cfg()
  -- vim.g.ai is the name from before the rename to tether.nvim.
  local value = vim.g.tether or vim.g.ai
  if type(value) ~= "table" then
    return {}
  end
  return value
end

vim.api.nvim_create_user_command("TetherStart", function()
  local failures = require("tether").setup(cfg())
  if failures and #failures > 0 then
    vim.notify(table.concat(failures, "\n"), vim.log.levels.WARN)
  end
  vim.notify(table.concat(require("tether").status(), "\n"), vim.log.levels.INFO)
end, { desc = "Attach Neovim to local AI harnesses" })

vim.api.nvim_create_user_command("TetherStop", function()
  require("tether").stop()
  vim.notify("tether.nvim stopped", vim.log.levels.INFO)
end, { desc = "Stop AI harness listeners" })

vim.api.nvim_create_user_command("TetherStatus", function()
  vim.notify(table.concat(require("tether").status(), "\n"), vim.log.levels.INFO)
end, { desc = "Show AI harness attachment status" })

vim.api.nvim_create_user_command("TetherEnv", function()
  print(require("tether").env_script())
end, { desc = "Print environment variables for an external terminal" })

vim.api.nvim_create_user_command("TetherAccept", function()
  local ok, err = require("tether").accept()
  if not ok then
    vim.notify(err or "no diff to accept", vim.log.levels.WARN)
  end
end, { desc = "Accept the AI diff in the current review" })

vim.api.nvim_create_user_command("TetherReject", function()
  local ok, err = require("tether").reject()
  if not ok then
    vim.notify(err or "no diff to reject", vim.log.levels.WARN)
  end
end, { desc = "Reject the AI diff in the current review" })

vim.api.nvim_create_user_command("TetherAcceptHunk", function()
  local ok, err = require("tether").accept_hunk()
  if not ok then
    vim.notify(err or "no hunk to accept", vim.log.levels.WARN)
  end
end, { desc = "Accept the diff hunk under the cursor" })

vim.api.nvim_create_user_command("TetherReviews", function()
  require("tether").reviews()
end, { desc = "Jump to an open AI review" })

vim.api.nvim_create_user_command("TetherFocus", function()
  require("tether").focus()
end, { desc = "Focus the agent pane that last received text" })

vim.api.nvim_create_user_command("TetherAgents", function()
  require("tether").agents()
end, { desc = "List Herdr and tmux agent panes" })

vim.api.nvim_create_user_command("TetherLog", function()
  require("tether").show_log()
end, { desc = "Show recent harness protocol events" })

local function command_range(args)
  if args.range > 0 then
    return { args.line1, args.line2 }
  end
end

vim.api.nvim_create_user_command("TetherSend", function(args)
  require("tether").mention(command_range(args))
end, { range = true, desc = "Add the file, or the lines in the range, to the AI prompt without sending it" })

vim.api.nvim_create_user_command("TetherSendFile", function()
  require("tether").send_file()
end, { desc = "Add the current file to the AI prompt without sending it" })

vim.api.nvim_create_user_command("TetherSendSelection", function(args)
  require("tether").send_selection(command_range(args))
end, { range = true, desc = "Add the selected lines to the AI prompt without sending it" })

vim.api.nvim_create_user_command("TetherSendDiagnostic", function()
  require("tether").send_diagnostic()
end, { desc = "Add the diagnostic under the cursor to the AI prompt without sending it" })

vim.api.nvim_create_user_command("TetherSendNode", function()
  require("tether").send_node()
end, { desc = "Add the function or type under the cursor to the AI prompt without sending it" })

vim.api.nvim_create_user_command("TetherSendPrompt", function()
  require("tether").send_prompt()
end, { desc = "Ask for an instruction and add it with the file or selection" })

vim.api.nvim_create_user_command("TetherSendMany", function(args)
  local range = command_range(args)
  if range then
    require("tether").send_many("selection", range)
  else
    require("tether").send_many("file")
  end
end, { range = true, desc = "Add the file or selection to several agent prompts" })

vim.api.nvim_create_user_command("TetherSendQuickfix", function()
  require("tether").send("quickfix")
end, { desc = "Add the quickfix list to an agent's prompt" })

vim.api.nvim_create_user_command("TetherSendDiff", function(args)
  local how = args.fargs[1]
  if how == "staged" then
    require("tether").send_diff("staged")
  elseif how == "base" then
    require("tether").send_diff("base", args.fargs[2])
  else
    require("tether").send_diff("unstaged")
  end
end, {
  nargs = "*",
  complete = function()
    return { "staged", "unstaged", "base" }
  end,
  desc = "Add a git diff to an agent's prompt",
})

vim.api.nvim_create_user_command("TetherSendTerminal", function(args)
  require("tether").send_terminal(args.args)
end, { nargs = "?", desc = "Add the last lines of a terminal buffer to an agent's prompt" })

vim.api.nvim_create_user_command("TetherSendReferences", function()
  require("tether").send_references()
end, { desc = "Add the LSP definition and references under the cursor" })

vim.api.nvim_create_user_command("TetherSetupHooks", function()
  require("tether").install_hooks()
end, { desc = "Install Claude Code hooks that report edits to Neovim" })

vim.api.nvim_create_user_command("TetherRemoveHooks", function()
  require("tether").remove_hooks()
end, { desc = "Remove the Claude Code hooks tether installed" })

vim.api.nvim_create_user_command("TetherRevertHunk", function()
  require("tether").revert_hunk()
end, { desc = "Revert the agent hunk under the cursor" })

vim.api.nvim_create_user_command("TetherUndoTurn", function()
  require("tether").undo_turn()
end, { desc = "Restore files touched by the latest agent turn" })

vim.api.nvim_create_user_command("TetherWatch", function(args)
  require("tether").watch(args.args ~= "" and args.args or nil)
end, { nargs = "?", complete = "dir", desc = "Watch the project for agent edits" })

vim.api.nvim_create_user_command("TetherSpawn", function(args)
  require("tether").spawn(args.args)
end, { nargs = 1, desc = "Start an agent in a new git worktree" })

vim.api.nvim_create_user_command("TetherWorktreeClean", function()
  require("tether").worktree_clean()
end, { desc = "Remove a tether worktree that has no uncommitted work" })

-- The :Ai* names from before the rename to tether.nvim.
for _, name in ipairs({ "Start", "Stop", "Status", "Env", "Accept", "Reject", "Send", "SendFile", "SendSelection" }) do
  vim.api.nvim_create_user_command("Ai" .. name, function(args)
    local range = args.range > 0 and (args.line1 .. "," .. args.line2) or ""
    vim.cmd(range .. "Tether" .. name)
  end, { range = true, desc = "Old name for :Tether" .. name })
end

local function start()
  if vim.g.tether_disable or vim.g.ai_disable or require("tether").is_running() then
    return
  end
  local failures = require("tether").setup(cfg())
  if failures and #failures > 0 then
    vim.notify("tether: " .. table.concat(failures, "; "), vim.log.levels.WARN)
  end
end

vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = start })
-- Configs that source this file after startup (deferred plugin load) missed VimEnter.
if vim.v.vim_did_enter == 1 then
  start()
end
