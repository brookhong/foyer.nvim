local H = dofile('tests/helpers.lua')

-- Insert mode needs a real main loop: keys typed into a child Neovim. Its
-- history for the terminal: 'one', then two lines, then 'three', newest last.
local child = H.child([[
    local foyer = require('foyer')
    foyer.setup({ commands = { q = { 'sh', '-c "echo up; cat >/dev/null"' } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit README.md')
    _G.readme = vim.api.nvim_get_current_buf()
    -- A fresh prompt, in Insert mode, holding {lines}.
    function _G.prompt(lines)
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= '' then vim.api.nvim_win_close(w, true) end
        end
        vim.cmd('stopinsert | silent! only')
        vim.api.nvim_set_current_buf(_G.readme)
        foyer.terminal_command({ key = 'q' })
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
local function open(lines)
    child.type('<C-\\><C-n>')
    child.lua('prompt(...)', lines)
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

child.stop()
H.finish()
