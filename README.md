# tether.nvim

[![CI](https://github.com/Rahularya01/tether.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/Rahularya01/tether.nvim/actions/workflows/ci.yml)

Neovim as the IDE for terminal coding agents: Claude Code, Gemini CLI, Codex, and OpenCode.

In VS Code and JetBrains, these agents attach to the editor. They see the file you are in and what you selected, read your diagnostics, and show their edits as a diff you accept or reject. tether.nvim gives Neovim the same connection. The agent keeps its own terminal UI. Neovim is the editor it talks to.

- **Context**: the focused file, cursor, selection, open buffers, and LSP diagnostics.
- **Reviews**: Claude Code and Gemini CLI open proposed edits as a diff tab. `:TetherAccept` writes the file, and `:TetherReject` or closing the tab discards it.
- **Send to the prompt**: `<leader>af` adds the current file to an agent's prompt, and `<leader>ao` adds the selected lines, as `@lua/tether/init.lua#L10-24`. Nothing is submitted until you press Enter in the agent.
- **Agents in panes**: agents running in [Herdr](https://herdr.dev) or tmux panes are found automatically, and a picker asks which one gets the text.

## Requirements

- Neovim 0.11 or newer
- macOS or Linux
- Optional: `tmux` or `herdr` for sending to agents in other panes

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Rahularya01/tether.nvim",
  lazy = false,
  opts = {},
}
```

`vim.pack` (Neovim 0.12):

```lua
vim.pack.add({ "https://github.com/Rahularya01/tether.nvim" })
```

The plugin starts on its own. `setup()` is only needed to change options, and `vim.g.tether_disable = true` stops it from starting.

## Use

Run the agent from a terminal in the project. `:terminal` inside Neovim is the simplest, because new terminals get the environment the agents look for.

| Agent | How it attaches |
| --- | --- |
| Claude Code | Connects on its own from Neovim's terminal. From another terminal in the project, run `/ide`. |
| Gemini CLI | Connects when started from Neovim's terminal. It identifies the editor by its parent processes. |
| Codex | From any terminal on this machine, run `/ide` in the TUI. |
| OpenCode | tether.nvim finds a running OpenCode server and adds text to its prompt. |

### Sending a file or selection

| Keys | Command | Sends |
| --- | --- | --- |
| `<leader>af` | `:TetherSendFile` | the current file |
| `<leader>ao` (visual) | `:'<,'>TetherSendSelection` | the selected lines |
| `<leader>ao` (normal) | `:TetherSendSelection` | the last visual selection |
| `<leader>ad` | `:TetherSendDiagnostic` | the diagnostic under the cursor, with its message |
| `<leader>an` | `:TetherSendNode` | the function or type around the cursor |
| `<leader>aj` | `:TetherFocus` | jumps to the pane that last received text |
| | `:TetherSend` | the lines in a range, or the file without one |

Where the text goes:

1. **Agents in Herdr or tmux panes.** A picker lists them, and the agent you used last is first, so Enter repeats it. When Neovim runs inside Herdr or tmux, only agents in the same Herdr workspace or tmux session are listed. Outside both, agents whose directory is the current project are listed. Claude gets `@path#L10-24`. Other agents get `path:10-24`.
2. **Claude Code over its IDE connection**, as an at-mention.
3. **OpenCode**, appended to its prompt.

A notification says where the text went. A path with spaces is sent as `@"my file.lua#L3"`, which Claude Code reads as one path. A buffer that is not a file on disk sends its text instead of a path. Claude Code's at-mention needs a path, so that text goes to a pane agent or to OpenCode.

### Reviewing edits

When Claude Code or Gemini CLI proposes an edit, a tab opens with the current file next to the proposal. You can edit the proposal before accepting.

- `ga` or `:TetherAccept` writes it. If the file has unsaved changes, it refuses rather than overwrite them. The text reported back to the agent is whatever is on disk after the write, including format-on-save.
- `gh` or `:TetherAcceptHunk` writes only the change under the cursor and leaves the rest of the review open. The last hunk finishes the review.
- `gr` or `:TetherReject` discards it. Closing the tab does the same. Hunks already written stay on disk.
- `ga`, `gh`, and `gr` are buffer-local on the proposal. `:TetherStatus` lists a review that is still open, and `:TetherReviews` jumps to one.
- A second proposal for a file that already has a review waits, and opens when the current one finishes.
- Answering in Claude's terminal closes the tab for you.

### Other commands

- `:TetherStatus` shows each adapter: ports, sockets, connected clients, and agents found.
- `:TetherLog` shows recent handshakes, tool calls, and review events.
- `:TetherFocus` jumps to the last Herdr or tmux agent pane. Set `focus = true` to do that after every send.
- The last pane agent is remembered across Neovim restarts.
- `User TetherClient` fires with `{ adapter, clients }` when a harness connects or drops. `User TetherReview` fires with `{ action, path }` when a review opens, a hunk is accepted, or the review is accepted or rejected.
- `:TetherEnv` prints export lines for a terminal opened before the plugin started.
- `:TetherStart` and `:TetherStop` start and stop everything.
- `:checkhealth tether`

## Configuration

Defaults:

```lua
require("tether").setup({
  adapters = { "claude", "gemini", "codex", "opencode", "herdr", "tmux" },
  -- "always" asks which pane agent gets the text, even when there is only one.
  -- "auto" asks only when there are several.
  pick = "always",
  -- When true, a send also focuses that pane.
  focus = false,
  -- Set one to false to skip it, or keymaps = false for none.
  keymaps = {
    send_file = "<leader>af",
    send_selection = "<leader>ao",
    send_diagnostic = "<leader>ad",
    send_node = "<leader>an",
    focus = "<leader>aj",
  },
  -- Buffer-local maps on the proposal. Set one to false to skip it, or false for none.
  review_keymaps = { accept = "ga", reject = "gr", hunk = "gh" },
  -- Gemini CLI decides workspace trust itself. Set true or false to override it.
  gemini = { trusted = nil },
  -- Extra tmux process names to treat as agents. A list, or { basename = "label" }.
  tmux = { agents = {} },
})
```

The same table can go in `vim.g.tether` instead of a `setup()` call.

## How it works

There is no shared protocol. Each agent discovers the editor its own way, and tether.nvim has an adapter for each:

| Adapter | How it is found | What it provides |
| --- | --- | --- |
| Claude Code | `~/.claude/ide/<port>.lock` and `CLAUDE_CODE_SSE_PORT` | WebSocket MCP server: selection, buffers, diagnostics, blocking diff |
| Gemini CLI | `$TMPDIR/gemini/ide/gemini-ide-server-<pid>-<port>.json` | HTTP MCP server: context over SSE, diff with async result |
| Codex | `$CODEX_HOME/ipc/ipc.sock` and `$TMPDIR/codex-ipc/ipc-<uid>.sock` | Unix socket: active file, selection, open tabs |
| OpenCode | `server.json` in OpenCode's state directory | Client of the running server: appends to the prompt |
| Herdr | `herdr agent list` | Agent panes; text typed with `herdr pane send-text` |
| tmux | `tmux list-panes` and the processes under each pane | The same agent CLIs Herdr detects, plus aider, crush, and goose, plus any names in `tmux.agents`; text typed with `tmux send-keys -l` |

Listeners bind to `127.0.0.1`, and Claude Code and Gemini CLI must present the per-session token from the discovery file. Discovery files are written mode `0600`. If VS Code or another Neovim already serves the Codex socket, tether.nvim leaves it alone and takes it over once that editor exits.

This is the companion model, where the agent keeps its own UI. It is different from the Agent Client Protocol, where the editor is the chat window and starts the agent.

## Development

```sh
nvim --headless --noplugin --clean -u tests/minimal.vim   # tests
stylua --check lua plugin tests                            # formatting
```

The tmux tests start a private tmux server and are skipped when tmux is not installed.

## License

[MIT](LICENSE)
