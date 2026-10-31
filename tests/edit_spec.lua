local H = dofile('tests/helpers.lua')
local foyer = H.foyer({})

H.test('edit_selection() edits the selection in a float and writes it back', function()
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'keep', 'one', 'two', 'keep' })
    H.press(function() foyer.edit_selection() end, '2GVj')
    local s = H.state()
    H.ok(s.float, 'a float')
    H.eq({ 'one', 'two' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'the selection, without a trailing blank')
    -- Sized from the selection: its rows, or its wrapped length plus two.
    H.eq(3, vim.api.nvim_win_get_height(s.win), 'sized from the selection, not the default 10')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ONE', 'TWO', 'THREE' })
    vim.cmd('stopinsert')
    H.feed('<CR>')
    H.eq(buf, H.state().buf, 'back in the buffer')
    H.eq({ 'keep', 'ONE', 'TWO', 'THREE', 'keep' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'written back')
end)

H.test('<C-o> in edit_selection()\'s float leads nowhere', function()
    vim.cmd('edit README.md')
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one' })
    H.press(function() foyer.edit_selection() end, 'V')
    local s = H.state()
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.eq(s.buf, H.state().buf, 'still the selection, not a file from the jump list')
    H.feed('<C-c>')
end)

H.test('edit_input() lifts the half-typed line and puts the edit back', function()
    vim.cmd('enew')
    vim.fn.termopen({ 'sh', '-c', 'PS1="$ " exec sh -i' }, { env = { ENV = '' } })
    local term = vim.api.nvim_get_current_buf()
    H.wait(500)
    vim.fn.chansend(vim.b[term].terminal_job_id, 'echo half')
    H.wait(300)
    -- Where leaving terminal mode puts the cursor: on what was typed last.
    -- Headless, the terminal's cursor is not carried over, so put it there.
    vim.api.nvim_win_set_cursor(0, { 1, #'$ echo half' })
    foyer.edit_input()
    -- It erases the line and watches the cursor settle, on timers.
    vim.wait(3000, function() return H.state().prompt end, 50)
    local s = H.state()
    H.ok(s.prompt and s.float, 'a prompt float')
    -- Trimmed: the start of the line is found from where the cursor settles
    -- in terminal mode, which a headless Neovim tracks a column out. The
    -- column is the heuristic's business (it is experimental); the flow is
    -- what this checks.
    H.eq({ 'echo half' }, vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(0, 0, -1, false)), 'the half-typed line')
    H.send('echo whole')
    -- Put back on the input line, not run.
    H.eq('echo whole', H.last_text(), 'sent back without Enter')
end)

H.finish()
