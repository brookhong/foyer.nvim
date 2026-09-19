# foyer.nvim

Edit what you are about to type into a Neovim terminal in a real buffer first.

Terminal command lines are a hostile editing environment: no `dw`, no visual
block, no undo, and pasting a multi-line prompt into an LLM CLI is a gamble.
This plugin puts a normal, modifiable buffer in front of the terminal. You edit
with the full power of Vim, press `<CR>`, and the text is sent to the shell.

A foyer is the room you pass through on the way in. Nothing reaches the shell
until you are done with it here.

## Features

- **Edit the current command line** — `edit_input()` lifts whatever you have
  half-typed at the prompt into a floating buffer, then writes it back.
- **Project-scoped named terminals** — one keypress picks a terminal by its
  first character (`z` → zsh, `g` → gdb, `a` → your coding agent). Terminals are
  keyed by project root, spawned on demand, and reused.
- **Per-terminal command history** — persisted across sessions in
  `stdpath('cache')/foyer.json`, scoped per terminal name. `<C-p>`/`<C-n>`
  walk it, and typing first filters the history by substring, with the match
  highlighted.
- **Multi-line prompts** — write a paragraph across many lines, send it as one
  payload. Made for agent CLIs, not just shell one-liners.
- **Command builders** — rewrite a command before it is sent, e.g. append the
  current file and line so an LLM knows the context you are looking at.
- **Prompt navigation** — `[p` / `]p` jump between shell prompts in the terminal
  scrollback.
- **Editable visual selection** — `edit_selection()` opens any visual selection
  in a floating scratch buffer and writes the result back over the selection.

## Requirements

Neovim **0.10+** (uses `vim.fs.root`, `vim.uv`, and `split =` in
`nvim_open_win`).

No other dependencies.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'brookhong/foyer.nvim',
    opts = {
        commands = {
            z = 'zsh',
            g = 'gdb',
        },
    },
}
```

`opts` is passed straight to `setup()`. Calling `setup()` yourself works too.

## Configuration

```lua
require('foyer').setup({
    -- Terminals, keyed by the single character that selects them.
    commands = {
        -- string: the command to run
        z = 'zsh',
        -- table: { command, arguments } -- the first element is also the
        -- display name shown in the window title
        a = { 'opencode', '-c' },
        -- function(project_root, launch_info) -> string | table
        -- resolved every time, so the terminal can depend on the project
        e = function(project_root, launch_info)
            if project_root:find('kernel', 1, true) then
                return { 'bash', '--norc' }
            end
            return 'zsh'
        end,
    },

    -- Rewrite a command before it is sent, keyed by the same character.
    -- function(cmd, launch_info) -> string
    builders = {
        a = function(cmd, launch_info)
            return cmd .. '\n\nCURRENT_FILE: ' .. launch_info.current_file
        end,
    },

    -- Markers used to find the project root that scopes terminals.
    -- Defaults to vim.g.root_markers, then { '.git' }.
    root_markers = { '.git', '.clangd' },
})
```

### `launch_info`

An arbitrary table you pass through `terminal_command()` /
`send_terminal_command()`. It reaches both the `commands` resolver and the
`builders` function untouched, so the plugin does not care what you put in it.
The convention used below is `current_file`, `current_line`, `start_line`,
`end_line`.

## Suggested keymaps

The plugin defines **no global keymaps**; wire up only what you want.

```lua
local foyer = require('foyer')

-- Pick a terminal by its first character and compose a command for it.
vim.keymap.set({ 'n', 'v' }, '<leader>a', function()
    local opts = { win_type = 'sidebar' }
    local mode = vim.fn.mode()
    vim.fn.setreg('a', '')
    opts.launch_info = {
        current_file = vim.fn.expand('%:p'),
        current_line = vim.fn.line('.'),
    }
    if mode == 'v' or mode == 'V' or mode == '\22' then
        opts.launch_info.start_line = vim.fn.line('v')
        opts.launch_info.end_line = vim.fn.line('.')
        vim.cmd('normal! "ay')
        opts.selection = '@'
    end
    foyer.terminal_command(opts)
end, { desc = 'Send command to terminal by first char' })

