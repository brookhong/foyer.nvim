local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ commands = {
    q = H.quiet, w = H.quiet, e = H.quiet,
    g = vim.tbl_extend('force', H.quiet, { scope = 'global' }),
} })
-- Showing a terminal reflows it, which reads as output: busy for two seconds.
foyer.is_idle = function() return true end

vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function launch(key, win_type)
    H.press(function() foyer.terminal_command({ key = key, win_type = win_type }) end)
end

-- Launch {key} and send to it, from the file: its terminal is left in the window.
local function sent(key, win_type)
    vim.cmd('stopinsert')
    if vim.api.nvim_get_current_buf() ~= file then vim.cmd('wincmd p') end
    launch(key, win_type)
    H.send('to ' .. key)
    vim.cmd('stopinsert')
    return H.state().buf
end

-- Every terminal gone, so a test starts with none running.
local function fresh()
    H.reset(file)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buf].foyer_terminal then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
end

local function press_switch()
    vim.cmd('stopinsert')
    H.feed('<C-t>')
    H.wait(100)
end

for _, win_type in ipairs({ 'float', 'split' }) do
    H.test(win_type .. ': <C-t> in a terminal shows the other one, in the same window', function()
        fresh()
        local q = sent('q', win_type)
        local win = H.state().win
        -- A draft in q's prompt, left behind <C-o>.
        H.feed('<C-o>')
        local q_prompt = H.state().buf
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'for q' })
        vim.cmd('stopinsert')
        H.feed('<C-o>')
        local w = sent('w', win_type)
        H.eq(win, H.state().win, 'w took the same window')

        press_switch()
        local s = H.state()
        H.eq(win, s.win, 'the same window')
        H.eq(q, s.buf, 'q\'s terminal')
        H.ok(s.title:find('sh · foyer.nvim', 1, true), 'the frame names it: ' .. s.title)

        -- Its prompt, with the draft, is behind <C-o>.
        H.feed('<C-o>')
        H.eq(q_prompt, H.state().buf, 'q\'s prompt')
        H.eq({ 'for q' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'with its draft')
        vim.cmd('stopinsert')
        H.feed('<C-o>')

        -- And <C-t> goes back to w's terminal, w's prompt behind it.
        press_switch()
        H.eq(win, H.state().win, 'still the same window')
        H.eq(w, H.state().buf, 'w\'s terminal')
        H.feed('<C-o>')
        H.eq(w, vim.b[H.state().buf].foyer_term, 'w\'s prompt behind it')
    end)
end

H.test('with three, <C-t> goes to the one used last before this one', function()
    fresh()
    local q = sent('q', 'split')
    local w = sent('w', 'split')
    local e = sent('e', 'split')
    press_switch()
    H.eq(w, H.state().buf, 'w, not q')
    press_switch()
    H.eq(e, H.state().buf, 'back to e, not on to q')
end)

H.test('<C-t> stays in the window, whatever the other terminal\'s win_type', function()
    -- e opens in a float of its own accord; <C-t> from a split must not.
    foyer.setup({ commands = { e = vim.tbl_extend('force', H.quiet, { win_type = 'float' }) } })
    fresh()
    local e = sent('e')
    H.ok(H.state().float, 'e in its float')
    sent('q')
    local split = H.state().win
    H.ok(not H.state().float, 'q in a split')
    vim.api.nvim_set_current_win(split)
    press_switch()
    H.eq(split, H.state().win, 'still the split')
    H.eq(e, H.state().buf, 'showing e there')
    foyer.setup({ commands = { e = H.quiet } })
end)

H.test('global terminals are left out', function()
    fresh()
    local q = sent('q', 'split')
    local split = H.state().win
    vim.cmd('wincmd p')
    launch('g')
    H.send('to g')
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(split)
    H.eq(q, H.state().buf, 'in q\'s terminal')
    press_switch()
    H.eq(q, H.state().buf, 'nowhere to go: still q\'s terminal')
end)

H.test('in a window of the user\'s, <C-t> shows the other terminal there', function()
    fresh()
    local q = sent('q', 'split')
    local w = sent('w', 'split')
    H.reset(file)
    vim.cmd('buffer ' .. q)
    local win = H.state().win
    press_switch()
    H.eq(win, H.state().win, 'the same window')
    H.eq(w, H.state().buf, 'w\'s terminal, shown in place')
    H.eq(1, H.state().wins, 'nothing opened')
end)

H.finish()
