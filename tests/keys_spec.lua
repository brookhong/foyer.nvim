local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ commands = { q = H.quiet, w = H.quiet } })
foyer.is_idle = function() return true end
local config = require('foyer.config').options
local defaults = vim.deepcopy(config.keys)

vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function prompt()
    H.press(function() foyer.terminal_command({ key = 'q' }) end)
    return H.state().buf
end

-- The terminal, shown by a send from a prompt.
local function terminal()
    prompt()
    H.send('hello')
    vim.cmd('stopinsert')
    return H.state().buf
end

-- The buffer's own mapping of {lhs} in {mode}, or nil.
local function mapped(buf, mode, lhs)
    local key = vim.keycode(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if vim.keycode(m.lhs) == key then return m end
    end
end

-- Each test sets keys of its own, from the defaults.
local function with(keys, fn)
    return function()
        config.keys = vim.deepcopy(defaults)
        foyer.setup({ keys = keys })
        H.reset(file)
        -- Fresh terminals: keys are mapped on a buffer as it is set up.
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.b[buf].foyer_terminal then vim.api.nvim_buf_delete(buf, { force = true }) end
        end
        fn()
        config.keys = vim.deepcopy(defaults)
    end
end

H.test('the defaults are mapped', with({}, function()
    local buf = prompt()
    for _, k in ipairs({ { 'n', '<CR>' }, { 'i', '<C-s>' }, { 'n', '<Esc>' }, { 'n', '<C-c>' },
        { 'n', '<C-o>' }, { 'n', '<Up>' }, { 'n', '<C-p>' }, { 'i', '<Up>' }, { 'n', '<Down>' },
        { 'i', '<Down>' }, { 'n', '<C-f>' }, { 'i', '<C-f>' } }) do
        H.ok(mapped(buf, k[1], k[2]), 'prompt ' .. k[1] .. ' ' .. k[2])
    end
    for _, lhs in ipairs({ '<C-p>', '<C-n>', '<C-x><C-p>', '<C-x><C-n>' }) do
        H.ok(not mapped(buf, 'i', lhs), 'Insert-mode ' .. lhs .. ' left to completion')
    end
    local term = terminal()
    for _, lhs in ipairs({ '<C-t>', '<C-o>', '<CR>', '<C-c>', '<Esc>', '<C-r>' }) do
        H.ok(mapped(term, 'n', lhs), 'terminal n ' .. lhs)
    end
end))

H.test('no <C-x> keys in Terminal mode', with({}, function()
    local term = terminal()
    H.eq({}, vim.api.nvim_buf_get_keymap(term, 't'), 'none')
end))

H.test('a key alone goes in the action\'s default modes, replacing its keys', with({
    prompt = { history_prev = '<C-k>' },
}, function()
    local buf = prompt()
    H.ok(mapped(buf, 'n', '<C-k>') and mapped(buf, 'i', '<C-k>'), 'both modes')
    H.ok(not mapped(buf, 'n', '<Up>') and not mapped(buf, 'n', '<C-p>'), 'the old keys gone')
    H.ok(not mapped(buf, 'i', '<Up>'), 'nor Insert-mode <Up>')
    H.ok(mapped(buf, 'i', '<Down>'), 'history_next keeps its own')
end))

H.test('a list replaces the default list rather than merging into it', with({
    terminal = { close = { 'q' } },
}, function()
    local term = terminal()
    H.ok(mapped(term, 'n', 'q'), 'q')
    H.ok(not mapped(term, 'n', '<CR>') and not mapped(term, 'n', '<C-c>'), 'the old keys gone')
end))

H.test('a table by mode names the modes itself', with({
    prompt = { send = { n = '<Space>s' } },
}, function()
    local buf = prompt()
    H.ok(mapped(buf, 'n', '<Space>s'), 'Normal mode')
    H.ok(not mapped(buf, 'i', '<C-s>'), 'none in Insert mode')
    H.ok(not mapped(buf, 'n', '<CR>'), 'nor the old one')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'via space s' })
    vim.cmd('stopinsert')
    H.sent_clear()
    H.feed(' s')
    -- A terminal just started is waited for before anything reaches it.
    H.ok(vim.wait(5000, function() return table.concat(H.sent()):find('via space s', 1, true) ~= nil end, 20),
        'it sends')
end))

H.test('false maps nothing', with({
    terminal = { cd_root = false, switch = false },
}, function()
    local term = terminal()
    H.ok(not mapped(term, 'n', '<C-r>'), 'no <C-r>')
    H.ok(not mapped(term, 'n', '<C-t>'), 'no <C-t>')
end))

-- What setup() says about {keys}, if anything.
local function warning(keys)
    local notify, said = vim.notify, nil
    vim.notify = function(msg) said = msg end
    foyer.setup({ keys = keys })
    vim.notify = notify
    return said
end

H.test('an unknown action is said so', with({}, function()
    local said = warning({ prompt = { sned = '<CR>' } })
    H.ok(said and said:find('keys.prompt.sned', 1, true), 'warned: ' .. tostring(said))
end))

H.test('an unknown group is said so', with({}, function()
    local said = warning({ promt = { send = '<CR>' } })
    H.ok(said and said:find('keys.promt', 1, true), 'warned: ' .. tostring(said))
end))

H.test('a group that is no table is said so, and the defaults kept', with({}, function()
    local said = warning({ prompt = false })
    H.ok(said and said:find('keys.prompt must be a table', 1, true), 'warned: ' .. tostring(said))
    H.ok(mapped(prompt(), 'n', '<CR>'), 'send still mapped')
end))

H.test('a value that is no key is said so, and the default kept', with({}, function()
    for _, bad in ipairs({ 5, { 5 }, { n = 5 }, true }) do
        local said = warning({ prompt = { send = bad } })
        H.ok(said and said:find('keys.prompt.send must be', 1, true),
            vim.inspect(bad) .. ' warned: ' .. tostring(said))
    end
    H.ok(mapped(prompt(), 'n', '<CR>'), 'send still mapped')
end))

H.test('every form a value may take is taken without a word', with({}, function()
    for _, good in ipairs({ '<CR>', { '<CR>', '<C-s>' }, { n = '<CR>', i = { '<C-s>' } }, { n = false }, false, {} }) do
        H.eq(nil, warning({ prompt = { send = good } }), vim.inspect(good))
    end
end))

H.finish()
