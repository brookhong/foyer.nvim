# foyer.nvim

Work with terminal coding agents from Neovim: one per project, prompts written
in a real buffer, your code sent along, their progress one key away.

Agent CLIs are where a lot of the thinking happens now, and they live in
terminals your editor knows nothing about. Their input boxes have no `dw`, no
undo, and turn a multi-line paste into a gamble; finding the right agent for
this repo, and later checking on it, means hunting through buffers. foyer puts a
normal, modifiable buffer in front of each agent and keeps track of the agents
themselves. Bring your own CLI: Claude Code, opencode, pi, any of them.

A foyer is the room you pass through on the way in. Nothing reaches the agent
until you are done with it here.

## Features

**Reach the right agent**

- **One per project** — a key picks an agent, spawned in the project root on
  first use and reused after, so each repo keeps its own conversation; with a
  CLI's `-c`, it picks that back up after a restart. An entry can be a
  function of the project root, to choose the agent per repo.
- **A side chat** — a `scope = 'global'` agent is one for the whole session,
  reached from any repo, for questions that are not about this one.
- **A picker when you pause** — it lists every key and marks the agents
  already running.

**Ask**

- **Multi-line prompts** — write with the full power of Vim, send it as one
  payload, inserted by the agent rather than sent line by line.
- **Your code in the prompt** — start from a visual selection, in a file or in
  a terminal's output, and it goes along, labelled with where it came from;
  type `@` to mention an open file at a line. It is all in the text the agent
  reads, so any agent understands it with no setup.
- **Prompts worth keeping** — a history per agent, kept across sessions:
  `<Up>` walks it, filtered by what you have typed; `<C-f>` lists your most
  used, after prompts of your own pinned on top, and `/` searches them by
  words.

**Send safely**

- **Waits until the agent is ready** — a prompt sent while it starts is held
  until it can take one, and its Enter waits until the agent shows the text,
  so a question the agent opened on, such as whether to trust the folder, is
  left for you to answer.

**Watch it work**

- **One key to ask and to check** — the key that opens a prompt shows the
  agent's terminal instead while it is still producing output, kept scrolled
  to the latest.
- **Told when it's done** — an agent that reports its state, such as pi,
  tells you when it is done, waiting for you, or failed, in whatever project;
  the tab page it is in gets a mark until you go there, and the picker shows
  what each is doing. A `User FoyerStatus` event lets you take it further.
- **Your keys stay yours** — a terminal foyer shows is in Normal mode, so a
  stray key doesn't reach the agent, and while you do type into it its window
  is tinted.

**Move around**

- `<C-o>` goes between an agent's prompt and its terminal, a half-written
  draft kept for each; `<C-t>` hops to the terminal you used before;
  `jump()` labels every tab, window, buffer and recent file, foyer's agents
  marked among them.

**And also**

- **Shells and debuggers** — zsh, gdb or a REPL gets the same buffer, with a
  history and pinned commands of its own.
- **`edit_selection()`** — rework any visual selection in a floating scratch
  buffer and write it back.
- **Every key configurable** — each key foyer maps in its prompts and
  terminals is set by action, and nothing is mapped globally or in terminal
  mode.

## Requirements

Neovim **0.10+**. No other dependencies.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'brookhong/foyer.nvim',
    opts = {
        commands = {
            a = { 'opencode', '-c' },
            z = 'zsh',
        },
    },
}
```

`opts` is passed straight to `setup()`. Calling `setup()` yourself works too.

## Configuration

A taste; every option, with its default, is in `:help foyer-setup`.

```lua
require('foyer').setup({
    -- Terminals, keyed by the single character that selects them: a command,
    -- { command, arguments }, or a function of the project root returning
    -- either. Its prompt opens in a split beside your code, or a float with
    -- win_type = 'float'; scope = 'global' keeps one for the whole session.
    commands = {
        a = { 'opencode', '-c' },
        F = { 'opencode', '-c --agent counselor', cwd = vim.env.HOME, scope = 'global' },
        z = { 'zsh', win_type = 'float' },
    },

    -- Prompts of your own, pinned on top of a terminal's <C-f> list.
    prompts = {
        a = { 'review the staged changes', 'explain this error' },
    },

    -- Any key foyer maps, by action; false for none. All of them, with
    -- their defaults: :help foyer-setup.
    keys = {
        prompt = { send = { n = '<CR>', i = '<C-j>' } },   -- send with Ctrl-J in insert mode
        terminal = { cd_root = false },                    -- leave <C-r> alone in terminals
    },
})
```

## Suggested keymaps

The plugin defines **no global keymaps**; wire up only what you want.

```lua
local foyer = require('foyer')

-- Pick a terminal by its key and write a prompt for it. From visual mode the
-- prompt carries the selected lines, labelled with their file and range.
vim.keymap.set({ 'n', 'v' }, '<leader>a', foyer.terminal_command,
    { desc = 'Prompt a picked terminal' })

-- Edit the current visual selection in a floating buffer.
vim.keymap.set('v', 'E', foyer.edit_selection, { desc = 'Edit selection' })

-- Any window, foyer's among them, to full screen and back.
vim.keymap.set('n', '<leader>z', foyer.toggle_full_size, { desc = 'Toggle full-size window' })

-- Any tab, window, buffer or recent file, by its label.
vim.keymap.set('n', '<leader>b', foyer.jump, { desc = 'Jump anywhere' })
```

## In use

Press `<leader>a`, then the terminal's key: a prompt opens in a split beside
your code, or a float for a terminal set up with one. Write in it as in any
buffer and press `<CR>` to send; the terminal takes the window, and `<C-o>`
goes back and forth between the two. `<Up>` recalls what you sent before,
`<C-f>` picks from your most used prompts, and `@` in insert mode mentions a
file. Start from a visual selection and it goes along, labelled with its file
and lines.

## Documentation

The full reference — every option, the API, the keys in foyer's windows,
highlights and limitations — is in Neovim: `:help foyer`, or
[doc/foyer.txt](doc/foyer.txt). Why foyer works the way it does is in
[doc/WHY.md](doc/WHY.md) ([中文](doc/WHY.zh-CN.md)).

## License

MIT
