local H = dofile('tests/helpers.lua')

-- The editor the mentions are typed in: README.md open at line 5, where the
-- prompt is opened from, and init.lua with a selection on lines 10-11 and an
-- unsaved change on line 11.
local child = H.child([[
    local foyer = require('foyer')
    local quiet = { 'sh', '-c "stty -echo; cat >/dev/null"' }
    foyer.setup({ commands = {
        q = quiet,
        G = { quiet[1], quiet[2], cwd = vim.env.HOME, scope = 'global' },
    } })
    foyer.is_idle = function() return true end
    vim.cmd('edit lua/foyer/init.lua | normal! 10GVj\27')
    vim.cmd('normal! 11Gx')
    vim.cmd('edit README.md | normal! 5G')
    _G.readme = vim.api.nvim_get_current_buf()
    -- A fresh prompt for {key}, in Insert mode.
    function _G.prompt(key)
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= '' then vim.api.nvim_win_close(w, true) end
        end
        vim.cmd('stopinsert | silent! only')
        vim.api.nvim_set_current_buf(_G.readme)
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        foyer.terminal_command({ key = key or 'q' })
    end
]])
local root = H.root

local function menu()
    return child.lua([[
        local ci = vim.fn.complete_info({ 'pum_visible', 'items', 'selected' })
        return { visible = ci.pum_visible == 1, selected = ci.selected,
                 entries = vim.tbl_map(function(i) return i.abbr end, ci.items) }
    ]])
end

local function prompt(key)
    child.lua('_G.prompt(...)', key)
    vim.wait(300)
    child.type('i')
end

H.test('@ lists the open files, the one you came from first, at its cursor line', function()
    prompt()
    child.type('ask @')
    local m = menu()
    H.ok(m.visible, 'the menu is up')
    H.eq({ 'README.md:5', 'lua/foyer/init.lua:11' }, m.entries, 'entries')
    H.eq(0, m.selected, 'the first is highlighted')
end)

H.test('typing after the @ narrows the list', function()
    child.type('ini')
    H.eq({ 'lua/foyer/init.lua:11' }, menu().entries, 'entries')
end)

H.test('<CR> puts in @path:line, and a space after it', function()
    child.type('<CR>')
    H.eq({ 'ask @lua/foyer/init.lua:11 ' }, child.lines(), 'prompt')
    H.ok(not menu().visible, 'the menu has closed')
end)

H.test('<C-n> moves through the menu rather than history', function()
    prompt()
    child.type('@')
    child.type('<C-n>')
    child.type('<CR>')
    H.eq({ '@lua/foyer/init.lua:11 ' }, child.lines(), 'the second entry')
end)

H.test('<C-l> puts in the selection block, the visual range around the line', function()
    prompt()
    child.type('look @')
    child.type('init')
    child.type('<C-l>')
    local lines = child.lines()
    H.eq('look', lines[1], 'what came before stays above')
    H.eq(('Selected in my editor: %s/lua/foyer/init.lua, lines 10-11 (unsaved; the file on disk differs)'):format(root),
        lines[2], 'label')
    H.eq('```lua', lines[3], 'fence')
    H.eq('ocal project_root = options.project_root', lines[5], 'the buffer\'s unsaved text')
    H.eq({ '```', '' }, { lines[6], lines[7] }, 'closed, and a line to carry on in')
end)

H.test('<C-l> on a file with no selection around the line sends just that line', function()
    prompt()
    child.type('@')
    child.type('<C-l>')
    H.eq(('Selected in my editor: %s/README.md, line 5'):format(root), child.lines()[1], 'label')
end)

H.test('an @ inside a word is just an @', function()
    prompt()
    child.type('mail a@b')
    H.ok(not menu().visible, 'no menu')
    child.type(' x<CR>y')
    H.eq({ 'mail a@b x', 'y' }, child.lines(), 'and <CR> is a newline')
end)

H.test('<Esc> leaves the @ as typed, and <CR> a newline again', function()
    prompt()
    child.type('x @')
    child.type('<Esc>')
    child.type('a<CR>y')
    H.eq({ 'x @', 'y' }, child.lines(), 'prompt')
end)

H.test('a newline typed fast after other keys keeps its place', function()
    prompt()
    child.type('a<CR>b')
    H.eq({ 'a', 'b' }, child.lines(), 'prompt')
end)

H.test('no match: <CR> is a newline', function()
    prompt()
    child.type('x @')
    child.type('nomatch')
    child.type('<CR>y')
    H.eq({ 'x @nomatch', 'y' }, child.lines(), 'prompt')
end)

H.test('a global agent gets absolute paths', function()
    prompt('G')
    child.type('@')
    H.eq(('%s/README.md:5'):format(root), menu().entries[1], 'first entry')
end)

H.test('a sent block stays out of history; the words around it stay in', function()
    prompt()
    child.type('why this @')
    child.type('<C-l>')
    child.type('and that<Esc>')
    child.type('<CR>', 500)
    local entries = child.lua([[
        local data = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath('cache') .. '/foyer.json'), '\n'))
        local all = {}
        for _, list in pairs(data) do for _, e in ipairs(list) do table.insert(all, e.cmd) end end
        return all
    ]])
    H.ok(vim.tbl_contains(entries, 'why this\nand that'), 'stored: ' .. vim.inspect(entries))
end)

H.test('a mention typed straight after another keeps its files', function()
    -- LICENSE is only remembered, not open: the first mention loads it for
    -- its menu, and the second, in the same keystrokes, finds it loaded.
    child.lua('vim.v.oldfiles = { vim.fn.getcwd() .. "/LICENSE" }')
    prompt()
    child.type('@LIC @LIC', 300)
    child.type('<C-l>', 300)
    H.eq('', child.lua('return vim.v.errmsg'), 'no error')
    H.ok(child.lines()[2]:find('/LICENSE, line 1$'), 'the block: ' .. vim.inspect(child.lines()))
    vim.wait(100)
    H.eq(-1, child.lua('return vim.fn.bufnr(vim.fn.getcwd() .. "/LICENSE")'), 'and LICENSE let go once both are done')
end)

H.test('a file that is not text is not offered', function()
    child.lua([[
        local path = vim.fn.stdpath('cache') .. '/image.bin'
        vim.fn.writefile(vim.fn.list2blob({ 137, 80, 78, 71, 0, 0, 0, 13, 73, 72, 68, 82 }), path)
        vim.v.oldfiles = { path, vim.fn.getcwd() .. '/LICENSE' }
    ]])
    prompt()
    child.type('@')
    local entries = menu().entries
    H.ok(vim.tbl_contains(entries, 'LICENSE:1'), 'LICENSE offered: ' .. vim.inspect(entries))
    H.ok(not vim.iter(entries):any(function(e) return e:find('image.bin', 1, true) end), 'the binary is not')
    child.type('<Esc>')
    child.lua('vim.v.oldfiles = {}')
end)

H.test('mention = false leaves @ alone', function()
    child.lua("require('foyer').setup({ mention = false })")
    prompt()
    child.type('@')
    H.ok(not menu().visible, 'no menu')
    child.lua("require('foyer').setup({ mention = true })")
end)

child.stop()
H.finish()
