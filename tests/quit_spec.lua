local H = dofile('tests/helpers.lua')

-- The stand-in for pi of status_spec.lua, reporting each line it reads as
-- its state, and printing nothing of its own.
local script = vim.fn.stdpath('cache') .. '/status.py'
vim.fn.mkdir(vim.fn.fnamemodify(script, ':h'), 'p')
vim.fn.writefile({
    'import os, select, sys, termios, time, tty',
    'fd = sys.stdin.fileno()',
    'old = termios.tcgetattr(fd)',
    'tty.setraw(fd)',
    'os.write(1, b"\\x1b]7501;?\\x1b\\\\\\x1b[c")',
    'got, end = b"", time.time() + 1',
    'while time.time() < end and b"c" not in got.split(b"\\x1b[")[-1]:',
    '    if select.select([fd], [], [], 0.1)[0]: got += os.read(fd, 1024)',
    'termios.tcsetattr(fd, termios.TCSADRAIN, old)',
    'for line in sys.stdin:',
    '    os.write(1, ("\\x1b]7501;state=" + line.strip() + "\\x1b\\\\").encode())',
}, script)

-- A child with terminal {key} started from LICENSE, its prompt put away:
-- n prints all the time, q prints a prompt and then nothing, p reports its
-- state.
local function start(key, opts)
    local child = H.child(([==[
        local foyer = require('foyer')
        foyer.setup({
            commands = {
                n = { %q, %q },
                q = { %q, %q },
                p = { 'python3', %q },
            },
        })
        vim.cmd('edit LICENSE')
        _G.notices = {}
        vim.notify = function(msg) table.insert(_G.notices, msg) end
        foyer.terminal_command({ key = %q, auto_start = true })
        vim.cmd('stopinsert')
        vim.api.nvim_win_close(0, true)
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.b[b].foyer_terminal then _G.term = b end
        end
        vim.cmd('edit README.md | edit LICENSE')
        _G.alt = vim.fn.bufnr('#')
    ]==]):format(H.noisy[1], H.noisy[2], H.quiet[1], H.quiet[2], script, key))
    if opts then child.lua('require("foyer").setup(...)', opts) end
    return child
end

-- Type :{cmd} there, as the user would: true if it quit, else false, the
-- error it gave, and what foyer said.
local function quits(child, cmd)
    child.lua('_G.notices = {}; vim.v.errmsg = ""')
    pcall(child.type, ':' .. cmd .. '<CR>', 400)
    local alive = pcall(child.lua, 'return 1')
    if not alive then return true end
    return false, child.lua('return vim.v.errmsg'), child.lua('return _G.notices')
end

H.test('with an agent printing still, :qa is refused, and says which', function()
    local child = start('n')
    vim.wait(1500)
    local quit, err, notices = quits(child, 'qa')
    H.eq(false, quit, 'quit')
    H.eq('E162: No write since last change for buffer "foyer: sh · foyer.nvim is working"', err, 'refused')
    H.eq({ 'foyer.nvim: sh · foyer.nvim is working; :qa! quits anyway, and ends it' }, notices, 'notices')
    H.eq(child.lua('return vim.fn.bufnr("LICENSE")'), child.lua('return vim.api.nvim_get_current_buf()'),
        'still on the file')
    H.eq(child.lua('return _G.alt'), child.lua('return vim.fn.bufnr("#")'), 'and its alternate file as it was')
    H.eq(false, child.lua([[
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].modified then return true end
        end
        return false
    ]]), 'nothing left unsaved after')
    -- Written by :wqa, as by a :confirm dialog's Yes, it says why too.
    local wqa, _, said = quits(child, 'wqa')
    H.eq(false, wqa, ':wqa refused too')
    H.eq({ 'foyer.nvim: sh · foyer.nvim is working; :qa! quits anyway, and ends it' }, said, 'and said why')
    H.eq(false, (quits(child, 'quit')), ':q in the last window refused too')
    H.eq(true, (quits(child, 'qa!')), ':qa! quits')
end)

H.test('closing a window is no quit', function()
    local child = start('n')
    vim.wait(1500)
    child.lua('vim.cmd("split")')
    H.eq(false, (quits(child, 'quit')), 'still running')
    H.eq(1, child.lua('return #vim.api.nvim_list_wins()'), 'the window closed')
    H.eq({}, child.lua('return _G.notices'), 'nothing said')
    child.stop()
end)

H.test('an agent gone quiet does not hold the quit', function()
    local child = start('q')
    vim.wait(3500)
    H.eq(true, (quits(child, 'qa')), 'quit')
end)

H.test('an agent waiting for the user holds it, by its own report', function()
    local child = start('p')
    vim.wait(4500)
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "blocked\\n")')
    vim.wait(300)
    local quit, _, notices = quits(child, 'qa')
    H.eq(false, quit, 'quit')
    H.eq({ 'foyer.nvim: python3 · foyer.nvim is waiting for you; :qa! quits anyway, and ends it' }, notices,
        'notices')
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "done\\n")')
    vim.wait(300)
    H.eq(true, (quits(child, 'qa')), 'once done, it quits')
end)

H.test('quit_guard = false lets it quit', function()
    local child = start('n', { quit_guard = false })
    vim.wait(1500)
    H.eq(true, (quits(child, 'qa')), 'quit')
end)

H.finish()
