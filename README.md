# ryuux05 Neovim config

Neovim config with AI agent tools built in: live reload of agent edits, ask/edit with Claude or Codex on any line, PR review, architecture notes and line memos.

## Install

Requirements:

- Neovim 0.12+ (nvim-treesitter `main` needs it). [bob](https://github.com/MordechaiHadad/bob) works: `bob use stable`
- git, a C compiler (`xcode-select --install`), ripgrep, Node/npm, Python 3 with sqlite3
- tree-sitter CLI 0.26.1+ (`tree-sitter-cli`, not the `tree-sitter` library formula)
- GitHub CLI, logged in (for PR review)
- Claude Code and/or Codex CLI, logged in (for the AI features)
- Arc browser (markdown preview opens in Arc)

```sh
brew install bob git ripgrep node tree-sitter-cli gh
bob use stable
gh auth login

npm install -g @anthropic-ai/claude-code @openai/codex
claude        # log in once
codex login

git clone https://github.com/ryuux05/neovim ~/.config/nvim
nvim
```

Plugins are managed by [lazy.nvim](https://github.com/folke/lazy.nvim). The first launch installs lazy.nvim and every plugin at the versions in `lazy-lock.json`; treesitter parsers build in the background. `:Lazy` opens the plugin manager (`U` update, `R` restore to the lockfile). Commit `lazy-lock.json` after updating so other machines get the same versions.

Pick the default agent for this machine (stored per machine, not in the repo):

```vim
:AgentDefault claude
```

## Features

Leader is `Space`.

### Agent change tracking

Files reload live when an AI agent edits them, even in hidden buffers. Changed lines get a soft blue background with an `Agent` tag. Changes from `git checkout` / `git pull` aren't marked.

| Key | Action |
|---|---|
| `<leader>n` | Next agent change in this file (wraps) |
| `<leader>pa` | Telescope list of agent-changed files |
| `<leader>cc` / `:AgentClear` | Clear agent highlights |

### Ask / edit with Claude or Codex

Works in any file and in PR review diffs.

| Key | Action |
|---|---|
| `Enter` / `V` + `Enter` | Ask about the line or selection (opens the session if the line already has one) |
| `Shift+Enter` | Always start a new question |
| `q` on a marked line | Delete that session |
| `ga` / `:AgentPanel` | Open the AI panel |

In the prompt: `Tab` switches Claude/Codex (new sessions only), `Ctrl+E` edit mode, `Ctrl+A` ask mode, `Enter` send, `Esc` cancel. Edit mode lets the agent change the file; its changes get the blue Agent highlight.

Asked lines get an `AI` marker with the session status. Answers go to a small panel that keeps focus in your code. Its title shows the session under the cursor, e.g. ` AI #2/3 · lua/ryuux05/ask.lua:120 · Claude · done `.

Panel keys: `Enter`/`i` reply, `]]`/`[[` next/previous session, `m` maximize, `q` delete session, `/` search history, `r` recent, `Esc` hide. A maximized panel stays hidden while the agent works; bring it back with `ga`.

Sessions are saved and come back after restart. `:AgentSearch <words>` searches past conversations. Details: `:h agent-panel`.

### PR review

```sh
nvim https://github.com/<owner>/<repo>/pull/<n>
```

or `:Review <url>` inside Neovim. A panel lists only changed files; click or `Enter` opens one. Diffs show base on the left and the PR on the right in red/green. Unchanged code is folded; `Enter` expands it. Ask/edit works on diff lines too.

Octo shortcuts: `<leader>op` PRs, `<leader>or` review requests, `<leader>oi` issues, `<leader>on` notifications, `<leader>ov` start review.

### Architecture mode

`:Arch [file]` opens a markdown note (default `docs/architecture.md`, or the current markdown file) in a new tab, docks the AI panel on the right, and opens a rendered preview in Arc. Mark lines and ask the agent about them as usual.

### Line memos

| Key | Action |
|---|---|
| `<leader>b` | Memo the line with an optional note; on a memo line, remove it |
| `V` + `<leader>b` | Memo the selected lines |
| `Ctrl+B` | Telescope list of this project's memos |

Memos show as a light green highlighter. They follow the lines through edits, agent changes and restarts. Stored in `~/.local/state/nvim/memos.json`.

### Everyday keys

| Key | Action |
|---|---|
| `<leader>pf` / `Ctrl+P` | Find files / git files |
| `<leader>ps` | Grep |
| `<leader>a`, `Ctrl+E` | Harpoon add file, menu |
| `Ctrl+H/T/N/S` | Harpoon files 1–4 |
| `<leader>u` | Undotree (persistent undo) |
| `gd`, `gr`, `K` | LSP definition, references, hover |
| `<leader>rn`, `<leader>ca`, `<leader>f` | Rename, code action, format |
| `[d`, `]d`, `<leader>vd` | Diagnostics |
| `<leader>gs` | Git status (fugitive) |
| `<leader>ga`, `<leader>gc`, `<leader>gp`, `<leader>gP` | Git add all, signed commit, push, all three |
| `<leader>mp`, `<leader>ms`, `<leader>mt` | Markdown preview start, stop, toggle |

LSP servers installed by Mason: `gopls`, `rust_analyzer`, `lua_ls`.

## Tests

```sh
python3 tests/ask_sessions.py
python3 tests/test_ask_store.py
python3 tests/agent_live_updates.py
nvim --headless -u NONE -i NONE -l tests/agent_navigation.lua
```
