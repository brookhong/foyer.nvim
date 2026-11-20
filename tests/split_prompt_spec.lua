local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ commands = {
    q = H.quiet, n = H.noisy,
    g = vim.tbl_extend('force', H.quiet, { scope = 'global' }),
} })

-- As in prompt_spec: only the noisy terminal is asked whether it is busy.
local is_idle = foyer.is_idle
foyer.is_idle = function(buf, ms)
    if vim.api.nvim_buf_get_name(buf):find('while', 1, true) then return is_idle(buf, ms) end
    return true
end

vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function prompt(key)
    H.press(function() foyer.prompt({ key = key or 'q' }) end)
end

-- The terminal in the split foyer keeps, shown by a send from its prompt.
local function terminal(key)
    H.reset(file)
    prompt(key)
    H.send('hello')
    vim.cmd('stopinsert')
    H.ok(H.state().terminal, 'the terminal took the split')
    return H.state().buf, H.state().win
end

local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end

H.test('O in a terminal opens its prompt in a split above, the terminal kept below', function()
    local term, below = terminal()
    local wins = H.state().wins
    H.feed('O')
    local s = H.state()
    H.ok(s.prompt, 'in a prompt')
    H.ok(s.win ~= below, 'a window of its own')
    H.eq(wins + 1, s.wins, 'one more window')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal still in view')
    local row = vim.api.nvim_win_get_position(s.win)[1]
    H.ok(row < vim.api.nvim_win_get_position(below)[1], 'above it')
    local top, bottom = vim.api.nvim_win_get_height(s.win), vim.api.nvim_win_get_height(below)
    H.ok(math.abs(top - bottom) <= 1, ('half each: %d and %d'):format(top, bottom))
    H.ok(s.title:find('Ctrl-s to send command', 1, true), 'the prompt\'s frame: ' .. s.title)
end)

-- A real main loop: feedkeys() here ends the Insert mode a key starts.
H.test('the split opens in Insert mode, at the end of the draft', function()
    local child = H.child([[
        local foyer = require('foyer')
        foyer.setup({ commands = { q = { 'sh', '-c "echo up; cat >/dev/null"' } } })
        foyer.is_idle = function() return true end
        vim.cmd('edit README.md')
        foyer.prompt({ key = 'q' })
    ]])
    vim.wait(500)
    child.lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'half written' })
        vim.cmd('stopinsert')
    ]])
    child.type('<C-o>', 300)
    child.type('O', 300)
    local s = child.lua([[
        return {
            prompt = vim.b.foyer_prompt == true,
            mode = vim.api.nvim_get_mode().mode,
            cursor = vim.api.nvim_win_get_cursor(0),
        }
    ]])
    child.stop()
    H.ok(s.prompt, 'in the prompt')
    H.eq('i', s.mode, 'Insert mode')
    H.eq({ 2, 12 }, s.cursor, 'at the end of the last line')
end)

H.test('the draft behind <C-o> comes up in the split, and what it carries with it', function()
    H.reset(file)
    H.press(function() foyer.prompt({ key = 'q' }) end, '3GV')
    local draft = H.state().buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'half written' })
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.ok(H.state().terminal, 'the terminal')
    H.feed('O')
    local s = H.state()
    H.eq(draft, s.buf, 'the same prompt')
    H.eq({ 'half written' }, lines(), 'the draft kept')
    H.ok(s.title:find('+ README.md:3', 1, true), 'the selection still on it: ' .. s.title)
    vim.cmd('stopinsert')
    H.send('half written')
    H.ok(H.last_text():find('Selected in my editor', 1, true), 'and sent with it')
end)

H.test('a send closes the split, the terminal below taking the cursor', function()
    local term, below = terminal()
    local wins = H.state().wins
    H.feed('O')
    local p = H.state().buf
    H.send('from above')
    H.eq('from above\r', H.last_text(), 'sent')
    local s = H.state()
    H.eq(below, s.win, 'in the terminal\'s window')
    H.eq(term, s.buf, 'the terminal')
    H.eq(wins, s.wins, 'the split gone')
    H.eq('nt', vim.api.nvim_get_mode().mode, 'Normal mode')
    H.feed('<C-o>')
    H.eq(p, H.state().buf, '<C-o> finds the prompt')
    H.eq({ '' }, lines(), 'empty')
end)

