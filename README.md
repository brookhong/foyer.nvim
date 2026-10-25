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
  keyed by project root, spawned on demand, and reused; a `scope = 'global'`
  one is kept for the whole session instead.
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
        -- a table entry may also name cwd and scope: 'global' keeps one
        -- terminal for the whole session instead of one per project root,
        -- and its prompt takes the current window instead of a float or
        -- sidebar
        F = { 'opencode', '-c --agent counselor',
              cwd = vim.env.HOME, scope = 'global' },
    },

    -- Markers used to find the project root that scopes terminals.
    -- Defaults to vim.g.root_markers, then { '.git' }.
    root_markers = { '.git', '.clangd' },

    -- Wrap a multi-line send in bracketed paste. Turn it off for a terminal
    -- program that does not understand the escapes. Defaults to true.
    bracketed_paste = true,

    -- Milliseconds terminal_command() waits for a terminal key before showing
    -- the picker, so a mapping typed straight through never flashes it.
    -- Defaults to 500.
    picker_delay = 500,

    -- A selection is sent with its lines, up to this many; a longer one is
    -- sent as its location alone. 0 never sends the lines. Defaults to 40.
    selection_max_lines = 40,

    -- `@` in a terminal's prompt lists the open files to mention. Defaults to
    -- true.
    mention = true,

    -- Keys that clear the receiver's input line and its screen, keyed by the
    -- program receiving them. Defaults to { Ctrl-U, Ctrl-L }. A program that
    -- binds either key to something of its own needs its own -- see below.
    send_prefix = {
        pi = { vim.keycode('<C-u>'), '' },
    },
})
```

### `send_prefix`

Before the text, foyer clears whatever the receiver already has on its input
line, and clears the screen with it: `Ctrl-U` then `Ctrl-L`, or `{ ESC, '' }`
for `cmd.exe`. Those are a shell's bindings, and a program with its own UI is
free to bind them to anything — `pi` erases the line on `Ctrl-U` as a shell
does, but opens its model picker on `Ctrl-L`, which then swallows the prompt
arriving behind it. So name the keys the program does understand, and `''` for
the rest:

```lua
send_prefix = {
    -- { clear input, clear screen }
    pi = { vim.keycode('<C-u>'), '' },
    claude = { '', '' },
}
```

A send is prefixed with both, the input key first. The input key alone is also
what `edit_input()` sends to find the command line, so a program given `''`
there leaves it nothing to read — reading back a prompt is a shell feature
either way.

The key names the **program**, not the `commands` key that selected it: one
such key stands for whatever a project wants behind it, so `a` is free to be a
different agent in every repo. The whole command line as spawned, the program
alone and its basename are all tried, so `pi --yolo`, `/opt/pi/bin/pi` and `pi`
are all usable keys — the basename covers every path and argument spelling at
once. A program with no key of its own keeps the defaults.

### `launch_info`

Captured for you: `terminal_command()` and `send_terminal_command()` read the
current file and line, plus `start_line`/`end_line`
when you are in visual mode, before anything in the call can change them. The
table reaches the `commands` resolver untouched and is published verbatim, so a
key of your own travels all the way to the agent:

```lua
foyer.terminal_command({
    launch_info = {
        project_root = '/repo',
        current_file = 'src/main.c',
        ticket = 'JIRA-123',
    },
})
```

`current_file` is relative to `project_root`, which is captured alongside it —
`src/main.c`, the name the project uses, not a path that only means something on
your machine. The two always travel together: when there is no project root to
name the file against, the `project_root` key is absent and `current_file` is
absolute instead.

Passing one yourself opts out of the capture entirely. In a buffer with no file
— a terminal, a scratch buffer — the captured table is empty, and an empty table
publishes nothing, so a prompt started from inside the agent's own terminal
leaves the last real context standing instead of overwriting it with `term://…`.

## Suggested keymaps

The plugin defines **no global keymaps**; wire up only what you want.

