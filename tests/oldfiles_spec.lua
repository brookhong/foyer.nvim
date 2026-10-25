local H = dofile('tests/helpers.lua')
local shada = vim.fs.joinpath(vim.fn.stdpath('cache'), 'oldfiles_spec.shada')
os.remove(shada)

-- Two earlier sessions, to leave something in 'shada'. The older one changed
-- layout.lua at line 20 (undone, so the file is untouched). The newer one
-- opened eight specs, LICENSE -- last seen at line 9 -- and README.md: ten
-- files, all more recent than layout.lua. A session apiece, since
-- files used within the same second come back in no particular order.
local older = H.child([[vim.cmd('edit lua/foyer/layout.lua | normal! 20G"_xu')]], shada)
older.quit()
vim.wait(1100)
local newer = H.child([[
    -- Eight, so that with these and README.md open, LICENSE is the tenth.
    for _, spec in ipairs(vim.list_slice(vim.fn.glob('tests/*_spec.lua', false, true), 1, 8)) do
        vim.cmd.edit(spec)
    end
    vim.cmd('edit LICENSE | normal! 9G')
    vim.cmd('edit README.md')
]], shada)
newer.quit()

-- The next session has only README.md open.
local child = H.child([[
    -- -u NONE leaves detection off; the point here is that it runs.
    vim.cmd('filetype on')
    local foyer = require('foyer')
    foyer.setup({ commands = { q = { 'sh', '-c "echo up; cat >/dev/null"' } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit README.md | normal! 5G')
    foyer.terminal_command({ key = 'q' })
]], shada)
vim.wait(300)

local function menu()
    return child.lua([[
        local ci = vim.fn.complete_info({ 'pum_visible', 'items' })
        return vim.tbl_map(function(i) return i.abbr end, ci.items)
    ]])
end

local function loaded(path)
    return child.lua('local b = vim.fn.bufnr(...); return b ~= -1 and vim.api.nvim_buf_is_loaded(b)', path)
end

H.test('recent files from shada follow the open ones, ten at most', function()
    child.type('i@')
    local entries = menu()
    H.eq(10, #entries, 'entries')
    H.eq('README.md:5', entries[1], 'the open file first')
    H.ok(vim.tbl_contains(entries, 'LICENSE:9'), 'a recent one, at its last cursor line: ' .. vim.inspect(entries))
    H.ok(not vim.tbl_contains(entries, 'lua/foyer/layout.lua:20'), 'the oldest is out of sight')
end)

H.test('typing searches all of them, not just the ten in sight', function()
    child.type('foyer/layout')
    H.eq({ 'lua/foyer/layout.lua:20' }, menu(), 'found, at its last change')
end)

H.test('a recent file is loaded for the menu without its autocommands', function()
    H.eq(true, loaded('lua/foyer/layout.lua'), 'loaded while the menu is up')
    H.eq('', child.lua("return vim.bo[vim.fn.bufnr('lua/foyer/layout.lua')].filetype"), 'no FileType yet')
end)

H.test('<C-l> on it sends its lines, with the filetype it would have', function()
    child.type('<C-l>')
    local lines = child.lines()
    H.ok(lines[1]:find('lua/foyer/layout.lua, line 20$'), 'label: ' .. lines[1])
    H.eq('```lua', lines[2], 'fence')
end)

H.test('and once the menu is gone, so are the files it loaded', function()
    vim.wait(100)
    H.eq(false, loaded('lua/foyer/layout.lua'), 'layout.lua not left loaded')
    H.eq(false, loaded('LICENSE'), 'nor LICENSE')
    H.eq({ 'README.md' }, child.lua([[
        local files = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].buflisted and vim.bo[b].buftype == '' then
                table.insert(files, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':.'))
            end
        end
        return files
    ]]), 'no file listed besides README.md')
end)

H.test('so opening one afterwards gets its filetype as usual', function()
    child.type('<Esc>')
    child.lua('vim.cmd("wincmd p | edit lua/foyer/layout.lua")')
    H.eq('lua', child.lua('return vim.bo.filetype'), 'filetype')
end)

child.stop()
os.remove(shada)
H.finish()