H.test('<C-o> goes between the split and the terminal below, neither swapped', function()
    local term, below = terminal()
    H.feed('O')
    local above, p = H.state().win, H.state().buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a draft' })
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.eq(below, H.state().win, 'down to the terminal')
    H.eq(p, vim.api.nvim_win_get_buf(above), 'the split keeps the prompt')
    H.eq(term, H.state().buf, 'the terminal left as it was')
    H.feed('<C-o>')
    H.eq(above, H.state().win, 'back up')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal still below')
    H.eq({ 'a draft' }, lines(), 'the draft kept')
end)

H.test('<C-c> and <Esc> close the split only, back to the terminal', function()
    for _, key in ipairs({ '<C-c>', '<Esc>' }) do
        local term, below = terminal()
        local wins = H.state().wins
        H.feed('O')
        vim.cmd('stopinsert')
        H.feed(key)
        local s = H.state()
        H.eq(wins, s.wins, key .. ': the split gone')
        H.eq(below, s.win, key .. ': in the terminal\'s window')
        H.eq(term, s.buf, key .. ': the terminal')
    end
end)

H.test('O with the split open goes to it rather than opening another', function()
    local _, below = terminal()
    H.feed('O')
    local above, wins = H.state().win, H.state().wins
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(below)
    H.feed('O')
    H.eq(above, H.state().win, 'the one open')
    H.eq(wins, H.state().wins, 'no other')
end)

H.test('a busy terminal still gets its prompt above', function()
    local term, below = terminal('n')
    vim.wait(1500)
    H.ok(not foyer.is_idle(term, 2000), 'busy')
    H.feed('O')
    H.ok(H.state().prompt, 'a prompt')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal below')
    vim.cmd('stopinsert')
end)

H.test('in a window of the user\'s, a fresh prompt above, for that terminal', function()
    local term = terminal()
    H.reset(file)
    vim.cmd('buffer ' .. term)
    local below = H.state().win
    H.feed('O')
    local s = H.state()
    H.ok(s.prompt, 'a prompt')
    H.eq({ '' }, lines(), 'fresh')
    H.eq(term, vim.b[s.buf].foyer_term, 'for this terminal')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal below')
    H.send('hi')
    H.eq(below, H.state().win, 'back in the user\'s window')
end)

H.test('a global terminal\'s prompt opens above it too', function()
    H.reset(file)
    prompt('g')
    H.send('hello')
    vim.cmd('stopinsert')
    local term, below = H.state().buf, H.state().win
    H.ok(H.state().terminal, 'the terminal')
    H.feed('O')
    H.ok(H.state().prompt and H.state().win ~= below, 'a prompt in a split')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal below')
end)

H.test('the terminal\'s close keys put the split away with it', function()
    local _, below = terminal()
    H.feed('O')
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(below)
    H.feed('<CR>')
    local s = H.state()
    H.eq(1, s.wins, 'the file alone')
    H.eq(file, s.buf, 'the file')
end)

H.test('a fresh prompt above is the one the terminal\'s <C-o> goes to', function()
    local term = terminal()
    H.reset(file)
    vim.cmd('buffer ' .. term)
    local below = H.state().win
    H.feed('O')
    local above = H.state().win
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(below)
    H.feed('<C-o>')
    H.eq(above, H.state().win, 'up to the split')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal still below')
end)

H.test('launched again with the split open, the split is where it goes', function()
    local term, below = terminal()
    H.feed('O')
    local above, p = H.state().win, H.state().buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a draft' })
    vim.cmd('stopinsert')
    vim.cmd('wincmd t')
    H.eq(file, H.state().buf, 'from the file')
    prompt()
    H.eq(above, H.state().win, 'the split')
    H.eq(p, H.state().buf, 'its prompt')
    H.eq({ 'a draft' }, lines(), 'the draft kept')
    H.eq(term, vim.api.nvim_win_get_buf(below), 'the terminal still below')
end)

