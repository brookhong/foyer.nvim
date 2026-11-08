# foyer.nvim

Edit what you are about to type into a Neovim terminal in a real buffer first.

Terminal command lines are a hostile editing environment: no `dw`, no visual
block, no undo, and pasting a multi-line prompt into an LLM CLI is a gamble.
This plugin puts a normal, modifiable buffer in front of the terminal. You edit
with the full power of Vim, press `<CR>`, and the text is sent to the shell.

A foyer is the room you pass through on the way in. Nothing reaches the shell
until you are done with it here.

## Features

- **Project-scoped named terminals** — one keypress picks a terminal by its
  first character (`z` → zsh, `g` → gdb, `a` → your coding agent). Terminals are
  keyed by project root, spawned on demand, and reused; a `scope = 'global'`
  one is kept for the whole session instead. `<C-t>` in one goes back to the
  one you used before it.
- **Per-terminal command history** — persisted across sessions, scoped per
  terminal. `<Up>`/`<Down>` walk it, filtered by what you have typed.
  `<C-f>` lists your most used prompts, ranked by frequency and recency, after
  prompts of your own pinned on top, and `/` there searches all of them by
  words.
- **Multi-line prompts** — write a paragraph across many lines, send it as one
  payload. Made for agent CLIs, not just shell one-liners.
- **Editor context in the prompt** — start from a visual selection and it goes
  with the prompt, labelled with its file and lines; type `@` to mention an open
  file at a line, the one you came from first. All of it is in the text the
  agent reads, so any agent understands it with no setup.
- **Editable visual selection** — `edit_selection()` opens any visual selection
  in a floating scratch buffer and writes the result back over the selection.
- **Jump anywhere** — `jump()` labels every tab, window, buffer and recent file;
  type a label to go there.
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
            z = 'zsh',
            a = { 'opencode', '-c' },
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
        z = { 'zsh', win_type = 'float' },
        a = { 'opencode', '-c' },
        F = { 'opencode', '-c --agent counselor', cwd = vim.env.HOME, scope = 'global' },
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
