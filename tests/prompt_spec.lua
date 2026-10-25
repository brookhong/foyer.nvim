local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ commands = { q = H.quiet, n = H.noisy } })

-- Showing a terminal in a window of another size reflows it, which counts as
-- output, so even the quiet one reads as busy for two seconds after each send.
-- Only the noisy terminal is asked for real.
local is_idle = foyer.is_idle
foyer.is_idle = function(buf, ms)
    if vim.api.nvim_buf_get_name(buf):find('while', 1, true) then return is_idle(buf, ms) end
    return true
end

vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function prompt(opts)
    H.press(function() foyer.terminal_command(vim.tbl_extend('force', { key = 'q' }, opts or {})) end)
end

H.test('the prompt opens in a float, titled with the terminal', function()
    H.reset(file)
    prompt()
    local s = H.state()
    H.ok(s.prompt and s.float, 'a prompt in a float')
    H.ok(s.title:find('sh · foyer.nvim', 1, true), 'title: ' .. s.title)
end)

H.test('a sent line reaches the terminal after the clear keys', function()
    H.reset(file)
    prompt()
    H.send('echo hello')
    H.eq('\21\12', H.sent()[1], 'clear keys first')
    H.eq('echo hello\r', H.last_text(), 'then the line')
    H.ok(H.state().terminal, 'the window now shows the terminal')
end)

H.test('a multi-line prompt goes as one bracketed paste', function()
    H.reset(file)
    prompt()
    H.send({ 'first', 'second' })
    H.eq('\27[200~first\nsecond\27[201~\r', H.last_text(), 'sent')
end)

H.test('a blank prompt sends nothing', function()
    H.reset(file)
    prompt()
    H.send({ '  ', '' }, true)
    H.eq(nil, H.last_text(), 'sent')
end)

H.test('<Up> recalls history, filtered by the draft', function()
    H.reset(file)
    prompt(); H.send('alpha one')
    H.reset(file)
    prompt(); H.send('beta two')
    H.reset(file)
    prompt()
    -- Not <Esc>: on an empty draft that closes the prompt.
    vim.cmd('stopinsert')
    H.feed('<Up>')
    H.eq({ 'beta two' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'latest first')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alp' })
    H.feed('<Up>')
    H.eq({ 'alpha one' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'filtered')
end)

H.test('<C-c> closes the float and drops the draft', function()
    H.reset(file)
    prompt()
    local buf = H.state().buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a draft' })
    vim.cmd('stopinsert')
    H.feed('<Esc>')
    H.eq(buf, H.state().buf, '<Esc> keeps a draft')
    H.feed('<C-c>')
    H.eq(file, H.state().buf, 'back in the file')
    H.ok(not vim.api.nvim_buf_is_valid(buf), 'draft buffer gone')
end)

H.test('a busy terminal shows itself; <C-o> reaches a working prompt', function()
    H.reset(file)
    -- Spawn it and let it come up and start printing.
    foyer.terminal_command({ key = 'n', command = ':' })
    H.wait(1500)
    H.reset(file)
    H.press(function() foyer.terminal_command({ key = 'n' }) end)
    H.ok(H.state().terminal, 'busy: the terminal is shown')
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.ok(H.state().prompt, '<C-o> lands in the prompt')
    H.send('hi')
    H.eq('hi\r', H.last_text(), '<CR> from there sends')
end)

H.test('a sidebar is reused rather than stacked', function()
    H.reset(file)
    prompt({ win_type = 'sidebar' })
    local first = H.state()
    H.eq(2, first.wins, 'one sidebar beside the file')
    vim.cmd('wincmd p')
    prompt({ win_type = 'sidebar' })
    H.eq(2, H.state().wins, 'still one sidebar')
    H.eq(first.win, H.state().win, 'the same window')
end)

H.test('a sidebar taken over for a file is left to it, and its successor kept', function()
    H.reset(file)
    local function sidebar() H.press(function() foyer.terminal_command({ key = 'q', win_type = 'sidebar' }) end) end
    sidebar()
    local taken = H.state().win
    vim.cmd('stopinsert | edit LICENSE')
    vim.cmd('wincmd p')
    sidebar()
    local successor = H.state().win
    H.ok(successor ~= taken, 'a new sidebar rather than the user\'s window')
    H.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(taken)):find('LICENSE$'), 'LICENSE left where it was')
    vim.cmd('stopinsert')
    vim.api.nvim_win_close(taken, true)
    vim.cmd('wincmd p')
    sidebar()
    H.eq(successor, H.state().win, 'the successor is still the sidebar')
    H.eq(2, H.state().wins, 'no third window')
end)

for _, win_type in ipairs({ 'float', 'sidebar' }) do
    H.test(win_type .. ': after a send, <C-o> finds the prompt empty and the selection gone', function()
        H.reset(file)
        -- A selection, so there is something that must not ride along again.
        H.press(function() foyer.terminal_command({ key = 'q', win_type = win_type }) end, '3GV')
        local prompt_buf = H.state().buf
        H.ok(H.state().title:find('+ README.md:3', 1, true), 'the selection advertised: ' .. H.state().title)
        H.send('first question')
        H.ok(H.last_text():find('Selected in my editor', 1, true), 'the first send carries it')

        vim.cmd('stopinsert')
        H.feed('<C-o>')
        local s = H.state()
        H.eq(prompt_buf, s.buf, 'back in the same prompt')
        H.eq({ '' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'empty')
        H.ok(not s.title:find('README.md:3', 1, true), 'the frame no longer offers it: ' .. s.title)
        H.ok(s.title:find('Ctrl-s to send command', 1, true), 'the prompt\'s own frame: ' .. s.title)

        H.feed('<Up>')
        H.eq({ 'first question' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), '<Up> recalls what was sent')

        H.send('a follow-up')
        H.eq('a follow-up\r', H.last_text(), 'sent alone')
    end)
end

H.finish()
