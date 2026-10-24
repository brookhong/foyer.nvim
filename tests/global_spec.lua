local H = dofile('tests/helpers.lua')
local foyer = H.foyer({
    commands = {
        q = H.quiet,
        G = vim.tbl_extend('force', H.quiet, { cwd = vim.env.HOME, scope = 'global' }),
    },
})
-- See prompt_spec: a shown terminal reflows, which would read as busy.
foyer.is_idle = function() return true end

-- A split layout, so a closed window would show in the count.
vim.cmd('edit README.md | vsplit lua/foyer/init.lua')
local win = vim.api.nvim_get_current_win()
local file = vim.api.nvim_get_current_buf()
local own_match = vim.fn.matchadd('Search', 'local')

local function global(opts)
    H.press(function() foyer.terminal_command(vim.tbl_extend('force', { key = 'G' }, opts or {})) end)
end

-- The window is the user's again, exactly as it was.
local function restored(what)
    local s = H.state()
    H.eq(win, s.win, what .. ': same window')
    H.eq(2, s.wins, what .. ': window count')
    H.eq(file, s.buf, what .. ': the file is back')
    H.eq('', vim.wo[win].winbar, what .. ': no title left behind')
    H.eq(false, vim.wo[win].relativenumber, what .. ': relativenumber as it was')
    H.eq(false, vim.wo[win].cursorline, what .. ': cursorline as it was')
    local ids = vim.tbl_map(function(m) return m.id end, vim.fn.getmatches(win))
    H.ok(vim.tbl_contains(ids, own_match), what .. ': the user\'s own match survives')
end

local function back()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_set_current_buf(file)
    vim.cmd('stopinsert')
    H.sent_clear()
end

H.test('the prompt takes the current window, titled global', function()
    back()
    global()
    local s = H.state()
    H.ok(s.prompt, 'a prompt')
    H.eq(win, s.win, 'in the current window')
    H.eq(2, s.wins, 'no window opened')
    H.ok(s.title:find('sh · global', 1, true), 'title: ' .. s.title)
end)

H.test('<C-c> hands the window back', function()
    H.feed('<C-c>')
    restored('<C-c>')
end)

H.test('after a send, the terminal takes the window; <CR> hands it back', function()
    back()
    global()
    H.send('hello')
    H.eq('hello\r', H.last_text(), 'sent')
    local s = H.state()
    H.ok(s.terminal, 'the terminal is shown')
    H.eq(win, s.win, 'in the same window')
    H.ok(s.title:find('sh · global', 1, true), 'terminal titled: ' .. s.title)
    vim.cmd('stopinsert')
    H.feed('<CR>')
    restored('terminal <CR>')
end)

H.test('the history filter cleans up only its own highlight', function()
    back()
    global()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hel' })
    vim.cmd('stopinsert')
    H.feed('<Up>')
    local groups = vim.tbl_map(function(m) return m.group end, vim.fn.getmatches(win))
    H.ok(vim.tbl_contains(groups, 'FoyerMatch'), 'the filter highlights')
    H.feed('<C-c>')
    groups = vim.tbl_map(function(m) return m.group end, vim.fn.getmatches(win))
    H.ok(not vim.tbl_contains(groups, 'FoyerMatch'), 'and takes it away again')
    restored('after filtering')
end)

H.test('switch = true steps straight into the terminal', function()
    back()
    global({ switch = true })
    local s = H.state()
    H.ok(s.terminal, 'the terminal')
    H.eq(win, s.win, 'in the current window')
end)

H.test('a terminal reached by hand does not close the window on <CR>', function()
    back()
    -- Only the global terminal has been spawned so far.
    local term = vim.iter(vim.api.nvim_list_bufs()):find(function(b)
        return vim.bo[b].buftype == 'terminal'
    end)
    vim.api.nvim_set_current_buf(term)
    vim.cmd('stopinsert')
    H.feed('<CR>')
    H.eq(win, H.state().win, 'window still there')
    H.eq(2, H.state().wins, 'window count')
end)

H.test('a project agent still opens in a float', function()
    back()
    H.press(function() foyer.terminal_command({ key = 'q' }) end)
    local s = H.state()
    H.ok(s.prompt and s.float, 'a float')
    H.ok(s.title:find('sh · foyer.nvim', 1, true), 'titled with the project: ' .. s.title)
    H.feed('<C-c>')
end)

H.finish()
