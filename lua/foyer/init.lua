local M = {}
local config = { commands = {}, root_markers = nil }
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
    config = vim.tbl_deep_extend('force', config, opts or {})
end

local context_dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'foyer')
local published = {}

local function in_visual()
    local mode = vim.fn.mode()
    return mode == 'v' or mode == 'V' or mode == '\22' -- char, line, block
end

-- What the user is looking at, in the conventional launch_info shape.
local function launch_info()
    -- A terminal or scratch buffer has no file worth reporting: expand('%:p')
    -- would hand back a term:// path. The empty table publishes nothing, so the
    -- last real context stays in place.
    if vim.bo.buftype ~= '' or vim.fn.expand('%') == '' then return {} end
    local info = {
        current_file = vim.fn.expand('%:p'),
        current_line = vim.fn.line('.'),
    }
    if in_visual() then
        info.start_line = vim.fn.line('v')
        info.end_line = vim.fn.line('.')
    end
    return info
end

local function escape_key(s)
    return (tostring(s):gsub('[^%w%-_]', function(c) return ('%%%02x'):format(c:byte()) end))
end

-- Keyed by the terminal's identity, so the same terminal reopened reuses its
-- file. The pid separates two Neovim instances; the caller's prefix separates a
-- project terminal keyed `1` from a named terminal called `1`.
local function context_path(key)
    return vim.fs.joinpath(context_dir, ('%d-%s.json'):format(vim.fn.getpid(), key))
end

-- The root is hashed rather than flattened: a deep path would otherwise make a
-- filename longer than the filesystem allows.
local function term_context_path(root, term_key)
    return context_path(('t-%s-%s'):format(vim.fn.sha256(root):sub(1, 8), escape_key(term_key)))
end

local function named_context_path(name)
    return context_path('n-' .. escape_key(name))
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

local function capture(opts)
    if opts.launch_info ~= nil then return end
    opts.launch_info = launch_info()
    if not in_visual() then return end
    -- Take the selected text only when there will be a prompt to seed with it:
    -- a fire-and-forget send must not clobber register a.
    if opts.interactive or opts.command == nil or opts.command == '' then
        vim.cmd('normal! "ay')
        opts.selection = opts.selection or '@'
    end
end

-- Command logger
local cache_file = vim.fn.stdpath('cache') .. '/foyer.json'
local history = {}
local current_term = nil
local idx = 0

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
    if cmd == "" then return end

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
end
set_default_hl()
vim.api.nvim_create_autocmd('ColorScheme', { group = hl_group, callback = set_default_hl })

local function send_command(term_bufnr, cmd, prefix, suffix, stopinsert)
    vim.cmd('startinsert')
    vim.defer_fn(function()
        vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, prefix)
        vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, cmd .. suffix)
        if stopinsert then
            vim.cmd('stopinsert')
        end
    end, 100)
end

local function get_osc_commands(term_bufnr)
    if jit.os == "Windows" then
        if vim.api.nvim_buf_get_name(term_bufnr):match("cmd") then
            -- \x1b -- ESC
            return { "\x1b", "\x1b" }
        end
    end
    -- \x15 -- Ctrl-u
    -- \x0c -- Ctrl-l
    return { "\x15", "\x15\x0c" }
end

-- Toggle the current window between full screen and the size it had before:
-- height for a float, width for a split. The remembered size is window-local,
-- so it dies with the window. Full is a request, not a promise: a neighbouring
-- split keeps its minimum width, so the window may stop short of 'columns'.
function M.toggle_full_size()
    local win_id = vim.api.nvim_get_current_win()
    local is_float = vim.api.nvim_win_get_config(win_id).relative ~= ''
    local get = is_float and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
    local set = is_float and vim.api.nvim_win_set_height or vim.api.nvim_win_set_width
    -- A float starts one row down and wears a border, so it cannot take every line.
    local full = is_float and (vim.o.lines - 4) or vim.o.columns

    local saved = vim.w[win_id].foyer_saved_size
    if saved then
        vim.w[win_id].foyer_saved_size = nil
        set(win_id, saved)
    else
        vim.w[win_id].foyer_saved_size = get(win_id)
        set(win_id, full)
    end
end

