local M = {}
local layout = require('foyer.layout')
local window = require('foyer.window')
local clear_foyer_matches = window.clear_foyer_matches
local dismiss = window.dismiss
local set_window_title = window.set_window_title
local insert_at_end = window.insert_at_end
local create_window = window.create_window
local config = {
    commands = {}, root_markers = nil, bracketed_paste = true, send_prefix = {},
    picker_delay = 500, selection_max_lines = 40,
}
local last_output_time = {}

-- Directory markers locating the project root that scopes terminals.
local function project_root(fallback)
    local markers = config.root_markers or vim.g.root_markers or { '.git' }
    return vim.fs.root(0, markers) or fallback
end

function M.is_idle(buf, threshold_ms)
    threshold_ms = threshold_ms or 1000
    local t = last_output_time[buf]
    return t == nil or (vim.uv.now() - t) > threshold_ms
end

function M.setup(opts)
    -- Merged into the table itself rather than replacing it, so whatever holds
    -- a reference to `config` sees what the user set, whenever it looked.
    local merged = vim.tbl_deep_extend('force', config, opts or {})
    for k, v in pairs(merged) do
        config[k] = v
    end
end

local context_dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'foyer')
local published = {}

local function in_visual()
    local mode = vim.fn.mode()
    return mode == 'v' or mode == 'V' or mode == '\22' -- char, line, block
end

-- A draft of nothing but whitespace is a draft the user never wrote: it closes
-- a window, it is not sent, and it is not remembered.
local function is_blank(s)
    return not s:find('%S')
end

