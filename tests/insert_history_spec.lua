local H = dofile('tests/helpers.lua')

-- Insert mode needs a real main loop: keys typed into a child Neovim. Its
-- history for the terminal: 'one', then two lines, then 'three', newest last.
local child = H.child([[
    local foyer = require('foyer')
    foyer.setup({ commands = {
        q = { 'sh', '-c "echo up; cat >/dev/null"' },
        -- A program of its own, so a history of its own too.
        w = 'cat',
    } })
    foyer.is_idle = function() return true end
    vim.cmd('edit README.md')
    _G.readme = vim.api.nvim_get_current_buf()
    -- A fresh prompt for {key}, q by default, in Insert mode, holding {lines}.
    function _G.prompt(lines, key)
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= '' then vim.api.nvim_win_close(w, true) end
        end
        vim.cmd('stopinsert | silent! only')
        vim.api.nvim_set_current_buf(_G.readme)
        foyer.prompt({ key = key or 'q' })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or {})
        local last = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_win_set_cursor(0, { last, #vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] })
        vim.cmd('startinsert!')
    end
]])

-- Send each of {prompts} in turn, building the history.
for _, text in ipairs({ 'one', 'two a\ntwo b', 'three' }) do
    child.lua('prompt(...)', vim.split(text, '\n'))
    child.type('<Esc><CR>', 300)
end
child.type('', 1500)

-- Out of Insert mode first, for real: a stopinsert run alongside the
-- prompt's startinsert would cancel it.
local function open(lines, key)
    child.type('<C-\\><C-n>')
    child.lua('prompt(...)', lines, key)
end

local function row() return child.lua('return vim.api.nvim_win_get_cursor(0)[1]') end

H.test('<C-n> in Insert mode completes a word, as anywhere else', function()
    open({ 'a wordcompletion here', 'word' })
    child.type('<C-n>')
    H.eq('wordcompletion', child.lines()[2], 'the match put in, as in a file buffer')
    child.type('<C-e>')
    H.eq('word', child.lines()[2], 'and <C-e> takes it back')
end)

H.test('an @ mention\'s menu leaves completion as it found it', function()
    open({ 'a wordcompletion here', '' })
    local before = child.lua('return vim.bo.completeopt')
    child.type('@')
    H.eq('menuone,noinsert', child.lua('return vim.bo.completeopt'), 'its own, while it is open')
    child.type('<Esc>')
    H.eq(before, child.lua('return vim.bo.completeopt'), 'put back once it closes')
    -- <Esc> left Insert mode too; back in after the @.
    child.type('a word<C-n>')
    H.eq('@ wordcompletion', child.lines()[2], 'and <C-n> puts the match in again')
end)

H.test('<Up> in Insert mode on a one-line draft walks history', function()
    open({})
    child.type('<Up>')
    H.eq({ 'three' }, child.lines(), 'the newest')
    child.type('<Up>')
    H.eq({ 'two a', 'two b' }, child.lines(), 'and the one before')
    child.type('<Up>')
    H.eq({ 'one' }, child.lines(), 'on through an entry of many lines')
    child.type('<Down>')
    H.eq({ 'two a', 'two b' }, child.lines(), '<Down> comes back')
    H.eq('i', child.lua('return vim.api.nvim_get_mode().mode'), 'still in Insert mode')
end)

H.test('in a draft of many lines <Up> and <Down> move until the edge', function()
    -- A draft history is filtered by: it finds the entry it is part of.
    open({ 'two a', 'two' })
    child.type('<Up>')
    H.eq(1, row(), 'up a line, to the first')
    H.eq({ 'two a', 'two' }, child.lines(), 'the draft untouched')
    child.type('<Up>')
    H.eq({ 'two a', 'two b' }, child.lines(), 'from there, history')
    H.eq(2, row(), 'the cursor on its last line')
    -- The only match: a walk going on from there wraps round to the draft.
    child.type('<Up>')
    H.eq({ 'two a', 'two' }, child.lines(), 'a walk goes on, wherever the cursor is')
    child.type('<Down>')
    H.eq({ 'two a', 'two b' }, child.lines(), '<Down> walks back')
end)

H.test('<Down> on a line above the last moves the cursor', function()
    open({ 'first', 'second' })
    child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
    child.type('<Down>')
    H.eq(2, row(), 'down a line')
    H.eq({ 'first', 'second' }, child.lines(), 'the draft untouched')
end)

local function mode() return child.lua('return { vim.api.nvim_get_mode().mode, vim.bo.buftype }') end

H.test('<C-s> leaves Insert mode: the terminal comes up in Normal mode', function()
    open({ 'sent from insert' })
    child.type('<C-s>', 800)
    H.eq({ 'nt', 'terminal' }, mode(), 'Normal mode in the terminal, as after <CR>')
end)

H.test('so does the first send to a terminal, whose Enter waits on its screen', function()
    open({ 'first words' }, 'w')
    child.type('<C-s>', 2500)
    H.eq({ 'nt', 'terminal' }, mode(), 'no key of the user\'s goes to a question it came up on')
end)

H.test('a startinsert autocmd of the user\'s does not put the terminal in Terminal mode', function()
    child.lua([[
        vim.api.nvim_create_autocmd('BufEnter', {
            group = vim.api.nvim_create_augroup('user_startinsert', { clear = true }),
            pattern = 'term://*',
            command = 'startinsert',
        })
    ]])
    open({ 'sent with <C-s>' })
    child.type('<C-s>', 800)
    local after_send = mode()
    open({ 'sent with <CR>' })
    child.type('<Esc><CR>', 800)
    local after_cr = mode()
    open({ 'a draft' })
    child.type('<Esc><C-o>', 800)
    local after_c_o = mode()
    child.lua([[vim.api.nvim_del_augroup_by_name('user_startinsert')]])
    H.eq({ 'nt', 'terminal' }, after_send, '<C-s>')
    H.eq({ 'nt', 'terminal' }, after_cr, '<CR>')
    H.eq({ 'nt', 'terminal' }, after_c_o, '<C-o>')
end)

H.test('a terminal key mapped in Insert mode shows the terminal in Normal mode', function()
    child.lua([[require('foyer').setup({ keys = { prompt = { terminal = { n = '<C-o>', i = '<C-g>' } } } })]])
    open({ 'a draft' })
    child.type('<C-g>', 800)
    local m = mode()
    child.lua([[require('foyer').setup({ keys = { prompt = { terminal = { n = '<C-o>' } } } })]])
    H.eq({ 'nt', 'terminal' }, m, 'from Insert mode, Normal mode in the terminal')
end)

child.stop()
H.finish()
