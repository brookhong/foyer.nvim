local H = dofile('tests/helpers.lua')

-- The stand-in for pi of status_spec.lua: it is answered, then reports each
-- line it reads as its state.
local script = vim.fn.stdpath('cache') .. '/status.py'
vim.fn.mkdir(vim.fn.fnamemodify(script, ':h'), 'p')
vim.fn.writefile({
    'import base64, os, select, sys, termios, time, tty',
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

-- Two agents, s and t, each started in tab page 1 and shown in its split.
local child = H.child(([==[
    local foyer = require('foyer')
    local agent = { 'python3', %q }
    foyer.setup({ notify = false, commands = { s = agent, t = vim.deepcopy(agent) } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE')
    _G.file = vim.api.nvim_get_current_buf()
    _G.term = {}
    function _G.start(key)
        foyer.terminal_command({ key = key, auto_start = true })
        vim.cmd('stopinsert')
        _G.term[key] = vim.b.foyer_term
    end
    function _G.report(key, state)
        vim.fn.chansend(vim.b[_G.term[key]].terminal_job_id, state .. '\n')
    end
    function _G.marks()
        local out = {}
        for i = 1, vim.fn.tabpagenr('$') do out[i] = foyer.tab_mark(i) end
        return out
    end
]==]):format(script))
vim.wait(300)

local function report(key, state)
    child.lua('_G.report(...)', key, state)
    vim.wait(300)
end
local function marks() return child.lua('return _G.marks()') end
local function tabvar(n)
    return child.lua('return vim.t[vim.api.nvim_list_tabpages()[...]].foyer_status', n)
end

child.lua('_G.start("s")')
vim.wait(1500)

H.test('done in another tab page marks it, until the user goes there', function()
    child.lua('vim.cmd("tabnew README.md")')
    report('s', 'working')
    report('s', 'done')
    H.eq({ '✓', '' }, marks(), 'tab page 1 marked')
    H.eq('done', tabvar(1), 'vim.t.foyer_status')
    child.lua('vim.cmd("tabprevious")')
    vim.wait(100)
    H.eq({ '', '' }, marks(), 'seen, gone')
    H.eq(vim.NIL, tabvar(1), 'and the variable with it')
end)

H.test('in the current tab page, nothing is marked', function()
    report('s', 'working')
    report('s', 'done')
    H.eq({ '', '' }, marks(), 'marks')
end)

H.test('working again takes the mark away', function()
    child.lua('vim.cmd("tabnext")')
    report('s', 'blocked')
    H.eq({ '?', '' }, marks(), 'blocked')
    report('s', 'working')
    H.eq({ '', '' }, marks(), 'working')
    child.lua('vim.cmd("tabprevious")')
end)

H.test('the most urgent of a tab page\'s agents is the one shown', function()
    child.lua('_G.start("t")')
    vim.wait(1500)
    child.lua('vim.cmd("tabnext")')
    report('s', 'done')
    report('t', 'error')
    H.eq({ '✗', '' }, marks(), 'error over done')
    report('t', 'working')
    H.eq({ '✓', '' }, marks(), 'done once the error is past')
    child.lua('vim.cmd("tabprevious")')
end)

H.test('an agent shown nowhere marks the tab page it was last used in', function()
    -- Its window put away, in tab page 1.
    child.lua([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if buf == _G.term.t or vim.b[buf].foyer_term == _G.term.t then vim.api.nvim_win_close(win, true) end
        end
    ]])
    child.lua('vim.cmd("tabnext")')
    report('t', 'done')
    H.eq({ '✓', '' }, marks(), 'tab page 1 marked')
    child.lua('vim.cmd("tabprevious")')
end)

H.test('the agent seen from another tab page takes its mark away', function()
    child.lua('vim.cmd("tabnext")')
    report('s', 'working')
    report('s', 'done')
    H.eq({ '✓', '' }, marks(), 'tab page 1 marked')
    -- Launched from tab page 2: its window moves here, and is looked at.
    child.lua('require("foyer").terminal_command({ key = "s" }); vim.cmd("stopinsert")')
    vim.wait(300)
    H.eq({ '', '' }, marks(), 'gone')
    -- Put away, then used last in tab page 1, and looked at again from tab
    -- page 2 in a window of the user's.
    child.type('<C-c>', 300)
    child.lua('vim.cmd("tabprevious")')
    child.lua('require("foyer").terminal_command({ key = "s" }); vim.cmd("stopinsert")')
    vim.wait(300)
    child.type('<C-c>', 300)
    report('s', 'working')
    child.lua('vim.cmd("tabnext")')
    report('s', 'done')
    H.eq({ '✓', '' }, marks(), 'tab page 1 marked again')
    child.lua('vim.cmd("buffer " .. _G.term.s)')
    vim.wait(100)
    H.eq({ '', '' }, marks(), 'gone again')
    child.lua('vim.cmd("buffer " .. _G.file); vim.cmd("tabprevious")')
end)

H.test('tabline = true puts the marks in a tab line of foyer\'s', function()
    child.lua('require("foyer").setup({ tabline = true })')
    H.eq("%!v:lua.require'foyer.tabline'.render()", child.lua('return vim.o.tabline'), 'set')
    -- Used last in tab page 1.
    child.lua('require("foyer").terminal_command({ key = "s" }); vim.cmd("stopinsert")')
    vim.wait(300)
    child.type('<C-c>', 300)
    child.lua('vim.cmd("tabnext")')
    report('s', 'working')
    report('s', 'done')
    local line = child.lua('return vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true }).str')
    H.ok(line:find('^ ✓ '), 'tab page 1, marked: ' .. line)
    H.ok(line:find('X$'), 'an X to close with, for two tab pages: ' .. line)
    child.lua('vim.cmd("tabprevious")')
    child.lua('require("foyer").setup({ tabline = false })')
    H.eq('', child.lua('return vim.o.tabline'), 'given up')
end)

H.test('a tab line of the user\'s own is left alone', function()
    child.lua('vim.o.tabline = "mine"; require("foyer").setup({ tabline = true })')
    H.eq('mine', child.lua('return vim.o.tabline'), 'tabline')
end)

child.stop()
H.finish()
