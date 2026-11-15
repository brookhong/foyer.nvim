local H = dofile('tests/helpers.lua')

-- The stand-in for pi of status_spec.lua: it is answered, then reports each
-- line it reads as its state -- here typed into it, as a prompt is, and sent
-- with <CR>; `later` starts working a second on, of itself. Plenty of lines
-- first, so the last one is far below the top, and its cursor well above it.
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
    'for i in range(60): print("line", i)',
    -- Its cursor where a TUI keeps its input box: not on the last line.
    'sys.stdout.write("\\x1b[10A")',
    'sys.stdout.flush()',
    'for line in sys.stdin:',
    '    state = line.strip()',
    '    if not state: continue',
    '    if state == "later": time.sleep(1); state = "working"',
    '    os.write(1, ("\\x1b]7501;state=" + state + "\\x1b\\\\").encode())',
}, script)

local child = H.child(([==[
    local foyer = require('foyer')
    foyer.setup({ notify = false, commands = { p = { 'python3', %q } } })
    vim.cmd('edit LICENSE')
    foyer.terminal_command({ key = 'p', auto_start = true, switch = true })
    vim.cmd('stopinsert')
    _G.term = vim.api.nvim_get_current_buf()
    function _G.state()
        return {
            mode = vim.api.nvim_get_mode().mode,
            cursor = vim.api.nvim_win_get_cursor(0)[1],
            last = vim.api.nvim_buf_line_count(_G.term),
        }
    end
]==]):format(script))
vim.wait(2500)

local function state() return child.lua('return _G.state()') end

-- Into Terminal mode, the cursor well above the last line, as reading back
-- through the output leaves it.
local function enter()
    child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
    child.type('i', 200)
    H.eq('t', state().mode, 'in Terminal mode')
end

H.test('a run started with <CR> in Terminal mode goes back to Normal mode, following', function()
    enter()
    child.type('working<CR>', 600)
    local s = state()
    H.eq('nt', s.mode, 'Normal mode')
    H.eq(s.last, s.cursor, 'on the last line')
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "done\\n")')
    vim.wait(300)
end)

H.test('so does the keypad\'s Enter', function()
    enter()
    child.type('working<kEnter>', 600)
    H.eq('nt', state().mode, 'Normal mode')
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "done\\n")')
    vim.wait(300)
end)

H.test('answering a question with <CR> does too', function()
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "blocked\\n")')
    vim.wait(300)
    enter()
    child.type('working<CR>', 600)
    H.eq('nt', state().mode, 'Normal mode')
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "done\\n")')
    vim.wait(300)
end)

H.test('a run that starts of itself leaves Terminal mode alone', function()
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "later\\n")')
    enter()
    child.type('next message', 1300)
    H.eq(false, child.lua('return require("foyer").is_idle(_G.term, 60000)'), 'working by now')
    H.eq('t', state().mode, 'still typing')
    child.type([[<C-\><C-n>]], 200)
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "\\21done\\n")')
    vim.wait(300)
end)

H.test('<CR> long before the run starts is not what started it', function()
    enter()
    child.type('<CR>', 1500)
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "working\\n")')
    vim.wait(300)
    H.eq('t', state().mode, 'still in Terminal mode')
    child.type([[<C-\><C-n>]], 200)
    child.lua('vim.fn.chansend(vim.b[_G.term].terminal_job_id, "done\\n")')
    vim.wait(300)
end)

H.test('normal_on_submit = false leaves it in Terminal mode', function()
    child.lua('require("foyer").setup({ normal_on_submit = false })')
    enter()
    child.type('working<CR>', 600)
    H.eq('t', state().mode, 'still in Terminal mode')
    child.type([[<C-\><C-n>]], 200)
end)

child.stop()
H.finish()