local function buffer_text(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

-- {path} stated the way the project talks about it, or nil when it does not sit
-- under {root} -- then no such name exists and only the absolute one is true.
local function relative_to(root, path)
    local prefix = root:gsub('/$', '') .. '/'
    local head = path:sub(1, #prefix)
    -- A Windows path can differ in case without differing: the buffer name and
    -- vim.fs.root() disagree about the drive letter often enough to matter.
    if jit.os == 'Windows' then
        head, prefix = head:lower(), prefix:lower()
    end
    if head ~= prefix then return nil end
    return path:sub(#prefix + 1)
end

-- What the user is looking at, in the conventional launch_info shape.
local function launch_info()
    -- A terminal or scratch buffer has no file worth reporting: its name would
    -- be a term:// URI. The empty table publishes nothing, so the last real
    -- context stays in place.
    local name = vim.api.nvim_buf_get_name(0)
    if vim.bo.buftype ~= '' or name == '' then return {} end
    -- The buffer name rather than expand('%:p'): that one leaves a symlinked
    -- path unresolved while vim.fs.root() resolves it, so the two would never
    -- match. normalize() then settles the separators, which disagree on
    -- Windows.
    local path = vim.fs.normalize(name)
    local root = project_root(nil)
    root = root and vim.fs.normalize(root)
    local relative = root and relative_to(root, path)
    local info = {
        -- The pair travels together or not at all: a root the file cannot be
        -- named against is a root nobody can resolve the name with.
        project_root = relative and root or nil,
        current_file = relative or path,
        current_line = vim.fn.line('.'),
    }
    if in_visual() then
        -- line('v') is the anchor, which sits below the cursor in a selection
        -- dragged upward; a reversed range is no use to whoever reads it.
        local anchor, cursor = vim.fn.line('v'), vim.fn.line('.')
        info.start_line = math.min(anchor, cursor)
        info.end_line = math.max(anchor, cursor)
    end
    return info
end

-- The selected range in the project's own terms, `src/main.c:30-36`: short
-- enough for a window title, which is where the user reads it.
local function selection_ref(info)
    if not (info.current_file and info.start_line) then return nil end
    if info.end_line == info.start_line then
        return ('%s:%d'):format(info.current_file, info.start_line)
    end
    return ('%s:%d-%d'):format(info.current_file, info.start_line, info.end_line)
end

-- The selection as an agent is to read it: said in words, from a path that
-- resolves wherever the agent was started, with the lines themselves below.
--
-- A bare `path:30` reads as a location -- a compiler error, a grep hit -- and
-- an agent reads a window of lines around one, then has to guess which of them
-- was meant. And the numbers are the buffer's, while the agent reads the file
-- on disk: unsaved edits above the selection point it at other lines
-- altogether. The text settles both. Past `selection_max_lines` it is left
-- out, so a selection the size of a file is not pasted whole; the label alone
-- still says where to look.
local function selection_block(sel)
    local info = sel.info
    local file = info.current_file
    if info.project_root then file = vim.fs.joinpath(info.project_root, file) end
    local where = info.end_line == info.start_line
        and ('line %d'):format(info.start_line)
        or ('lines %d-%d'):format(info.start_line, info.end_line)
    local label = ('Selected in my editor: %s, %s'):format(file, where)
    -- Said outright, so an agent that does open the file is not misled by it.
    if sel.modified then label = label .. ' (unsaved; the file on disk differs)' end

    local max = config.selection_max_lines or 0
    if max <= 0 or #sel.lines > max then return label end
    local text = table.concat(sel.lines, '\n')
    -- A fence longer than any run of backticks in the text, so code that
    -- holds a fence of its own cannot close this one early.
    local fence = '```'
    while text:find(fence, 1, true) do fence = fence .. '`' end
    return ('%s\n%s%s\n%s\n%s'):format(label, fence, sel.filetype or '', text, fence)
end

-- What the user typed, with the selection below it after a blank line. It
-- joins here, as the prompt is sent, and never sits in the command buffer: the
-- line stays the user's to edit and to navigate history with, and history
-- records the prompt without a selection that will not be true next time. A
-- blank prompt stays blank, so the send is dropped: a selection alone asks the
-- agent nothing.
local function with_selection(cmd, ref)
    if not ref or is_blank(cmd) then return cmd end
    return cmd .. '\n\n' .. ref
end

local function escape_key(s)
    return (tostring(s):gsub('[^%w%-_]', function(c) return ('%%%02x'):format(c:byte()) end))
end

-- Keyed by the terminal's identity, so the same terminal reopened reuses its
-- file. The pid separates two Neovim instances.
local function context_path(key)
    return vim.fs.joinpath(context_dir, ('%d-%s.json'):format(vim.fn.getpid(), key))
end

-- The root is hashed rather than flattened: a deep path would otherwise make a
-- filename longer than the filesystem allows. A global terminal has no root to
-- hash, so its empty bucket gives it one file for the session.
local function term_context_path(root, term_key)
    return context_path(('t-%s-%s'):format(vim.fn.sha256(root):sub(1, 8), escape_key(term_key)))
end

-- Write a terminal's context. An empty info means "keep the context this
-- terminal already has". Publishing is a side channel, so it may not take the
-- send down: info is the caller's table and vim.json.encode can refuse it.
local function publish(path, info)
    info = info or launch_info()
    if type(info) ~= 'table' or vim.tbl_isempty(info) then return path end
    local ok, err = pcall(function()
        vim.fn.mkdir(context_dir, 'p')
        local json = vim.json.encode({
            captured_at = os.date('%Y-%m-%dT%H:%M:%S%z'),
            captured_unix = os.time(),
            launch_info = info,
        })
        assert(vim.fn.writefile({ json }, path) == 0, 'could not write ' .. path)
    end)
    if ok then
        published[path] = true
    else
        -- The traceback prefix is noise to whoever set launch_info.
        local reason = tostring(err):gsub('^.-:%d+: ', '')
        vim.notify('foyer.nvim: could not publish context: ' .. reason, vim.log.levels.WARN)
    end
    return path
end

-- Name the context file in the environment of a terminal about to be spawned.
-- A job reads its environment once, at startup, so only the spawning paths may
-- set this; cleared on the next tick so it cannot leak to unrelated jobs.
local function export_context(path)
    vim.env.FOYER_CONTEXT = path
    vim.schedule(function() vim.env.FOYER_CONTEXT = nil end)
end

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('foyer_context', { clear = true }),
    callback = function()
        -- These describe a live editing session; leaving them behind would let
        -- an agent read a cursor position from a Neovim that no longer exists.
        for path in pairs(published) do
            os.remove(path)
        end
    end,
})

-- The opts whose selection capture() wrote, rather than the caller: only
-- those may be renamed for the terminal they end up going to.
local captured_selection = setmetatable({}, { __mode = 'k' })

-- What a send appends below the prompt: the captured selection with its text,
-- or a `selection` the caller gave, which is theirs and goes as given.
local function selection_appendix(opts)
    local sel = captured_selection[opts]
    if sel then return selection_block(sel) end
    return opts.selection
end

local function capture(opts)
    if opts.launch_info ~= nil then return end
    opts.launch_info = launch_info()
    if not in_visual() then return end
    -- A ref is only useful on a prompt that is going to open; a send that asked
    -- for no window has nowhere to put it.
    if opts.interactive or opts.command == nil or opts.command == '' then
        if opts.selection == nil then
            opts.selection = selection_ref(opts.launch_info)
            if opts.selection then
                -- The lines as the buffer has them now, unsaved edits and all:
                -- that is what the user selected, whatever the disk says.
                local info = opts.launch_info
                captured_selection[opts] = {
                    info = info,
                    lines = vim.api.nvim_buf_get_lines(0, info.start_line - 1, info.end_line, false),
                    filetype = vim.bo.filetype,
                    modified = vim.bo.modified,
                }
            end
        end
        -- The window opened next is no place to still be in Visual mode.
        vim.cmd('normal! \27')
    end
end

-- Command logger
local cache_file = vim.fn.stdpath('cache') .. '/foyer.json'
local history = {}

local function load_history()
    local file = io.open(cache_file, 'r')
    if file then
        local content = file:read('*a')
        file:close()
        local ok, data = pcall(vim.fn.json_decode, content)
        if ok and data then history = data end
    end
end

local function save_history()
    local file = io.open(cache_file, 'w')
    if file then
        file:write(vim.fn.json_encode(history))
        file:close()
    end
end

local function get_term_name(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local term_name = name:match('([^/\\]+)$') or 'default'
    -- A terminal buffer name carries a PID prefix like "42098:".
    return (term_name:gsub('^%d+:', ''):gsub('^%s*(.-)%s*$', '%1')) or 'default'
end

local function log_command(cmd, term_bufnr)
    if is_blank(cmd) then return end

    local term_name = get_term_name(term_bufnr)
    if not history[term_name] then history[term_name] = {} end

    local entries = history[term_name]

    for i = #entries, 1, -1 do
        if entries[i].cmd == cmd then
            table.remove(entries, i)
        end
    end

    table.insert(entries, {
        cmd = cmd,
        time = os.time()
    })

    save_history()
end

load_history()

-- Highlight marking the filter text inside the history palette. Re-applied on
-- ColorScheme because :colorscheme clears default highlights.
local hl_group = vim.api.nvim_create_augroup('foyer_highlight', { clear = true })
local function set_default_hl()
    vim.api.nvim_set_hl(0, 'FoyerMatch', {
        bg = '#333333',
        fg = '#ff7700',
        bold = true,
        default = true,
    })
    -- The veil over the editor while the terminal picker is up.
    vim.api.nvim_set_hl(0, 'FoyerBackdrop', { bg = '#000000', default = true })
end
set_default_hl()
vim.api.nvim_create_autocmd('ColorScheme', { group = hl_group, callback = set_default_hl })

-- Text the receiver must take literally rather than act on. A bare newline in
-- the middle of a command reads as Enter to a shell, which would run the first
-- line on its own; bracketed paste says "this is pasted input" and gets the
-- newline inserted instead. Only a multi-line send is wrapped: a single-line
-- command never needed the protection. A receiver that does not understand the
-- escapes shows them as text, which is what `bracketed_paste = false` is for.
local function as_paste(cmd)
    if not config.bracketed_paste then return cmd end
    if not cmd:find('\n', 1, true) then return cmd end
    return '\x1b[200~' .. cmd .. '\x1b[201~'
end

local function send_command(term_bufnr, cmd, prefix, suffix, stopinsert)
    vim.cmd('startinsert')
    vim.defer_fn(function()
        vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, prefix)
        vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, as_paste(cmd) .. suffix)
        if stopinsert then
            vim.cmd('stopinsert')
        end
    end, 100)
