-- Shared by every spec. A spec runs in a fresh headless Neovim, started by
-- tests/run.sh with a throwaway cache directory, so the history and context
-- files it writes are never the user's.
local H = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
H.root = root
vim.opt.rtp:prepend(root)
vim.cmd.cd(root)
-- No "3 lines yanked" in the output: edit_selection() goes through a register.
vim.o.report = 10000
-- No swap files: a spec edits the repository's own files, which the user may
-- have open -- an existing swap file would stop it at the ATTENTION prompt,
-- and one of its own, left by a run cut short, would stop the next run.
vim.o.swapfile = false
vim.opt.shortmess:append('A')

-- Terminals for the specs to drive. `quiet` draws a prompt and then shows
-- only what is typed into it, as an input box does, so it starts at once and
-- takes a prompt as a real program would; `noisy` starts as quickly, then
-- never stops printing from a second on, so it is busy for good -- the way an
-- agent is busy, after it has come up.
H.quiet = { 'sh', [[-c "printf '$ '; cat >/dev/null"]] }
H.noisy = { 'sh', [[-c "echo up; sleep 1; while :; do echo x; sleep 0.1; done"]] }

function H.foyer(opts)
    local foyer = require('foyer')
    foyer.setup(opts or {})
    return foyer
end

-- Keys as typed, run to completion.
function H.feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

function H.wait(ms)
    vim.wait(ms or 300)
end

-- Run {fn} from a key, the way a user's mapping would: keys before it (a
-- visual selection) are still in effect when it runs.
function H.press(fn, before)
    _G.__foyer_test_fn = fn
    vim.keymap.set({ 'n', 'x' }, '<F12>', '<Cmd>lua __foyer_test_fn()<CR>')
    H.feed((before or '') .. '<F12>')
    H.wait()
end

-- Every chunk sent to any terminal, in order. Cleared by H.sent_clear().
local sent = {}
local chansend = vim.fn.chansend
vim.fn.chansend = function(id, data)
    table.insert(sent, data)
    return chansend(id, data)
end
function H.sent() return sent end
function H.sent_clear() sent = {} end
-- The last chunk that carried text rather than a lone control key, with what
-- followed it: the Enter goes on its own when a terminal's first prompt is
-- confirmed before it is sent.
function H.last_text()
    for i = #sent, 1, -1 do
        if #sent[i] > 2 then return table.concat(sent, '', i) end
    end
end

-- What the user is looking at.
function H.state()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local cfg = vim.api.nvim_win_get_config(win)
    local float = cfg.relative ~= ''
    return {
        win = win,
        buf = buf,
        float = float,
        prompt = vim.b[buf].foyer_prompt == true,
        terminal = vim.bo[buf].buftype == 'terminal',
        wins = #vim.api.nvim_tabpage_list_wins(0),
        title = float and cfg.title and cfg.title[1][1] or vim.wo[win].winbar,
    }
end

-- Type {lines} into the prompt in front of the user and send it.
-- It is waited for until text reaches a terminal: a send to a terminal still
-- starting is held until it has. {nothing} says none is expected, and waits a
-- moment instead.
function H.send(lines, nothing)
    if type(lines) == 'string' then lines = { lines } end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd('stopinsert')
    local before = #sent
    H.feed('<CR>')
    if nothing then return H.wait(400) end
    vim.wait(5000, function()
        for i = before + 1, #sent do
            if #sent[i] > 2 then return true end
        end
    end, 20)
    -- And whatever comes after it, the Enter of a confirmed first send.
    local count, still = #sent, vim.uv.now()
    vim.wait(3000, function()
        if #sent ~= count then count, still = #sent, vim.uv.now() end
        return vim.uv.now() - still > 400
    end, 20)
end

-- Back to a single window showing {buf}, out of insert mode, no floats.
function H.reset(buf)
    vim.cmd('stopinsert')
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then
            vim.api.nvim_win_close(w, true)
        end
    end
    vim.cmd('silent! only')
    if buf then vim.api.nvim_set_current_buf(buf) end
    H.sent_clear()
end

local results = { pass = 0, fail = 0 }

-- A second Neovim, driven over RPC, for what only a real main loop does: keys
-- typed in Insert mode, completion menus, callbacks scheduled from mappings.
-- feedkeys() cannot drive those from a running script. It shares the cache
-- directory tests/run.sh set up, and starts in the repository.
--
-- {shada} is the ShaDa file it reads and writes, for a spec about what one
-- session leaves the next; without it there is none.
function H.child(setup, shada)
    -- -n and shortmess+=A: no swap files, for the reason given at the top.
    local cmd = { 'nvim', '--embed', '--headless', '-u', 'NONE', '-n', '--cmd', 'set shortmess+=A',
        '-i', shada or 'NONE' }
    if not shada then table.insert(cmd, '--clean') end
    local chan = vim.fn.jobstart(cmd, { rpc = true, cwd = root })
    local child = {}
    -- Run {code} there, with {...} as its arguments; what it returns comes back.
    function child.lua(code, ...)
        return vim.rpcrequest(chan, 'nvim_exec_lua', code, { ... })
    end
    -- Type {keys} there, and give it a moment to act on them.
    function child.type(keys, ms)
        vim.rpcrequest(chan, 'nvim_input', keys)
        vim.wait(ms or 150)
    end
    function child.lines()
        return child.lua('return vim.api.nvim_buf_get_lines(0, 0, -1, false)')
    end
    function child.stop()
        pcall(vim.rpcnotify, chan, 'nvim_command', 'qa!')
        vim.fn.jobwait({ chan }, 2000)
        vim.fn.jobstop(chan)
    end
    -- Quit the way a user does, so it writes its ShaDa, and wait for it.
    function child.quit()
        pcall(vim.rpcrequest, chan, 'nvim_command', 'qa!')
        vim.fn.jobwait({ chan }, 5000)
    end
    child.lua("vim.opt.rtp:prepend('.'); vim.o.report = 10000")
    if setup then child.lua(setup) end
    return child
end

function H.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        results.pass = results.pass + 1
        io.stdout:write('  ok    ' .. name .. '\n')
    else
        results.fail = results.fail + 1
        io.stdout:write('  FAIL  ' .. name .. '\n' .. tostring(err):gsub('^', '        '):gsub('\n', '\n        ') .. '\n')
    end
    -- Now, not at the end: a spec that hangs still shows how far it got.
    io.stdout:flush()
end

local function show(v)
    local s = vim.inspect(v)
    return #s > 200 and s:sub(1, 200) .. '…' or s
end

function H.eq(want, got, what)
    if not vim.deep_equal(want, got) then
        error(('%s: want %s, got %s'):format(what or 'value', show(want), show(got)), 2)
    end
end

function H.ok(cond, what)
    if not cond then error((what or 'assertion') .. ' failed', 2) end
end

function H.finish()
    io.stdout:write(('  %d passed, %d failed\n'):format(results.pass, results.fail))
    io.stdout:flush()
    vim.cmd(results.fail == 0 and 'qa!' or 'cq!')
end

return H