H.test('no room above the terminal: said so, nothing opened', function()
    local term, below = terminal()
    vim.api.nvim_win_set_height(below, 2)
    local wins = H.state().wins
    local notify, said = vim.notify, nil
    vim.notify = function(msg) said = msg end
    local ok, err = pcall(H.feed, 'O')
    vim.notify = notify
    H.ok(ok, 'no error: ' .. tostring(err))
    H.ok(said and said:find('no room', 1, true), 'said so: ' .. tostring(said))
    H.eq(wins, H.state().wins, 'no window')
    H.eq(term, H.state().buf, 'still in the terminal')
    vim.api.nvim_win_set_height(below, vim.o.lines)
end)

H.test('launched from another tab page, the split and its terminal move there together', function()
    local term, below = terminal()
    H.feed('O')
    local p = H.state().buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a draft' })
    vim.cmd('stopinsert')
    local first = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabnew')
    vim.api.nvim_set_current_buf(file)
    prompt()
    H.eq(p, H.state().buf, 'the draft brought here')
    H.eq({ 'a draft' }, lines(), 'as it was')
    H.ok(not vim.api.nvim_win_is_valid(below), 'the terminal\'s window given up there')
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(first)) do
        H.ok(vim.api.nvim_win_get_buf(win) ~= term, 'the terminal no longer shown there')
    end
    vim.cmd('stopinsert | tabonly')
end)

H.test('moved to another tab page, the split leaves a file put in below it alone', function()
    local _, below = terminal()
    H.feed('O')
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(below)
    vim.cmd('edit LICENSE')
    local license = H.state().buf
    vim.cmd('tabnew')
    vim.api.nvim_set_current_buf(file)
    prompt()
    H.ok(H.state().prompt, 'the prompt brought here')
    H.ok(vim.api.nvim_win_is_valid(below), 'the window kept')
    H.eq(license, vim.api.nvim_win_get_buf(below), 'with its file')
    vim.cmd('stopinsert | tabonly')
end)

H.test('the split refuses any other buffer', function()
    terminal()
    H.feed('O')
    local above, p = H.state().win, H.state().buf
    vim.cmd('stopinsert')
    H.ok(not pcall(vim.cmd, 'edit LICENSE'), ':edit refused')
    H.eq(p, vim.api.nvim_win_get_buf(above), 'the prompt still in it')
end)

H.test('the split goes once its terminal is not shown below it', function()
    for _, case in ipairs({
        { 'the window closed', function() vim.cmd('close') end },
        { 'a file put in it', function() vim.cmd('edit LICENSE') end },
        { 'another buffer put in it', function() vim.api.nvim_set_current_buf(file) end },
    }) do
        local _, below = terminal()
        H.feed('O')
        local above = H.state().win
        vim.cmd('stopinsert')
        vim.api.nvim_set_current_win(below)
        case[2]()
        H.wait(50)
        H.ok(not vim.api.nvim_win_is_valid(above), case[1] .. ': the split gone')
    end
end)

H.test('the last window left, the split becomes an ordinary prompt', function()
    local term, below = terminal()
    H.feed('O')
    local above, p = H.state().win, H.state().buf
    vim.cmd('stopinsert')
    vim.cmd('only')
    H.ok(not vim.api.nvim_win_is_valid(below), 'the terminal\'s window closed')
    H.wait(50)
    H.ok(vim.api.nvim_win_is_valid(above), 'still open')
    H.ok(not vim.wo[above].winfixbuf, 'takes other buffers again')
    H.feed('<C-o>')
    H.eq(term, H.state().buf, '<C-o> shows the terminal in it')
    H.feed('<C-o>')
    H.eq(p, H.state().buf, 'and back')
end)

H.test('forced to show a file, the split is the user\'s window', function()
    local _, below = terminal()
    H.feed('O')
    local above = H.state().win
    vim.cmd('stopinsert')
    vim.cmd('edit! LICENSE')
    H.wait(50)
    H.ok(vim.api.nvim_win_is_valid(above), 'the window kept')
    H.ok(vim.api.nvim_win_is_valid(below), 'the terminal\'s too')
    H.ok(not require('foyer.window').is_foyer_window(above), 'no longer foyer\'s')
end)

H.finish()