end

-- The command line a terminal was spawned with, which its buffer name records
-- as `term://<cwd>//<pid>:<command>`.
local function term_command(term_bufnr)
    return vim.api.nvim_buf_get_name(term_bufnr):match('^term://.-//%d+:(.*)$')
end

-- The keys a terminal is driven with, `{ clear_input, clear_screen }`: Ctrl-U
-- erases the input line, Ctrl-L wipes the screen. cmd.exe erases with ESC and
-- has nothing for the screen.
local function default_prefix(term_bufnr)
    if jit.os == "Windows" and vim.api.nvim_buf_get_name(term_bufnr):match("cmd") then
        return { "\x1b", "" }
    end
    return { "\x15", "\x0c" }
end

-- The pair the user named for this program, if any.
--
-- Keyed by the program, not by the `commands` key that selected it: one key
-- stands for whatever that project wants behind it, so `a` is one agent here
-- and another there. The whole command line, the program alone and its
-- basename are all tried, so a program can be named however you think of it.
local function configured_prefix(term_bufnr)
    local cmd = term_command(term_bufnr)
    if not cmd then return nil end
    local program = cmd:match('^%S+')
    return config.send_prefix[cmd]
        or program and (config.send_prefix[program]
            or config.send_prefix[program:match('[^/\\]+$')])
end

-- [1] clears the input line, which is also how the command line is read back;
-- [2] clears the screen as well, which is what a send is prefixed with. Both
-- are a shell's bindings, and a program with a UI of its own is free to bind
-- them to anything -- an agent that opens a menu on Ctrl-L swallows the prompt
-- arriving behind it, while erasing the line on Ctrl-U as any shell does -- so
-- a program may name the keys it understands, and `''` the ones it does not.
local function get_osc_commands(term_bufnr)
    local prefix = configured_prefix(term_bufnr) or default_prefix(term_bufnr)
    local clear_input = prefix[1] or ''
    return { clear_input, clear_input .. (prefix[2] or '') }
end

-- Map `key` to toggle the window between its current size and full screen.
local function create_keymap_x(bufnr, key)
    vim.keymap.set('n', key, layout.toggle_full_size, {silent = true, buffer = bufnr})
    vim.keymap.set('n', '<C-o>', '<C-6>', {silent = true, buffer = bufnr})
end

local prompts = {}

local term_keymaps_group = vim.api.nvim_create_augroup('foyer_keymaps', { clear = false })
local term_setup_done = {}