```lua
local foyer = require('foyer')

-- Pick a terminal by its first character and compose a command for it.
-- From visual mode the prompt names the selected range with `file:start-end`,
-- appended as you send; either way the file, line and range are captured for
-- the agent.
vim.keymap.set({ 'n', 'v' }, '<leader>a', function()
    foyer.terminal_command({ win_type = 'sidebar' })
end, { desc = 'Send command to a picked terminal' })

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
| `terminal_command(opts)` | Pick a terminal by its `commands` key, spawn it if needed, then open a command buffer for it. A popup lists the keys if none is typed within `picker_delay`; `<Esc>` cancels. |
| `send_terminal_command(term_key, opts)` | Drive a specific terminal directly. `opts.command` sends non-interactively; omit it to open the command buffer. `opts.auto_start = true` spawns the terminal if it is missing. |
| `edit_input()` | Lift the terminal's current command line into a floating buffer. Must be called from a terminal buffer. |
| `edit_selection()` | Open the current visual selection in a floating buffer and write the result back. Must be called from visual mode. |
| `toggle_full_size()` | Toggle the current window between full screen and the size it had before: height for a float, width for a split. A neighbouring split keeps its minimum width, so a split may stop a few columns short. |
| `tab_switch()` | Move to the next window worth looking at: `CTRL-W w` order, wrapping around, skipping floats and windows a full-screen neighbour has squeezed to `'winminwidth'`/`'winminheight'`. With nothing left to step into, switches to the alternate buffer (`CTRL-^`) instead. A maximised diff pane restores the squeezed pane and steps into it. |
| `is_idle(buf, threshold_ms)` | Whether `buf` has produced no output for `threshold_ms` (default 1000). |

### `opts` for `terminal_command` / `send_terminal_command`

| Key | Meaning |
| --- | --- |
| `command` | Send this text instead of opening a command buffer. |
| `interactive` | Force the command buffer open even when `command` is set; `command` then seeds the buffer. |
| `selection` | Text appended to the prompt as it is sent. Set for you when the send starts in visual mode, see below. |
| `win_type` | `'sidebar'` for a right-hand split, otherwise a floating window. Ignored for a `scope = 'global'` terminal, whose prompt takes the current window. |
| `auto_start` | Spawn the terminal if it does not exist yet. |
| `launch_info` | Override the captured context. Passed to the `commands` resolver and published for the agent. |

`terminal_command` also takes `key`, the `commands` key to drive instead of
asking for one, and `switch`, which shows the terminal in the current window
rather than opening a prompt and returns its buffer.

A `scope = 'global'` terminal is a conversation of its own rather than a helper
to the code beside it, so its prompt does not open in a float or a sidebar: it
takes the window you are in, and the terminal takes it in turn once you send.
`<CR>`, `<C-c>` or `<Esc>` there hand the window back to the buffer it was
showing, so your layout is never touched:

```lua
vim.keymap.set({ 'n', 'v' }, '<leader>af', function()
    foyer.terminal_command({ key = 'F' })
end, { desc = 'opencode terminal' })
```

Starting from visual mode attaches the selection. The command buffer opens empty
and in insert mode, with the selection's place shown in its title —
`src/main.c:30-36` — and the selection joins below the prompt, after a blank
line, as it is sent:

````
what does this do?

Selected in my editor: /repo/src/main.c, lines 30-36
```c
…the selected lines, as the buffer has them…
```
````

The lines go with it because a bare `src/main.c:30` reads to an agent as a
location, and it reads the lines around one and guesses which was meant; and
the numbers are the buffer's, while the agent reads the file on disk, which
unsaved edits can put out of step — the label says so when they have. The path
is absolute, so it resolves wherever the agent was started. A selection longer
than `selection_max_lines` is sent as the label alone.

None of it sits in the command buffer, so the line stays yours to edit and to
walk history with, and history remembers the prompt without a selection that
will not be true next time. Type nothing and nothing is sent; a selection alone
asks the agent nothing. A `selection` you pass yourself is appended as given.

A sidebar outlives the send that opened it, so sending again aims at the window
already there rather than splitting another one: a draft still in it is yours
and stays — only an empty one takes a seeded `command` — with the new selection
replacing whatever the title advertised before, and the terminal left in there
by the last send gives the window back to a fresh prompt. A floating window is
transient and is simply opened again.

A terminal still producing output keeps the window instead of giving it to a
prompt (see `is_idle`); there is no prompt for a selection to ride on then, so
it is dropped and said so with `vim.notify`.

## Giving an agent your editor context

On every send, the `launch_info` you attached is written as JSON to a file — one
per terminal — and every terminal this plugin spawns gets `$FOYER_CONTEXT` in
its environment naming that file:

```console
$ cat "$FOYER_CONTEXT"
{"captured_at":"2026-09-22T15:59:07+0800","captured_unix":1790063947,
 "launch_info":{"project_root":"/repo","current_file":"src/main.c",
                "current_line":88,"start_line":30,"end_line":36}}
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

