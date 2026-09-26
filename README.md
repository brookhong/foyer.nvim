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
- **Agent-readable context** — the file, line and selection you attached when
  you opened the prompt are published as a small JSON file, one per terminal,
  named by `$FOYER_CONTEXT`. A coding agent reads it when it needs it, instead
  of you pasting the same thing into every message.
- **Prompt navigation** — `[p` / `]p` jump between shell prompts in the terminal
  scrollback.
- **Editable visual selection** — `edit_selection()` opens any visual selection
  in a floating scratch buffer and writes the result back over the selection.

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

    -- Markers used to find the project root that scopes terminals.
    -- Defaults to vim.g.root_markers, then { '.git' }.
    root_markers = { '.git', '.clangd' },
})
```

### `launch_info`

Captured for you: `terminal_command()`, `send_terminal_command()` and
`open_terminal()` read the current file and line, plus `start_line`/`end_line`
when you are in visual mode, before anything in the call can change them. The
table reaches the `commands` resolver untouched and is published verbatim, so a
key of your own travels all the way to the agent:

```lua
foyer.terminal_command({
    launch_info = { current_file = vim.fn.expand('%:p'), ticket = 'JIRA-123' },
})
```

Passing one yourself opts out of the capture entirely. In a buffer with no file
— a terminal, a scratch buffer — the captured table is empty, and an empty table
publishes nothing, so a prompt started from inside the agent's own terminal
leaves the last real context standing instead of overwriting it with `term://…`.

## Suggested keymaps

The plugin defines **no global keymaps**; wire up only what you want.

```lua
local foyer = require('foyer')

-- Pick a terminal by its first character and compose a command for it.
-- From visual mode the selection seeds the prompt; either way the file, line
-- and selected range are captured for the agent. No bookkeeping needed here.
vim.keymap.set({ 'n', 'v' }, '<leader>a', function()
    foyer.terminal_command({ win_type = 'sidebar' })
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
| `toggle_full_size()` | Toggle the current window between full screen and the size it had before: height for a float, width for a split. A neighbouring split keeps its minimum width, so a split may stop a few columns short. |
| `is_idle(buf, threshold_ms)` | Whether `buf` has produced no output for `threshold_ms` (default 1000). |
| `open_terminal(name, command, opts)` | A terminal that is not project-scoped: one reused buffer per `name`, spawned in `opts.cwd` (default `$HOME`), context published and keymaps applied. For an agent you keep one conversation with wherever you are. |

### `opts` for `terminal_command` / `send_terminal_command`

| Key | Meaning |
| --- | --- |
| `command` | Send this text instead of opening a command buffer. |
| `interactive` | Force the command buffer open even when `command` is set. |
| `selection` | `'@'` seeds the buffer from register `a`. Set automatically when you start from visual mode. |
| `win_type` | `'sidebar'` for a right-hand split, otherwise a floating window. |
| `auto_start` | Spawn the terminal if it does not exist yet. |
| `launch_info` | Override the captured context. Passed to the `commands` resolver and published for the agent. |

## Giving an agent your editor context

On every send, the `launch_info` you attached is written as JSON to a file — one
per terminal — and every terminal this plugin spawns gets `$FOYER_CONTEXT` in
its environment naming that file:

```console
$ cat "$FOYER_CONTEXT"
{"captured_at":"2026-09-22T15:59:07+0800","captured_unix":1790063947,
 "launch_info":{"current_file":"/repo/src/main.c","current_line":88,
                "start_line":30,"end_line":36}}
```

That is the whole interface — a file an agent reads when it needs it. What
remains is telling the agent it is there.

`skills/foyer-editor-context/SKILL.md` in this repo does that as an
[agent skill](https://opencode.ai/docs/skills/): a one-line description stays in
the model's context, and the body is loaded only when a request actually points at
your editor. Symlink it into whichever skill directory your CLI scans, keeping
the directory name:

```sh
# from a clone of this repository, or from the plugin's install directory:
# ~/.local/share/nvim/lazy/foyer.nvim with lazy.nvim
src="$PWD/skills/foyer-editor-context/SKILL.md"
for dir in ~/.config/opencode/skills ~/.kiro/skills ~/.claude/skills; do
    [ -d "$dir" ] || continue
    mkdir -p "$dir/foyer-editor-context"
    ln -sf "$src" "$dir/foyer-editor-context/SKILL.md"
done
```

For a CLI with no skill mechanism, the same thing works as an always-loaded rule
(`AGENTS.md`, `CLAUDE.md`, `~/.kiro/steering/*.md`), at the cost of those tokens
on every request:

> When `$FOYER_CONTEXT` is set it names a JSON file holding the file, line and
> selection the user had when they wrote their prompt. Read it with
> `cat "$FOYER_CONTEXT"` before acting on "this file", "here", "this line" or
> "my selection". If it is unset, ask which file is meant.

It is the *attached* context, not a fresh look at your buffers: the file you
meant is the one you were in when you started writing, not the terminal you are
typing in now. Each terminal has its own file, so an agent in one project never
reads a path you attached for another.

Notes:

- Only terminals this plugin opened get a context. `open_terminal()` is the way
  to get one outside the project-scoped `commands`; a terminal you spawn by hand
  is not adopted at all — no context, and none of the terminal-buffer mappings.
- The snapshot ages. `captured_at` and `captured_unix` are in the file so a model
  can notice that "fix this function" was said twenty minutes ago.
- The files live in `stdpath('cache')/foyer/`, one per terminal, and are removed
  on `VimLeavePre`. A terminal closed and reopened keeps the same file, so a long
  session does not litter the directory.
- A send with no `launch_info` leaves the previous context in place rather than
  blanking it, so `:Gb`-style automation does not erase what you attached.
- Publishing never breaks a send: a `launch_info` value that is not
  JSON-serializable, or an unwritable cache directory, warns and sends the
  command anyway.

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
| `<C-x><C-x>` | n | Toggle the window between its previous size and full screen |

### Terminal buffer

The last three are on every terminal this plugin opens. The rest are attached
when a terminal is shown in one of this plugin's own windows, which is something
`open_terminal()` does not do — so a terminal from `open_terminal()` has only
those three.

| Key | Mode | Action |
| --- | --- | --- |
| `[p` / `]p` | n | Jump to the previous / next shell prompt |
| `<C-r>` | n | `cd` the terminal to the project root and re-learn the prompt |
| `x` | n | Toggle the window between its previous size and full screen |
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

- Register `a` is the transport for selections and pastes: sending from visual
  mode yanks into it, and a command buffer seeded from it consumes and clears it.
  `edit_selection()` does the same.
- The plugin reads the command line by sending an erase sequence (`Ctrl-U`, or
  `ESC` for `cmd.exe`) and watching where the cursor lands, with short timers to
  let the shell respond. This is inherently heuristic: a shell with an unusual
  prompt or a very slow response can confuse it.
- Timings, keymaps, and the register are hardcoded.

## License

MIT
