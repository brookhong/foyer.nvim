local H = dofile('tests/helpers.lua')

-- A stand-in for pi: it asks whether the terminal listens for program
-- status, as pi does, along with the device attributes it asks for too, and
-- prints what it learnt. Then each line it reads is a state to report,
-- `blocked Trust this folder?` with a message after it.
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
    'first = got.split(b"\\x1b[")[0]',
    'print("supported" if first.startswith(b"\\x1b]7501;?") else "unsupported", flush=True)',
    'for line in sys.stdin:',
    '    state, _, msg = line.strip().partition(" ")',
    '    fields = "state=" + state',
    '    if msg: fields += ":msg=" + base64.b64encode(msg.encode()).decode()',
    '    os.write(1, ("\\x1b]7501;" + fields + "\\x1b\\\\").encode())',
}, script)

local child = H.child(([[
    local foyer = require('foyer')
    foyer.setup({ picker_delay = 0, commands = { s = { 'python3', %q } } })
    vim.cmd('edit LICENSE')
    _G.file = vim.api.nvim_get_current_buf()
    _G.notices, _G.events = {}, {}
    vim.notify = function(msg, level) table.insert(_G.notices, { msg = msg, level = level }) end
    vim.api.nvim_create_autocmd('User', { pattern = 'FoyerStatus', callback = function(ev)
        table.insert(_G.events, ev.data)
    end })
    -- Started, and its prompt put away: the terminal is in no window.
    foyer.prompt({ key = 's', auto_start = true })
    vim.cmd('stopinsert')
    vim.api.nvim_win_close(0, true)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].foyer_terminal then _G.term = b end
    end
    function _G.report(line)
        vim.fn.chansend(vim.b[_G.term].terminal_job_id, line .. '\n')
    end
]]):format(script))
vim.wait(2000)

-- Report {line}, and wait for it to be seen.
local function report(line)
    child.lua('_G.notices = {}; _G.events = {}; _G.report(...)', line)
    vim.wait(300)
end
local function notices() return child.lua('return _G.notices') end
local function events() return child.lua('return _G.events') end

H.test('a foyer terminal says it listens for program status', function()
    local lines = child.lua('return vim.api.nvim_buf_get_lines(_G.term, 0, -1, false)')
    H.ok(vim.tbl_contains(lines, 'supported'), 'the program was answered: ' .. vim.inspect(lines))
end)

H.test('done, out of view, is told', function()
    report('working')
    H.eq({}, notices(), 'nothing while working')
    report('done my session')
    H.eq({ { msg = 'foyer.nvim: python3 · foyer.nvim is done', level = vim.log.levels.INFO } }, notices(), 'notices')
end)

H.test('waiting for the user, and failing, are told with what they said', function()
    report('blocked Trust this folder?')
    H.eq({ { msg = 'foyer.nvim: python3 · foyer.nvim is waiting for you: Trust this folder?',
        level = vim.log.levels.WARN } }, notices(), 'blocked')
    report('error rate limited')
    H.eq({ { msg = 'foyer.nvim: python3 · foyer.nvim failed: rate limited', level = vim.log.levels.ERROR } },
        notices(), 'error')
end)

H.test('every change is a FoyerStatus event', function()
    report('working')
    local e = events()
    H.eq(1, #e, 'one event')
    H.eq('working', e[1].state, 'state')
    H.eq('s', e[1].key, 'key')
    H.eq(child.lua('return _G.term'), e[1].buf, 'buf')
    H.ok(e[1].project and e[1].project:find('foyer.nvim', 1, true), 'project')
    report('working')
    H.eq({}, events(), 'none for the same state again')
end)

H.test('the state is what is_idle() goes by', function()
    report('working')
    vim.wait(1200)
    H.eq(false, child.lua('return require("foyer").is_idle(_G.term, 1000)'), 'busy while working, quiet or not')
    report('done')
    H.eq(true, child.lua('return require("foyer").is_idle(_G.term, 60000)'), 'idle once done, however recent')
end)

H.test('the picker shows the state', function()
    report('blocked')
    local lines = child.lua([[
        local seen
        local getchar = vim.fn.getchar
        vim.fn.getchar = function(peek)
            if peek then return getchar(peek) end
            for _, w in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(w).relative ~= '' then
                    seen = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
                end
            end
            return 27
        end
        require('foyer').prompt()
        vim.fn.getchar = getchar
        return seen
    ]])
    H.ok(lines and lines[1]:find('● blocked', 1, true), 'tagged: ' .. vim.inspect(lines))
end)

H.test('in view, nothing is told', function()
    report('working')
    child.lua('vim.api.nvim_set_current_buf(_G.term)')
    report('done')
    H.eq({}, notices(), 'notices')
    H.eq(1, #events(), 'the event all the same')
    child.lua('vim.api.nvim_set_current_buf(_G.file)')
end)

H.test('with notify_status = false, nothing is told, and the event still comes', function()
    child.lua('require("foyer").setup({ notify_status = false })')
    report('working')
    report('done')
    H.eq({}, notices(), 'notices')
    H.eq(1, #events(), 'the event')
end)

H.test('clear drops the state, for output to go by again', function()
    report('working')
    report('clear')
    H.eq('clear', (events()[1] or {}).state, 'the event says so')
    H.eq(true, child.lua('return require("foyer").is_idle(_G.term, 60000) == false'),
        'busy while output is recent, the timing guess again')
    vim.wait(1200)
    H.eq(true, child.lua('return require("foyer").is_idle(_G.term, 1000)'), 'idle once quiet')
end)

H.test('a program that exits is busy no more', function()
    report('working')
    H.eq(false, child.lua('return require("foyer").is_idle(_G.term, 1000)'), 'working')
    -- Gone without a word, as a program killed is.
    child.lua('vim.fn.jobstop(vim.b[_G.term].terminal_job_id)')
    vim.wait(1000)
    H.ok(child.lua('return vim.fn.jobwait({ vim.b[_G.term].terminal_job_id }, 0)[1] ~= -1'), 'it exited')
    -- Its last words are output, which the timing guess goes by once quiet.
    vim.wait(1200)
    H.eq(true, child.lua('return require("foyer").is_idle(_G.term, 1000)'), 'idle')
end)

child.stop()
H.finish()