-- Edit the half-typed command line of the terminal you are in.
vim.api.nvim_create_autocmd('TermOpen', {
    pattern = '*',
    callback = function(ev)
        vim.api.nvim_buf_set_keymap(ev.buf, 't', '<C-x>e',
            '<C-\\><C-n>:lua require("foyer").edit_input()<CR>',
            { noremap = true, silent = true, desc = 'Edit terminal command line' })
    end,
})

-- Edit the current visual selection in a floating buffer.
vim.keymap.set('v', 'E', function()
    foyer.edit_selection()
end, { desc = 'Edit selection in floating window' })
```

## API

| Function | Description |
| --- | --- |
| `setup(opts)` | Merge `opts` into the configuration. |
| `terminal_command(opts)` | Read one character, resolve it against `commands`, spawn the terminal if needed, then open a command buffer for it. |
| `send_terminal_command(term_key, opts)` | Drive a specific terminal directly. `opts.command` sends non-interactively; omit it to open the command buffer. `opts.auto_start = true` spawns the terminal if it is missing. |
| `edit_input()` | Lift the terminal's current command line into a floating buffer. Must be called from a terminal buffer. |
| `edit_selection()` | Open the current visual selection in a floating buffer and write the result back. Must be called from visual mode. |
| `setup_terminal_keymaps(buf)` | Apply the terminal-buffer keymaps and output tracking to a terminal you created yourself. Idempotent. |
| `is_idle(buf, threshold_ms)` | Whether `buf` has produced no output for `threshold_ms` (default 1000). |

### `opts` for `terminal_command` / `send_terminal_command`

| Key | Meaning |
| --- | --- |
| `command` | Send this text instead of opening a command buffer. |
| `interactive` | Force the command buffer open even when `command` is set. |
| `selection` | Set to `'@'` to seed the buffer from register `a`. |
| `win_type` | `'sidebar'` for a right-hand split, otherwise a floating window. |
| `auto_start` | Spawn the terminal if it does not exist yet. |
| `launch_info` | Passed through to the `commands` resolver and `builders`. |

## Mappings inside the plugin's windows

These are buffer-local and currently not configurable.

### Command buffer

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | n | Send the buffer to the terminal |
| `<C-s>` | i | Send the buffer to the terminal |
| `<C-p>` / `<Up>` | n, i | Previous history entry (filtered by what you typed) |
| `<C-n>` / `<Down>` | n, i | Next history entry |
| `<C-x><C-p>` / `<C-x><C-n>` | i | Ordinary insert-mode completion |
| `<Esc>` | n | Close the window if the buffer is empty |
| `<C-c>` | n | Close the window, discarding the draft |
| `<C-x><C-x>` | n | Toggle the window between its default size and full screen |

### Terminal buffer

| Key | Mode | Action |
| --- | --- | --- |
| `[p` / `]p` | n | Jump to the previous / next shell prompt |
| `<C-r>` | n | `cd` the terminal to the project root and re-learn the prompt |
| `x` | n | Toggle the window between its default size and full screen |
| `<CR>` / `<C-c>` / `<Esc>` | n | Close the terminal window |
| `<C-x>i` | t | Paste register `a` at the prompt |
| `<C-x>w` | t | Switch window, or tab when there is only one window |
| `<C-x>c` | t | Close the terminal buffer |

Yanking in a terminal buffer strips trailing whitespace from every line — a
terminal pads its lines to the window width, and that padding is never what you
wanted to copy.

## Highlights

| Group | Default | Used for |
| --- | --- | --- |
| `FoyerMatch` | `bg=#333333 fg=#ff7700 bold` | The filter text matched in the history palette |

Defined with `default = true`, so override it with `vim.api.nvim_set_hl` or from
your colorscheme.

## Notes and limitations

- Register `a` is used as the transport for selections and pastes, and is
  clobbered by `edit_selection()` and the suggested `<leader>a` mapping.
- The plugin reads the command line by sending an erase sequence (`Ctrl-U`, or
  `ESC` for `cmd.exe`) and watching where the cursor lands, with short timers to
  let the shell respond. This is inherently heuristic: a shell with an unusual
  prompt or a very slow response can confuse it.
- Timings, keymaps, and the register are hardcoded. They are deliberately
  opinionated for now; open an issue if you need them configurable.

## License

MIT
