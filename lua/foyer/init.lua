local M = {}
local config = { commands = {}, builders = {}, root_markers = nil }
local last_output_time = {}

-- Directory markers used to locate the project root that scopes terminals.
-- Falls back to vim.g.root_markers so an existing config keeps working, then
-- to a plain git checkout for everybody else.
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
    -- Remove PID prefix like "42098:" from terminal names
    return (term_name:gsub('^%d+:', ''):gsub('^%s*(.-)%s*$', '%1')) or 'default'
end

local function log_command(cmd, term_bufnr)
    if cmd == "" then return end

    local term_name = get_term_name(term_bufnr)
    if not history[term_name] then history[term_name] = {} end

    local entries = history[term_name]

    -- Remove existing entry with same command
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

-- Initialize
load_history()

-- Highlight used to mark the filter text inside the history palette. Declared
-- with default = true so a colorscheme or user override wins, and re-applied on
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

local function create_keymap_x(bufnr, win_id, key)
    local is_float = vim.api.nvim_win_get_config(win_id).relative ~= ''
    if is_float then
        -- Floating window: toggle height between default and full-screen
        local height = vim.api.nvim_win_get_config(win_id).height
        vim.keymap.set('n', key, function()
            if vim.api.nvim_win_is_valid(win_id) then
                local win_config = vim.api.nvim_win_get_config(win_id)
                local new_height = win_config.height == height and (vim.o.lines - 4) or height
                vim.api.nvim_win_set_config(win_id, vim.tbl_extend('force', win_config, {height = new_height}))
            end
        end, {silent = true, buffer = bufnr})
    else
        -- Sidebar: toggle width between default and expanded
        local width = vim.api.nvim_win_get_width(win_id)
        vim.keymap.set('n', key, function()
            if vim.api.nvim_win_is_valid(win_id) then
                local cur_width = vim.api.nvim_win_get_width(win_id)
                local new_width = cur_width == width and vim.o.columns or width
                vim.api.nvim_win_set_width(win_id, new_width)
            end
        end, {silent = true, buffer = bufnr})
    end

    vim.keymap.set('n', '<C-o>', '<C-6>', {silent = true, buffer = bufnr})
end

local prompts = {}
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

    create_keymap_x(term_bufnr, win_id, 'x')
    M.setup_terminal_keymaps(term_bufnr)

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

    -- bring latest output in view
    vim.defer_fn(function()
        vim.cmd('startinsert')
        vim.defer_fn(function()
            vim.cmd('stopinsert')
        end, 200)
    end, 200)
end

local function init_command_buf_shared(bufnr, win_id, lines, on_enter)
    if #lines == 1 and lines[1] == "@" then
        -- V select all and paste from register a
        vim.cmd('normal! ggVG"ap')
        vim.fn.setreg('a', '')
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
    create_keymap_x(bufnr, win_id, '<C-x><C-x>')
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

    -- Set highlight group for this window
    set_default_hl()

    -- Build working entries once with current input
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

    -- History navigation
    local function navigate_history(delta)
        local user_input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if idx == #filtered_entries - 1 or filtered_entries[idx + 1].cmd ~= user_input then
            working_entries[#working_entries].cmd = user_input

            vim.fn.clearmatches()
            -- Apply filtering if there's user input
            if user_input and user_input ~= "" then
                filtered_entries = {}
                for i = 1, #working_entries - 1 do
                    if working_entries[i].cmd:lower():find(user_input:lower(), 1, true) then
                        table.insert(filtered_entries, working_entries[i])
                    end
                end
                -- Add the current input as the last entry
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

-- Track active command buffer windows per terminal
local active_cmd_wins = {}

-- Common function to create a window (floating or sidebar)
local function create_window(type, title, on_ready, opts)
    opts = opts or {}
    -- Focus existing command buffer window if already open for the same terminal
    if type == "sidebar" then
        local win = active_cmd_wins[current_term]
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    -- Capture expandtab settings from current buffer
    local current_bufnr = vim.api.nvim_get_current_buf()
    local expandtab = vim.bo[current_bufnr].expandtab
    local tabstop = vim.bo[current_bufnr].tabstop
    local shiftwidth = vim.bo[current_bufnr].shiftwidth
    local softtabstop = vim.bo[current_bufnr].softtabstop

    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_id

    if type == "sidebar" then
        -- Create a sidebar split on the right
        win_id = vim.api.nvim_open_win(bufnr, true, {
            split = 'right',
        })
        -- Show title in the winbar
        vim.wo[win_id].winbar = ' ' .. title .. ' '
    else
        -- Calculate dimensions and position for the floating window
        local width = vim.o.columns - 32
        local col = math.floor((vim.o.columns - width) / 2)
        local row = 1

        -- Set up floating window options
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

        -- Create the floating window
        win_id = vim.api.nvim_open_win(bufnr, true, opts)
    end

    -- Set buffer options
    vim.bo[bufnr].modifiable = true
    vim.wo[win_id].relativenumber = true
    vim.wo[win_id].cursorline = true

    -- Apply expandtab settings from original buffer
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
    -- Get all lines between start and end positions
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
                result = string.sub(lines[1], start_col + 1) -- First line from start_col to end

                for i = 2, #lines - 1 do
                    result = result .. "\n" .. lines[i]
                end

                result = result .. "\n" .. string.sub(lines[#lines], 1, end_col + 1)
            end

            -- vim.fn.chansend(vim.b.terminal_job_id, result)
            cb(result)
        end, 200)
    end)
end

-- Function to edit the last line of a terminal buffer in a floating window
function M.edit_input()
    -- Check if we're in a terminal buffer
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
    M.setup_terminal_keymaps(term_bufs[root][term_key])
    vim.cmd('close')
    -- TermOpen autocmds may queue a startinsert that only takes effect once we
    -- return to the main loop. The terminal is created in the background here,
    -- so cancel it instead of letting it leak into whatever buffer is current.
    vim.cmd('stopinsert')
end

-- Function to send a command to a terminal buffer by name
function M.send_terminal_command(term_key, opts)
    opts = opts or {}
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

    local OSC_commands = get_osc_commands(target_buf)
    local command = opts.command
    local interactive = opts.interactive or opts.selection
    -- If command is empty, create a floating window for input
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
            init_command_buf(bufnr, win_id, { "@" }, function(cmd)
                vim.fn.clearmatches()
                if cmd ~= "" then
                    local builder = config.builders[term_key]
                    cmd = builder and builder(cmd, opts.launch_info) or cmd
                    send_command(target_buf, cmd, OSC_commands[2], "\r", true)
                end
                return target_buf
            end)
        end)
    else
        -- Send command to the terminal
        if vim.b[target_buf] and vim.b[target_buf].terminal_job_id then
            local builder = config.builders[term_key]
            command = builder and builder(command, opts.launch_info) or command
            send_command(target_buf, command, OSC_commands[2], "\r", true)
        else
            vim.notify("Failed to send command to terminal", vim.log.levels.ERROR)
        end
    end
end

function M.terminal_command(opts)
    opts = opts or {}

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

local term_keymaps_group = vim.api.nvim_create_augroup('foyer_keymaps', { clear = false })
local term_setup_done = {}

function M.setup_terminal_keymaps(buf)
    -- Called on every command send, from open_term(), and possibly by users on
    -- their own terminals, so it must be idempotent: each run used to stack
    -- another buf_attach and another TextYankPost autocmd on the same buffer.
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

return M
