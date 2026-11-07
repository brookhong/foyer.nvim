local H = dofile('tests/helpers.lua')

-- A terminal whose program prints a prompt and, for every line it reads, more
-- reply than its window holds. Shown in a split by `switch`, as an ordinary
-- window would show it, so nothing but the send decides where it looks.
local script = vim.fn.stdpath('cache') .. '/replies.sh'
vim.fn.mkdir(vim.fn.fnamemodify(script, ':h'), 'p')
vim.fn.writefile({
    "printf '$ '",
    'while read line; do',
    '  for i in $(seq 1 60); do echo "reply $i to $line"; done',
    "  printf '$ '",
    'done',
}, script)

local child = H.child(([[
    vim.o.lines, vim.o.columns = 24, 80
    local foyer = require('foyer')
    foyer.setup({ commands = { r = { 'sh', %q } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE | vsplit')
    foyer.terminal_command({ key = 'r', switch = true })
    vim.cmd('stopinsert')
    _G.term_win = vim.api.nvim_get_current_win()
    -- Back to the file: the terminal is in a window beside it, not in front.
    vim.cmd('wincmd p')
    function _G.view()
        local buf = vim.api.nvim_win_get_buf(_G.term_win)
        return {
            top = vim.fn.line('w0', _G.term_win),
            cursor = vim.api.nvim_win_get_cursor(_G.term_win)[1],
            last = vim.api.nvim_buf_line_count(buf),
        }
    end
]]):format(script))

-- Up, its prompt drawn, and its cursor somewhere above the last line, as a
-- terminal's is.
vim.wait(1000)
child.lua('vim.api.nvim_win_set_cursor(_G.term_win, { 1, 0 })')

-- Send {text}, and wait until the last line of its reply is in.
local function send_and_wait(text)
    local before = child.lua('return _G.view()')
    child.lua('require("foyer").send_terminal_command("r", { command = ... })', text)
    local arrived = vim.wait(3000, function()
        return child.lua([[
            local want = ...
            local buf = vim.api.nvim_win_get_buf(_G.term_win)
            return vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
                :any(function(l) return l == want end)
        ]], 'reply 60 to ' .. text)
    end, 100)
    vim.wait(200)
    return child.lua('return _G.view()'), before, arrived
end

H.test('the first send, confirmed before its Enter, has the window follow the reply', function()
    local v, _, arrived = send_and_wait('first')
    H.ok(arrived, 'the reply arrived')
    H.eq(v.last, v.cursor, 'the cursor on the last line')
    H.ok(v.top > 1, 'the window scrolled with it: ' .. vim.inspect(v))
end)

-- Sent straight away, with no Terminal mode entered for it any more: the
-- window still follows.
H.test('a later send, straight away, still has it follow', function()
    child.lua('vim.api.nvim_win_set_cursor(_G.term_win, { 1, 0 })')
    local v, before, arrived = send_and_wait('second')
    H.ok(arrived, 'the second reply arrived')
    H.eq(v.last, v.cursor, 'the cursor on the last line')
    H.ok(v.top > before.top, 'the window scrolled with it, past where it was: ' .. vim.inspect(v))
end)

child.stop()
H.finish()