local function setup_terminal_keymaps(buf)
    -- Called from every path that reaches a terminal, so it must be idempotent:
    -- a second run would stack another buf_attach and another TextYankPost
    -- autocmd on the same buffer.
    if term_setup_done[buf] then return end
    term_setup_done[buf] = true

    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            last_output_time[buf] = vim.uv.now()
        end,
        on_detach = function()
            term_setup_done[buf] = nil
            last_output_time[buf] = nil
            prompts[buf] = nil
        end,
    })

    vim.keymap.set('t', '<C-x>i', function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>"apA', true, true, true), 'm', true)
    end, { buffer = buf, desc = 'Paste from register a' })

    vim.keymap.set('t', '<C-x>w', function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        if #wins > 1 then
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n><C-w>w', true, true, true), 'm', true)
        else
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>gT', true, true, true), 'm', true)
        end
    end, { buffer = buf, desc = 'Switch window or tab' })

    vim.keymap.set('t', '<C-x>c', function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        local tabs = vim.api.nvim_list_tabpages()
        if #wins == 1 and #tabs == 1 then
            vim.cmd('b#')
        else
            vim.cmd('q')
        end
    end, { buffer = buf, desc = 'Close terminal buffer' })

    vim.api.nvim_create_autocmd('TextYankPost', {
        group = term_keymaps_group,
        buffer = buf,
        callback = function()
            local event = vim.v.event
            if event.operator == 'y' then
                local content = vim.tbl_map(function(line) return line:gsub('%s+$', '') end, event.regcontents)
                local reg = event.regname ~= '' and event.regname or '"'
                vim.fn.setreg(reg, content, event.regtype)
                if reg == '"' then
                    vim.fn.setreg('+', content, event.regtype)
                    vim.fn.setreg('*', content, event.regtype)
                end
            end
        end,
    })
end

local function init_term_buf(term_bufnr, win_id, prev_buf)
    -- Set for this buffer in this window only, so a borrowed window does not
    -- keep it once its own buffer is back.
    vim.wo[win_id][0].relativenumber = true
    for _, key in ipairs({'<CR>', '<C-c>', '<Esc>'}) do
        vim.keymap.set('n', key, function()
            dismiss(win_id, prev_buf)
        end, {silent = true, buffer = term_bufnr})
    end

    create_keymap_x(term_bufnr, 'x')
    setup_terminal_keymaps(term_bufnr)

    vim.keymap.set('n', '<C-r>', function()
        local root = project_root(vim.fn.getcwd())
        if root then
            vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, "cd " .. vim.fn.shellescape(root) .. "\r")
        end
        vim.cmd('normal 0"aY')
        prompts[term_bufnr] = vim.fn.getreg('a')
    end, {silent = true, buffer = term_bufnr})

    local function jump_to_prompt(backward)
        local flag = backward and 'b' or ''
        if not prompts[term_bufnr] then
            send_command(term_bufnr, "", get_osc_commands(term_bufnr)[1], "", true)
            vim.defer_fn(function()
                vim.cmd('normal 0"aY')
                prompts[term_bufnr] = vim.fn.getreg('a')
                vim.fn.search(vim.fn.escape(vim.fn.getreg('a'), '\\.*$^~[]'), flag)
            end, 200)
        else
            if vim.fn.search(vim.fn.escape(prompts[term_bufnr], '\\.*$^~[]'), flag) == 0 then
                prompts[term_bufnr] = nil
            end
        end
    end

    vim.keymap.set('n', '[p', function()
        jump_to_prompt(true)
    end, {silent = true, buffer = term_bufnr})

    vim.keymap.set('n', ']p', function()
        jump_to_prompt()
    end, {silent = true, buffer = term_bufnr})

    -- Entering terminal mode scrolls to the bottom, which is the only way to
    -- bring the latest output into view without moving the cursor ourselves.
    vim.defer_fn(function()
        vim.cmd('startinsert')
        vim.defer_fn(function()
            vim.cmd('stopinsert')
        end, 200)
    end, 200)
end

