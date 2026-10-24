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

-- Terminals for the specs to drive. `quiet` echoes nothing, so it is idle
-- whenever the spec wants it to be; `noisy` never stops printing, so it is
-- always busy.
H.quiet = { 'sh', [[-c "stty -echo; cat >/dev/null"]] }
H.noisy = { 'sh', [[-c "while :; do echo x; sleep 0.1; done"]] }

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
-- The last chunk that carried text rather than a lone control key.
function H.last_text()
    for i = #sent, 1, -1 do
        if #sent[i] > 2 then return sent[i] end
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
function H.send(lines)
    if type(lines) == 'string' then lines = { lines } end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd('stopinsert')
    H.feed('<CR>')
    H.wait(400)
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

function H.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        results.pass = results.pass + 1
        io.stdout:write('  ok    ' .. name .. '\n')
    else
        results.fail = results.fail + 1
        io.stdout:write('  FAIL  ' .. name .. '\n' .. tostring(err):gsub('^', '        '):gsub('\n', '\n        ') .. '\n')
    end
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