- Only terminals this plugin opened get a context. A `scope = 'global'`
  terminal has one file for the session, since it is the same conversation
  everywhere; a terminal you spawn by hand is not adopted at all — no context,
  and none of the terminal-buffer mappings.
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

A buffer with something to say already — a lifted command line, a seeded
`command`, a prompt that is going to carry a `selection` — starts in insert mode
at the end of its text. One opened with nothing to say starts in normal mode,
where `<Up>` walks the history.

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | n | Send the buffer to the terminal |
| `<C-s>` | i | Send the buffer to the terminal |
| `<C-p>` / `<Up>` | n | Previous history entry |
| `<C-n>` / `<Down>` | n | Next history entry |
| `<C-p>` / `<C-n>` | i | Previous / next history entry; with a menu open, move through it |
| `@` | i | Mention an open file, see below |
| `<C-x><C-p>` / `<C-x><C-n>` | i | Ordinary insert-mode completion |
| `<Esc>` | n | Close the window if the buffer is empty |
| `<C-c>` | n | Close the window, discarding the draft |
| `<C-x><C-x>` | n | Toggle the window between its previous size and full screen |

History is filtered by what you have typed: with a draft in the buffer, only the
entries containing it are walked, and the match is highlighted.

Once a prompt is sent, the terminal takes its window, and `<C-o>` from there
comes back to the prompt emptied, with the selection it carried gone: a
follow-up written there goes alone. What was sent is in history, one `<Up>`
away.

#### `@` mentions

In the prompt for one of your `commands`, `@` at the start of a word lists the
open files: the one you opened the prompt from first, at your cursor line, then
the rest by when you last used them, each at its last change, then the files
you used recently (`v:oldfiles`) in the same way. The menu shows ten at a time;
typing after the `@` searches all of them by name, so a file further down is
found as you type. While it is open:

| Key | Puts in |
| --- | --- |
| `<CR>` | `@src/parser.c:120` — the path as the agent resolves it: from the directory it was started in, or absolute for a `scope = 'global'` one |
| `<C-l>` | The selection block a visual selection sends — label, then the lines as your buffer has them. The file's last visual selection if it holds that line, else the line alone |
| `<Esc>` | Nothing: the `@` stays as typed |

An `@` inside a word (`user@host`) is just an `@`, and so is one with no open
file to offer. The prompt for `edit_input()` has no mentions: it is a shell's
command line. A recent file is read only when it comes into the menu, without
its autocommands — no filetype plugin or language server starts for it — and
let go again when the menu closes. A block put in with `<C-l>` is left out of
history, which keeps the words around it.

`edit_selection()`'s window is text you are editing rather than a prompt: it
keeps `<CR>`, `<C-s>`, `<Esc>`, `<C-c>` and `<C-x><C-x>`, has no history, and
always starts in normal mode.

### Terminal buffer

The last three are on every terminal this plugin opens. The rest are attached
when a terminal is shown in one of this plugin's own windows, which `switch`
does not do — it hands the terminal your window, so a terminal opened that way
has only those three.

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
| `FoyerBackdrop` | `bg=#000000` | The veil dimming the editor behind the terminal picker (needs `termguicolors`) |

Defined with `default = true`, so override it with `vim.api.nvim_set_hl` or from
your colorscheme.

## Notes and limitations

- A send containing a newline — a multi-line draft, or any prompt with a
  `selection` under it — is wrapped in bracketed paste, so the
  receiver inserts the newline instead of reading it as Enter and running the
  first line alone. What the receiver then does with a multi-line input is its
  own business: an agent takes it as one prompt, a shell lands it on one command
  line and still runs each of its lines in turn. A terminal program that does
  not understand bracketed paste will show the `[200~` escapes as text — turn
  `bracketed_paste` off for it. Single-line sends are never wrapped.
- `edit_selection()` goes through register `a`: the selection is yanked into it
  on the way in, and the edited text on the way back out. `<C-x>i` in a terminal
  pastes register `a`, whatever put it there.
- The plugin reads the command line by sending the erase sequence (`Ctrl-U`, or
  `ESC` for `cmd.exe`, or whatever `send_prefix` names) and watching where the
  cursor lands, with short timers to let the shell respond. This is inherently
  heuristic: a shell with an unusual prompt or a very slow response can confuse
  it.
- Timings, keymaps, and the register are hardcoded.

## License

MIT