local function init_command_buf_shared(bufnr, win_id, lines, on_enter)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    vim.keymap.set('n', '<Esc>', function()
        if is_blank(buffer_text(bufnr)) then
            dismiss(win_id, bufnr)
        end
    end, {silent = true, buffer = bufnr})

    vim.keymap.set('n', '<C-c>', function()
        dismiss(win_id, bufnr)
    end, {silent = true, buffer = bufnr})

    vim.keymap.set('n', '<CR>', on_enter, {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-s>', on_enter, {silent = true, buffer = bufnr})
    create_keymap_x(bufnr, '<C-x><C-x>')
end

-- History navigation for one command buffer, over the history of {term_buf}.
-- Re-attachable, and must be re-attached by anyone handing an existing buffer
-- to a new send: the list is read once, here, so a prompt that outlived its
-- send would otherwise go on walking the history as it stood when its window
-- opened.
local function attach_history(bufnr, term_buf)
    set_default_hl()

    -- A copy of this terminal's history, so filtering never mutates the stored
    -- list, with the draft appended as the last entry: navigation walks back to
    -- it, and typing updates it in place.
    local entries = history[get_term_name(term_buf)] or {}
    local working_entries = {}
    for _, entry in ipairs(entries) do
        table.insert(working_entries, entry)
    end
    table.insert(working_entries, {cmd = buffer_text(bufnr), time = os.time()})
    local filtered_entries = working_entries
    local idx = #filtered_entries - 1

    local function navigate_history(delta)
        local user_input = buffer_text(bufnr)
        if idx == #filtered_entries - 1 or filtered_entries[idx + 1].cmd ~= user_input then
            working_entries[#working_entries].cmd = user_input

            clear_foyer_matches()
            if user_input and user_input ~= "" then
                filtered_entries = {}
                for i = 1, #working_entries - 1 do
                    if working_entries[i].cmd:lower():find(user_input:lower(), 1, true) then
                        table.insert(filtered_entries, working_entries[i])
                    end
                end
                table.insert(filtered_entries, working_entries[#working_entries])

                vim.fn.matchadd('FoyerMatch', vim.fn.escape(user_input, '\\'))
            else
                filtered_entries = working_entries
            end
            idx = #filtered_entries - 1
        end

        if #filtered_entries == 0 then return end

        idx = ((idx - delta) % #filtered_entries + #filtered_entries) % #filtered_entries
        local cmd = filtered_entries[idx + 1] and filtered_entries[idx + 1].cmd or ""
        local new_lines = vim.split(cmd, '\n', {plain = true})
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
        vim.api.nvim_win_set_cursor(0, {#new_lines, #new_lines[#new_lines]})
    end

    vim.keymap.set('n', '<Up>', function() navigate_history(1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('n', '<C-p>', function() navigate_history(1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('n', '<Down>', function() navigate_history(-1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('n', '<C-n>', function() navigate_history(-1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-p>', function() navigate_history(1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-n>', function() navigate_history(-1) end, {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-x><C-p>', '<C-p>', {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-x><C-n>', '<C-n>', {silent = true, buffer = bufnr})
end

-- {opts.term} is the terminal the prompt is for: its history is the one
-- walked and the one the sent prompt joins.
local function init_command_buf(bufnr, win_id, lines, on_command_input, opts)
    opts = opts or {}
    init_command_buf_shared(bufnr, win_id, lines, function()
        local cmd = buffer_text(bufnr)
        log_command(cmd, opts.term)
        local new_buf = on_command_input(cmd)
        if new_buf then
            vim.api.nvim_set_current_buf(new_buf)
            vim.cmd('normal! G')
            -- The prompt has left this window; the frame should stop
            -- advertising it and name the terminal now sitting there, the
            -- way the caller named it if it did.
            set_window_title(win_id, opts.term_title or get_term_name(new_buf))
            init_term_buf(new_buf, win_id, bufnr)
        else
            dismiss(win_id, bufnr)
        end
    end)

    -- A buffer with something to say already -- a lifted command line, a seeded
    -- command, a prompt that is going to carry a selection -- means the writing
    -- has started. One with nothing to say stays in Normal mode, where <Up>
    -- walks history.
    if opts.start_insert then
        insert_at_end(bufnr, win_id)
    end

    attach_history(bufnr, opts.term)
end

local function back_to_prompt(osc_command, cb)
    local pos0 = vim.api.nvim_win_get_cursor(0)
    vim.fn.chansend(vim.b.terminal_job_id, osc_command)
    vim.cmd('startinsert')
    vim.defer_fn(function()
        local pos1 = vim.api.nvim_win_get_cursor(0)
        if pos0[1] == pos1[1] and pos0[2] == pos1[2] then
            cb()
        else
            back_to_prompt(osc_command, cb)
        end
    end, 200)
end

local function get_terminal_input(cb)
    local prompt_end = vim.api.nvim_win_get_cursor(0)

    local term_bufnr = vim.api.nvim_get_current_buf()
    -- Snapshot the buffer before the erase sequence scrolls the prompt away.
    local lines = vim.api.nvim_buf_get_lines(term_bufnr, 0, -1, false)

    back_to_prompt(get_osc_commands(term_bufnr)[1], function()

        local prompt_start = vim.api.nvim_win_get_cursor(0)

        vim.defer_fn(function()
            local start_line = prompt_start[1]
            local start_col = prompt_start[2]
            local end_line = prompt_end[1]
            local end_col = prompt_end[2]

            local sliced_lines = {}
            for i = start_line, end_line do
                table.insert(sliced_lines, lines[i])
            end
            lines = sliced_lines

            local result = ""

            if #lines == 0 then
                result = ""
            elseif #lines == 1 then
                result = string.sub(lines[1], start_col + 1, end_col + 1)
            else
                result = string.sub(lines[1], start_col + 1)

                for i = 2, #lines - 1 do
                    result = result .. "\n" .. lines[i]
                end

                result = result .. "\n" .. string.sub(lines[#lines], 1, end_col + 1)
            end

            cb(result)
        end, 200)
    end)
end

function M.edit_input()
    if vim.bo.buftype ~= 'terminal' then
        vim.notify("Not in a terminal buffer", vim.log.levels.ERROR)
        return
    end

    get_terminal_input(function(input)
        local term_bufnr = vim.api.nvim_get_current_buf()

        create_window('floating', 'Edit Terminal Command', function(bufnr, win_id)
            local text = input or ""
            local lines = vim.split(text, '\n', {plain = true})
            init_command_buf(bufnr, win_id, lines, function(cmd)
                send_command(term_bufnr, cmd, get_osc_commands(term_bufnr)[1], "", false)
            end, { start_insert = text ~= "", term = term_bufnr })
        end, { term = term_bufnr })
    end)
end

local term_bufs = {}

local function resolve_command(term_key, root, launch_info)
    local val = config.commands[term_key]
    if type(val) == "function" then
        return val(root, launch_info)
    end
    return val
end

-- A resolved entry is a string, a `{ command, arguments }` pair, or either of
-- those carrying `cwd` and `scope` alongside.
local function entry_command(entry)
    if type(entry) ~= "table" then return entry end
    return entry[2] and entry[1] .. " " .. entry[2] or entry[1]
end

local function entry_name(entry)
    return type(entry) == "table" and entry[1] or entry
end

local function entry_cwd(entry, root)
    return type(entry) == "table" and entry.cwd or root
end

local function entry_is_global(entry)
    return type(entry) == "table" and entry.scope == "global"
end

-- Where a terminal's identity lives. A global entry keeps one terminal for the
-- whole session, wherever you are; every other one is per project root. The
-- bucket also keys the context file, so a global agent reads one file rather
-- than a new one per repo.
local function entry_bucket(entry, root)
    if entry_is_global(entry) then return "" end
    return root
end

-- Which keys have a live terminal, each looked up in its own bucket.
local function running_terminals(root, launch_info)
    local running = {}
    for key in pairs(config.commands) do
        local bucket = entry_bucket(resolve_command(key, root, launch_info), root)
        local buf = term_bufs[bucket] and term_bufs[bucket][key]
        if buf then running[key] = buf end
    end
    return running
end

local function open_term(root, term_key, launch_info)
    local entry = resolve_command(term_key, root, launch_info)
    local bucket = entry_bucket(entry, root)

    vim.cmd('split')

    local pd = vim.fn.getcwd()

    vim.cmd("lcd " .. vim.fn.fnameescape(entry_cwd(entry, root)))

    export_context(publish(term_context_path(bucket, term_key), launch_info))
    vim.cmd("term " .. entry_command(entry))
    vim.cmd("lcd " .. vim.fn.fnameescape(pd))

    if term_bufs[bucket] == nil then
        term_bufs[bucket] = {}
    end
    term_bufs[bucket][term_key] = vim.api.nvim_get_current_buf()
    -- Attach now so is_idle() actually tracks output from the very first
    -- command instead of reporting a busy terminal as idle.
    setup_terminal_keymaps(term_bufs[bucket][term_key])
    vim.cmd('close')
    -- TermOpen autocmds may queue a startinsert that only takes effect once we
    -- return to the main loop. The terminal is created in the background here,
    -- so cancel it instead of letting it leak into whatever buffer is current.
    vim.cmd('stopinsert')
    return term_bufs[bucket][term_key]
end

function M.send_terminal_command(term_key, opts)
    opts = opts or {}
    capture(opts)
    local root = project_root(vim.env.HOME)
    local entry = resolve_command(term_key, root, opts.launch_info)
    local bucket = entry_bucket(entry, root)
    local target_buf = term_bufs[bucket] and term_bufs[bucket][term_key] or nil

    if target_buf and not vim.api.nvim_buf_is_valid(target_buf) then
        term_bufs[bucket][term_key] = nil
        target_buf = nil
    end

    if not target_buf then
        if opts.auto_start then
            open_term(root, term_key, opts.launch_info)
            opts.auto_start = false
            vim.defer_fn(function()
                M.send_terminal_command(term_key, opts)
            end, 200)
        else
            vim.notify("Terminal '" .. term_key .. "' not found", vim.log.levels.ERROR)
        end
        return
    end

    publish(term_context_path(bucket, term_key), opts.launch_info)

    local OSC_commands = get_osc_commands(target_buf)
    local command = opts.command
    local interactive = opts.interactive or opts.selection
    if command == nil or command == "" then
        interactive = true
    end
    if interactive then
        -- The program alone does not say which agent this is: the same one can
        -- run per project and as the global side chat. Name where it belongs
        -- -- the picker's `global` tag, or the project -- so the frame tells
        -- the two apart before anything is sent.
        local place = entry_is_global(entry) and 'global' or vim.fs.basename(root)
        local term = entry_name(entry) .. ' · ' .. place
        local title = 'Ctrl-s to send command to 『' .. term .. ' 』'
        -- The ref never appears in the buffer, so the frame is the only place
        -- the user can see what the send is going to carry.
        if opts.selection then title = title .. ' + ' .. opts.selection end
        -- A global agent is a conversation of its own rather than a helper to
        -- the code on screen, so its prompt takes the window you are in, as a
        -- page you turn to, instead of a float or a sidebar beside your code.
        local win_type = entry_is_global(entry) and 'current' or opts.win_type
        create_window(win_type, title, function(bufnr, win_id, reused)
            -- A sidebar prompt outlives the send that opened it, so this send's
            -- ref, seed and history have to reach the buffer rather than the
            -- closure that set the window up.
            if reused then
                vim.b[bufnr].foyer_selection = selection_appendix(opts)
                set_window_title(win_id, title)
                -- A draft in there is the user's and stays. An empty buffer has
                -- nothing to lose, so a seeded command still gets its chance
                -- rather than going missing without a word.
                if is_blank(buffer_text(bufnr)) and not is_blank(command or "") then
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(command, '\n', { plain = true }))
                end
                attach_history(bufnr, target_buf)
                if opts.selection or not is_blank(buffer_text(bufnr)) then
                    insert_at_end(bufnr, win_id)
                end
                return
            end
            local function init_prompt(start_insert)
                local seed = vim.split(command or "", '\n', { plain = true })
                init_command_buf(bufnr, win_id, seed, function(cmd)
                    clear_foyer_matches()
                    cmd = with_selection(cmd, vim.b[bufnr].foyer_selection)
                    if not is_blank(cmd) then
                        send_command(target_buf, cmd, OSC_commands[2], "\r", true)
                    end
                    return target_buf
                end, { start_insert = start_insert, term_title = term, term = target_buf })
            end
            if not M.is_idle(target_buf, 2000) then
                -- Mid-output, the terminal takes the window instead of a
                -- prompt, and a ref with no prompt to ride on goes nowhere.
                -- Say so, and let the frame name what is actually in there.
                if opts.selection then
                    vim.notify('Terminal busy, ' .. opts.selection .. ' not sent', vim.log.levels.WARN)
                end
                -- The prompt is still the terminal's alternate buffer, which
                -- <C-o> rewinds to, so it must work once the user gets there.
                -- It is set up in Normal mode: insert would land in the
                -- terminal that is about to take the window.
                init_prompt(false)
                vim.api.nvim_set_current_buf(target_buf)
                -- After the switch: the frame belongs to the buffer shown.
                set_window_title(win_id, term)
                init_term_buf(target_buf, win_id, bufnr)
                return
            end
            vim.b[bufnr].foyer_selection = selection_appendix(opts)
            init_prompt(opts.selection ~= nil or not is_blank(command or ""))
        end, { term = target_buf })
    else
        if vim.b[target_buf] and vim.b[target_buf].terminal_job_id then
            send_command(target_buf, command, OSC_commands[2], "\r", true)
        else
            vim.notify("Failed to send command to terminal", vim.log.levels.ERROR)
        end
    end
end

-- What a key read for the picker means: the terminal key it names, false for
-- a request to back out, nil for a key that names nothing. <C-c> can arrive as
-- an interrupt rather than a key, which is what {ok} false is.
local function picked_key(ok, char)
    if not ok or char == 27 or char == 3 then return false end
    if type(char) ~= 'number' then return nil end
    local key = vim.fn.nr2char(char)
    return config.commands[key] and key or nil
end

-- Wait up to {ms} for a key without drawing anything: true once one is
-- waiting, false on timeout, nil on <C-c>.
local function key_within(ms)
    local ok, status = vim.wait(ms, function() return vim.fn.getchar(1) ~= 0 end, 10)
    if ok then return true end
    if status == -2 then return nil end
    return false
end

-- Show the configured terminals in a popup and wait for the key of one, or nil
-- once the user backs out. A key that names no terminal is ignored rather than
-- taken as a cancel: the choices are on screen, so it is a slip of the finger.
--
-- The popup is lazy: a key typed within `picker_delay` is taken without one, so
-- a mapping run straight through to its terminal key does not flash a window
-- and a dimmed editor for a single frame.
local function pick_terminal(root, launch_info, running)
    local keys = vim.tbl_keys(config.commands)
    if #keys == 0 then
        vim.notify('foyer.nvim: no terminals configured in `commands`', vim.log.levels.WARN)
        return nil
    end

    local waiting = key_within(config.picker_delay)
    if waiting == nil then return nil end
    if waiting then
        local key = picked_key(pcall(vim.fn.getchar))
        -- A slip at this speed is still a slip: show the choices it missed.
        if key ~= nil then return key or nil end
    end

    -- One row per key: its name, then the tags worth knowing before picking.
    -- A global terminal is the same one in every project, and a running one is
    -- reused rather than spawned. The names are padded to one width so the tags
    -- line up in a column of their own.
    local rows = {}
    local name_width = 0
    for _, key in ipairs(keys) do
        local entry = resolve_command(key, root, launch_info)
        local row = {
            key = key,
            name = tostring(entry_name(entry)),
            global = entry_is_global(entry),
            running = running[key] ~= nil,
        }
        name_width = math.max(name_width, vim.fn.strdisplaywidth(row.name))
        table.insert(rows, row)
    end
    -- This project's terminals first, the global ones gathered below them:
    -- what belongs here leads, what follows you everywhere comes after. Each
    -- group stays in key order.
    table.sort(rows, function(a, b)
        if a.global ~= b.global then return b.global end
        return a.key < b.key
    end)

    local any_global = vim.iter(rows):any(function(row) return row.global end)
    local lines, tags = {}, {}
    for i, row in ipairs(rows) do
        local line = (' %s  %s'):format(row.key, row.name)
        if row.global or row.running then
            line = line .. (' '):rep(name_width - vim.fn.strdisplaywidth(row.name)) .. ' '
            if row.global then
                -- Byte offsets, for the highlight below.
                tags[i] = { #line, #line + #'global' }
                line = line .. 'global'
            elseif any_global then
                -- Hold the tag's place, so every ● sits in one column.
                line = line .. (' '):rep(#'global')
            end
            if row.running then line = line .. ' ●' end
        end
        lines[i] = line .. ' '
    end

    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    local footer = ' <Esc> to cancel '
    width = math.max(width, #footer)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace('foyer_pick')
    for i = 1, #lines do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 2, hl_group = 'Special' })
        if tags[i] then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, tags[i][1], { end_col = tags[i][2], hl_group = 'Comment' })
        end
    end
    vim.bo[buf].modifiable = false

    -- Dim the editor behind the picker, so the choice is the one thing that
    -- reads. Blending needs 'termguicolors': without it the veil would be
    -- opaque and hide the editor outright, so it is left out instead.
    local backdrop_buf, backdrop_win
    if vim.o.termguicolors then
        backdrop_buf = vim.api.nvim_create_buf(false, true)
        backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, {
            relative = 'editor',
            row = 0,
            col = 0,
            width = vim.o.columns,
            -- The command line stays clear: messages land there.
            height = math.max(1, vim.o.lines - vim.o.cmdheight),
            style = 'minimal',
            focusable = false,
            noautocmd = true,
            zindex = 49,
        })
        vim.wo[backdrop_win].winhighlight = 'Normal:FoyerBackdrop'
        vim.wo[backdrop_win].winblend = 40
    end

    local height = math.min(#lines, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' Terminal ',
        title_pos = 'center',
        footer = footer,
        footer_pos = 'right',
        focusable = false,
        noautocmd = true,
        zindex = 50,
    })

    local picked
    repeat
        -- getchar() blocks before the screen catches up with the new float.
        vim.cmd('redraw')
        picked = picked_key(pcall(vim.fn.getchar))
    until picked ~= nil

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    if backdrop_win then
        vim.api.nvim_win_close(backdrop_win, true)
        vim.api.nvim_buf_delete(backdrop_buf, { force = true })
    end
    return picked or nil
end

function M.terminal_command(opts)
    opts = opts or {}
    capture(opts)

    local root = project_root(vim.env.HOME)
    -- Every bucket, not just this project's: a global terminal is offered here
    -- too, and a buffer the user wiped must not be reported running.
    for _, bufs in pairs(term_bufs) do
        for key, buf in pairs(bufs) do
            if not vim.api.nvim_buf_is_valid(buf) then
                bufs[key] = nil
            end
        end
    end

    local term_key = opts.key
    if term_key then
        if config.commands[term_key] == nil then
            vim.notify("foyer.nvim: no terminal configured for key '" .. term_key .. "'",
                vim.log.levels.ERROR)
            return
        end
    else
        term_key = pick_terminal(root, opts.launch_info, running_terminals(root, opts.launch_info))
        if not term_key then return end
    end

    local entry = resolve_command(term_key, root, opts.launch_info)
    local bucket = entry_bucket(entry, root)
    if term_bufs[bucket] == nil then
        term_bufs[bucket] = {}
    end
    local buf = term_bufs[bucket][term_key]
    if buf == nil then
        buf = open_term(root, term_key, opts.launch_info)
    end

    -- Step into the terminal rather than prompt for it, when asked to.
    -- Published before the switch, so an agent already in there re-reads the
    -- file and learns where we are now.
    if opts.switch then
        publish(term_context_path(bucket, term_key), opts.launch_info)
        vim.api.nvim_set_current_buf(buf)
        return buf
    end

    M.send_terminal_command(term_key, opts)
end

function M.edit_selection()
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' or mode == '\22' then  -- visual, visual-line, or visual-block mode
        vim.cmd('normal! "ay')
    else
        return
    end
    local filetype = vim.bo[0].filetype
    local width = vim.o.columns - 32
    local adata = vim.fn.getreg('a')
    -- A linewise yank ends in a newline, which would seed a blank last line.
    -- Only linewise: a charwise selection that happens to end at a line break
    -- really does include that empty line.
    if mode == 'V' then adata = adata:gsub('\n$', '') end
    local lines = vim.split(adata, '\n', { plain = true })
    local height = math.min(math.max(#lines, math.ceil(#adata / width) + 2), vim.o.lines - 4)
    create_window('floating', 'Edit selection', function(bufnr, win_id)
        vim.bo[bufnr].filetype = filetype
        init_command_buf_shared(bufnr, win_id, lines, function()
            vim.cmd('normal! gg0' .. mode .. 'G$"ay')
            dismiss(win_id, bufnr)
            vim.cmd('normal! gv"ap')
        end)
    end, { float = { height = height, width = width } })
end


M.toggle_full_size = layout.toggle_full_size
M.tab_switch = layout.tab_switch

return M
