local H = dofile('tests/helpers.lua')

-- Fake agents, logging what reaches them to a file named on their command
-- line, one per agent.
--
-- agent.py takes a while to start and, like many, throws away whatever was
-- typed while it did: it reads nothing until it prints `ready`. After that it
-- shows what is typed, as an input box does.
--
-- dialog.py comes up on a question instead, the way an agent asks whether to
-- trust a workspace: it shows nothing of what is typed, and takes Enter as the
-- answer.
local dir = vim.fn.stdpath('cache')
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({
    'import sys, time, termios, tty',
    'log = open(sys.argv[1], "a")',
    'time.sleep(1.5)',
    'termios.tcflush(sys.stdin, termios.TCIFLUSH)',
    'tty.setraw(sys.stdin)',
    'sys.stdout.write("\\x1b[?2004h> ready\\r\\n> "); sys.stdout.flush()',
    'log.write("ready\\n"); log.flush()',
    'buf = b""',
    'while True:',
    '    c = sys.stdin.buffer.read(1)',
    '    buf += c',
    '    if c == b"\\r":',
    '        log.write("got %r\\n" % buf.replace(b"\\x1b[200~", b"").replace(b"\\x1b[201~", b"")); log.flush()',
    '        buf = b""',
    '        sys.stdout.write("\\r\\n> ")',
    '    elif c >= b" ":',
    '        sys.stdout.buffer.write(c)',
    '    sys.stdout.flush()',
}, dir .. '/agent.py')
vim.fn.writefile({
    'import sys, tty',
    'log = open(sys.argv[1], "a")',
    'tty.setraw(sys.stdin)',
    'sys.stdout.write("Trust this workspace?\\r\\n> Trust, continue\\r\\n  Do not trust, exit\\r\\n"); sys.stdout.flush()',
    'while True:',
    '    c = sys.stdin.buffer.read(1)',
    '    if c == b"\\r":',
    '        log.write("ENTER answered the dialog\\n"); log.flush()',
}, dir .. '/dialog.py')
local function fake(script, name) return { 'python3', ('%s/%s %s/%s.log'):format(dir, script, dir, name) } end

local notes = {}
vim.notify = function(msg) table.insert(notes, msg) end

local foyer = H.foyer({ commands = {
    a = fake('agent.py', 'a'),
    b = fake('agent.py', 'b'),
    d = fake('dialog.py', 'd'),
    s = { 'sh', '-c "cat >/dev/null"' },
} })
vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function received(name)
    local log = ('%s/%s.log'):format(dir, name)
    return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
end
local function wait_for(name, line)
    vim.wait(8000, function() return vim.tbl_contains(received(name), line) end, 50)
    return received(name)
end

H.test('auto_start with a command waits for the agent, then sends it', function()
    foyer.send_terminal_command('a', { auto_start = true, command = 'from auto_start' })
    H.eq({ 'ready', "got b'\\x15\\x0cfrom auto_start\\r'" }, wait_for('a', "got b'\\x15\\x0cfrom auto_start\\r'"), 'agent log')
    H.ok(vim.tbl_contains(notes, 'foyer.nvim: waiting for python3 to start'), 'said it was waiting: ' .. vim.inspect(notes))
end)

H.test('a prompt sent on first use, before the agent is up, still arrives', function()
    H.reset(file)
    H.press(function() foyer.terminal_command({ key = 'b' }) end)
    H.ok(H.state().prompt, 'the prompt opens at once')
    H.send('from the prompt', true)
    H.ok(not vim.tbl_contains(received('b'), 'ready'), 'sent while the agent was still starting')
    local got = wait_for('b', "got b'\\x15\\x0cfrom the prompt\\r'")
    H.eq('ready', got[1], 'the agent came up first')
    H.eq("got b'\\x15\\x0cfrom the prompt\\r'", got[2], 'then the prompt arrived')
end)

H.test('once the agent is up, a send goes straight to it', function()
    notes = {}
    foyer.send_terminal_command('a', { command = 'already up' })
    H.ok(vim.tbl_contains(wait_for('a', "got b'\\x15\\x0calready up\\r'"), "got b'\\x15\\x0calready up\\r'"), 'received')
    H.eq({}, notes, 'no waiting')
end)

H.test('a program that draws nothing is not waited on for long', function()
    local t0 = vim.uv.now()
    H.sent_clear()
    foyer.send_terminal_command('s', { auto_start = true, command = 'hello' })
    vim.wait(8000, function() return H.last_text() == 'hello\r' end, 50)
    H.eq('hello\r', H.last_text(), 'sent')
    local took = vim.uv.now() - t0
    H.ok(took >= 2500 and took < 5500, 'after the silent grace, not the full timeout: ' .. took .. 'ms')
end)

H.test('an agent that comes up on a question gets no Enter, only a notice', function()
    notes = {}
    H.reset(file)
    H.press(function() foyer.terminal_command({ key = 'd' }) end, '3GV')
    local prompt_buf = H.state().buf
    H.send('do not lose me', true)
    -- Waiting for the text to show, foyer keeps out of Terminal mode, so no
    -- key of the user's can reach the question meanwhile.
    H.ok(H.state().terminal, 'the terminal is in front, for the question to be answered')
    H.eq('n', vim.fn.mode(), 'not in Terminal mode')
    vim.wait(6000, function()
        return vim.iter(notes):any(function(n) return n:find('did not show the prompt', 1, true) end)
    end, 100)
    H.ok(vim.iter(notes):any(function(n) return n:find('python3 did not show the prompt, so it was not sent', 1, true) end),
        'said so: ' .. vim.inspect(notes))
    vim.wait(500)
    H.eq({}, received('d'), 'no Enter reached the question')

    -- Nothing put back: the prompt is in history.
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.eq(prompt_buf, H.state().buf, 'back in the prompt')
    H.eq({ '' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'left empty')
    H.feed('<Up>')
    H.eq({ 'do not lose me' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'one <Up> away')
end)

H.test('a terminal closed while foyer waits on it says nothing more', function()
    notes = {}
    foyer.send_terminal_command('d', { command = 'gone soon' })
    vim.wait(300)
    local term = vim.iter(vim.api.nvim_list_bufs()):find(function(b)
        return vim.api.nvim_buf_get_name(b):find('dialog.py', 1, true)
    end)
    vim.api.nvim_buf_delete(term, { force = true })
    vim.wait(3000)
    H.eq({}, notes, 'no notice')
end)

H.finish()