-- Map `key` to toggle the window between its current size and full screen.
local function create_keymap_x(bufnr, key)
    vim.keymap.set('n', key, M.toggle_full_size, {silent = true, buffer = bufnr})
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
    vim.wo[vim.api.nvim_get_current_win()].relativenumber = true
    for _, key in ipairs({'<CR>', '<C-c>', '<Esc>'}) do
        vim.keymap.set('n', key, function()
            if vim.api.nvim_win_is_valid(win_id) then
                vim.api.nvim_win_close(win_id, true)
                if prev_buf and vim.api.nvim_buf_is_valid(prev_buf) then
                    vim.api.nvim_buf_delete(prev_buf, { force = true })
                end
            end
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
    if #lines == 1 and lines[1] == "@" then
        if vim.fn.getreg('a') ~= '' then
            vim.cmd('normal! ggVG"ap')
            vim.fn.setreg('a', '')
        end
    else
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end

    vim.keymap.set('n', '<Esc>', function()
        local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local has_content = false

        for _, line in ipairs(new_lines) do
            if line:match('%S') then
                has_content = true
                break
            end
        end

        if not has_content then
            vim.api.nvim_win_close(win_id, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end, {silent = true, buffer = bufnr})

    vim.keymap.set('n', '<C-c>', function()
        vim.api.nvim_win_close(win_id, true)
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end, {silent = true, buffer = bufnr})

    vim.keymap.set('n', '<CR>', on_enter, {silent = true, buffer = bufnr})
    vim.keymap.set('i', '<C-s>', on_enter, {silent = true, buffer = bufnr})
    create_keymap_x(bufnr, '<C-x><C-x>')
end

local function init_command_buf(bufnr, win_id, lines, on_command_input)
    init_command_buf_shared(bufnr, win_id, lines, function()
        local cmd = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        log_command(cmd, current_term)
        local new_buf = on_command_input(cmd)
        if new_buf then
            vim.api.nvim_set_current_buf(new_buf)
            vim.cmd('normal! G')
            init_term_buf(new_buf, win_id, bufnr)
        else
            vim.api.nvim_win_close(win_id, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    set_default_hl()

    -- A copy of this terminal's history, so filtering never mutates the stored
    -- list, with the draft appended as the last entry: navigation walks back to
    -- it, and typing updates it in place.
    local term_name = get_term_name(current_term)
    local entries = history[term_name] or {}
    local working_entries = {}
    for _, entry in ipairs(entries) do
        table.insert(working_entries, entry)
    end
    local current_input = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] or ""
    table.insert(working_entries, {cmd = current_input, time = os.time()})
    local filtered_entries = working_entries
    idx = #filtered_entries - 1

    local function navigate_history(delta)
        local user_input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if idx == #filtered_entries - 1 or filtered_entries[idx + 1].cmd ~= user_input then
            working_entries[#working_entries].cmd = user_input

            vim.fn.clearmatches()
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

local active_cmd_wins = {}

local function create_window(type, title, on_ready, opts)
    opts = opts or {}
    -- A sidebar is a persistent split, so reopening it would stack another one;
    -- a float is transient and may simply be opened again.
    if type == "sidebar" then
        local win = active_cmd_wins[current_term]
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    -- The scratch buffer inherits the source buffer's indent settings, so text
    -- edited here keeps the shape it had over there.
    local current_bufnr = vim.api.nvim_get_current_buf()
    local expandtab = vim.bo[current_bufnr].expandtab
    local tabstop = vim.bo[current_bufnr].tabstop
    local shiftwidth = vim.bo[current_bufnr].shiftwidth
    local softtabstop = vim.bo[current_bufnr].softtabstop

    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_id

    if type == "sidebar" then
        win_id = vim.api.nvim_open_win(bufnr, true, {
            split = 'right',
        })
        vim.wo[win_id].winbar = ' ' .. title .. ' '
    else
        local width = vim.o.columns - 32
        local col = math.floor((vim.o.columns - width) / 2)
        local row = 1

        opts = vim.tbl_deep_extend('force', {
            relative = 'editor',
            width = width,
            height = 10,
            col = col,
            row = row,
            border = 'rounded',
            title = ' ' .. title .. ' ',
            title_pos = 'center',
            footer = { { " Press <Ctrl-c> or <Esc> to close this window ", "FloatFooter" } },
            footer_pos = "right",
        }, opts)

        win_id = vim.api.nvim_open_win(bufnr, true, opts)
    end

    vim.bo[bufnr].modifiable = true
    vim.wo[win_id].relativenumber = true
    vim.wo[win_id].cursorline = true

    vim.bo[bufnr].expandtab = expandtab
    vim.bo[bufnr].tabstop = tabstop
    vim.bo[bufnr].shiftwidth = shiftwidth
    vim.bo[bufnr].softtabstop = softtabstop

    if on_ready then
        on_ready(bufnr, win_id)
    end

    if current_term ~= nil then
        active_cmd_wins[current_term] = win_id
        local term_key = current_term
        vim.api.nvim_create_autocmd('WinClosed', {
            pattern = tostring(win_id),
            once = true,
            callback = function() active_cmd_wins[term_key] = nil end,
        })
    end
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
        current_term = term_bufnr

        create_window('floating', 'Edit Terminal Command', function(bufnr, win_id)
            local lines = vim.split(input or "", '\n', {plain = true})
            init_command_buf(bufnr, win_id, lines, function(cmd)
                send_command(term_bufnr, cmd, get_osc_commands(current_term)[1], "", false)
            end)
        end)
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

local function open_term(root, term_key, launch_info)
    vim.cmd('split')

    local pd = vim.fn.getcwd()

    vim.cmd("lcd " .. vim.fn.fnameescape(root))

    local term_commands = resolve_command(term_key, root, launch_info)
    export_context(publish(term_context_path(root, term_key), launch_info))
    if type(term_commands) == "string" then
        vim.cmd("term " .. term_commands)
    else
        vim.cmd("term " .. term_commands[1] .. " " .. term_commands[2])
    end
    vim.cmd("lcd " .. vim.fn.fnameescape(pd))

    if term_bufs[root] == nil then
        term_bufs[root] = {}
    end
    term_bufs[root][term_key] = vim.api.nvim_get_current_buf()
    -- Attach now so is_idle() actually tracks output from the very first
    -- command instead of reporting a busy terminal as idle.
    setup_terminal_keymaps(term_bufs[root][term_key])
    vim.cmd('close')
    -- TermOpen autocmds may queue a startinsert that only takes effect once we
    -- return to the main loop. The terminal is created in the background here,
    -- so cancel it instead of letting it leak into whatever buffer is current.
    vim.cmd('stopinsert')
end

function M.send_terminal_command(term_key, opts)
    opts = opts or {}
    capture(opts)
    local root = project_root(vim.env.HOME)
    local target_buf = term_bufs[root] and term_bufs[root][term_key] or nil

    if target_buf and not vim.api.nvim_buf_is_valid(target_buf) then
        term_bufs[root][term_key] = nil
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

    publish(term_context_path(root, term_key), opts.launch_info)

    local OSC_commands = get_osc_commands(target_buf)
    local command = opts.command
    local interactive = opts.interactive or opts.selection
    if command == nil or command == "" then
        interactive = true
    end
    if interactive then
        current_term = target_buf

        local term = resolve_command(term_key, root, opts.launch_info)
        term = type(term) == "table" and term[1] or term
        create_window(opts.win_type, 'Ctrl-s to send command to 『' .. term .. ' 』', function(bufnr, win_id)
            if not M.is_idle(target_buf, 2000) then
                vim.api.nvim_set_current_buf(target_buf)
                init_term_buf(target_buf, win_id, bufnr)
                return
            end
            init_command_buf(bufnr, win_id, { opts.selection or "" }, function(cmd)
                vim.fn.clearmatches()
                if cmd ~= "" then
                    send_command(target_buf, cmd, OSC_commands[2], "\r", true)
                end
                return target_buf
            end)
        end)
    else
        if vim.b[target_buf] and vim.b[target_buf].terminal_job_id then
            send_command(target_buf, command, OSC_commands[2], "\r", true)
        else
            vim.notify("Failed to send command to terminal", vim.log.levels.ERROR)
        end
    end
end

function M.terminal_command(opts)
    opts = opts or {}
    capture(opts)

    local root = project_root(vim.env.HOME)
    local project_term_bufs = term_bufs[root] or {}
    for name, buf in pairs(project_term_bufs) do
        if not vim.api.nvim_buf_is_valid(buf) then
            project_term_bufs[name] = nil
        end
    end

    local function notify_available_terminals(header)
        local display = header
        for key, _ in pairs(config.commands) do
            local term = resolve_command(key, root, opts.launch_info)
            term = type(term) == "table" and term[1] or term
            display = display .. key .. "(" .. term .. ") "
        end
        vim.notify(display, vim.log.levels.INFO)
    end

    local char = vim.fn.getchar()
    local term_key = vim.fn.nr2char(char)

    if term_bufs[root] == nil then
        term_bufs[root] = {}
    end
    if term_bufs[root][term_key] == nil then
        if config.commands[term_key] then
            open_term(root, term_key, opts.launch_info)
        else
            notify_available_terminals("No terminal with primary key '" .. term_key .. "', available terminals: ")
            return
        end
    end

    M.send_terminal_command(term_key, opts)
end

-- Terminals that are not project-scoped: one reused buffer per name, opened in
-- a directory of its own ($HOME unless told otherwise).
local named_terms = {}

function M.open_terminal(name, command, opts)
    opts = opts or {}
    local buf = named_terms[name]
    if buf and not vim.api.nvim_buf_is_valid(buf) then buf = nil end

    -- Before the switch, not just before the spawn: an agent already running in
    -- there re-reads the file, so it learns where we are now too.
    local path = publish(named_context_path(name), opts.launch_info)

    if buf then
        vim.api.nvim_set_current_buf(buf)
    else
        -- The job inherits the directory; the window gets the old one back, so
        -- the terminal's window-local cwd is not left pointing at it.
        local pd = vim.fn.getcwd()
        vim.cmd('lcd ' .. vim.fn.fnameescape(opts.cwd or vim.env.HOME))
        export_context(path)
        vim.cmd('terminal ' .. command)
        vim.cmd('lcd ' .. vim.fn.fnameescape(pd))
        buf = vim.api.nvim_get_current_buf()
        named_terms[name] = buf
    end
    setup_terminal_keymaps(buf)
    return buf
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
    local height = math.min(math.max(#vim.split(adata, '\n'), math.ceil(#adata / width) + 2), vim.o.lines - 4)
    create_window('floating', 'Edit selection', function(bufnr, win_id)
        vim.bo[bufnr].filetype = filetype
        init_command_buf_shared(bufnr, win_id, { "@" }, function()
            vim.cmd('normal! gg0' .. mode .. 'G$"ay')
            vim.api.nvim_win_close(win_id, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
            vim.cmd('normal! gv"ap')
        end)
    end, { height = height, width = width})
end

return M
