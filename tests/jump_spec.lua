local H = dofile('tests/helpers.lua')

-- The picker blocks on getcharstr() until it is done, so it is driven in a
-- second Neovim, through a mapping: README.md and LICENSE side by side, a
-- hidden listed buffer, and an old file.
local child = H.child([[
    local foyer = require('foyer')
    _G.fallback_called = false
    foyer.setup({ jump = { fallback = function() _G.fallback_called = true end } })
    vim.cmd('edit lua/foyer/init.lua | edit README.md | vsplit LICENSE')
    vim.v.oldfiles = { vim.fn.getcwd() .. '/doc/foyer.txt' }
    vim.keymap.set('n', '<F12>', foyer.jump)
    -- The picker's entries, name -> label, read from its marks; and name ->
    -- the section it is listed in, from the title above it.
    function _G.labels()
        local ns = vim.api.nvim_get_namespaces().foyer_jump
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out, sections = {}, {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local label = table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_text)):gsub('%s', '')
            -- Up to the column line: a name can hold spaces.
            local name = lines[m[2] + 1]:sub(m[3] + 1):match('^..%s(.-)%s+│')
            out[name] = label
            for i = m[2] + 1, 1, -1 do
                local title = lines[i]:match('━ (%a[%a ]*)|')
                if title then sections[name] = title; break end
            end
        end
        return out, sections
    end
    function _G.sections() return select(2, _G.labels()) end
    function _G.where()
        return {
            file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'),
            win = vim.api.nvim_get_current_win(),
            wins = #vim.api.nvim_tabpage_list_wins(0),
            tabs = #vim.api.nvim_list_tabpages(),
            guicursor = vim.o.guicursor,
        }
    end
]])
local home = child.lua('return _G.where()')

local function open()
    child.type('<F12>', 300)
    return child.lua('return _G.labels()')
end
local function sections()
    child.type('<F12>', 300)
    local s = child.lua('return _G.sections()')
    child.type('<Esc>')
    return s
end

H.test('lists the other window, the hidden buffer and the old file, each labelled', function()
    local labels = open()
    H.ok(labels['README.md'], 'the other window: ' .. vim.inspect(labels))
    H.ok(labels['init.lua'], 'the hidden buffer: ' .. vim.inspect(labels))
    H.ok(labels['doc/foyer.txt'], 'the old file, with its directory: ' .. vim.inspect(labels))
    H.eq(nil, labels['LICENSE'], 'not the current window: it is where we are')
    child.type('<Esc>')
end)

H.test('<Esc> closes it and puts everything back', function()
    local w = child.lua('return _G.where()')
    H.eq(home.win, w.win, 'back in the window it was opened from')
    H.eq(2, w.wins, 'no window left over')
    H.eq(home.guicursor, w.guicursor, 'the cursor shown again')
end)

H.test('a label goes to the window', function()
    local labels = open()
    child.type(labels['README.md'])
    local w = child.lua('return _G.where()')
    H.eq('README.md', w.file, 'in README.md')
    H.ok(w.win ~= home.win, 'its own window')
    child.lua('vim.api.nvim_set_current_win(...)', home.win)
end)

H.test('a label opens the hidden buffer, and the old file', function()
    child.type(open()['init.lua'])
    H.eq('init.lua', child.lua('return _G.where()').file, 'the buffer')
    child.type(open()['doc/foyer.txt'])
    H.eq('foyer.txt', child.lua('return _G.where()').file, 'the old file')
    child.lua('vim.cmd("buffer LICENSE")')
end)

H.test('an old file whose path :edit would expand still opens', function()
    child.lua([[
        vim.fn.mkdir(vim.fn.stdpath('cache'), 'p')
        -- A space, and a # that :edit would take for the alternate file.
        local path = vim.fn.stdpath('cache') .. '/notes #1.txt'
        vim.fn.writefile({ 'hello' }, path)
        vim.v.oldfiles = { path }
    ]])
    child.type(open()['nvim/notes #1.txt'])
    H.eq('notes #1.txt', child.lua('return _G.where().file'), 'opened')
    H.eq({ 'hello' }, child.lua('return vim.api.nvim_buf_get_lines(0, 0, -1, false)'), 'the file itself')
    child.lua('vim.cmd("buffer LICENSE")')
    child.lua('vim.v.oldfiles = { vim.fn.getcwd() .. "/doc/foyer.txt" }')
end)

H.test('Shift and a label opens it in a new tab', function()
    child.type(open()['README.md']:upper())
    local w = child.lua('return _G.where()')
    H.eq(2, w.tabs, 'a new tab')
    H.eq('README.md', w.file, 'showing README.md')
    child.lua('vim.cmd("tabclose")')
    child.lua('vim.api.nvim_set_current_win(...)', home.win)
end)

H.test('a key that is no label hands over to the fallback', function()
    open()
    child.type('9')
    H.eq(true, child.lua('return _G.fallback_called'), 'fallback called')
    H.eq(2, child.lua('return _G.where()').wins, 'and the picker is gone')
end)

H.test('a window squeezed flat is left out, its buffer still offered', function()
    H.eq('Tabs', sections()['README.md'], 'as a window while it has room')
    -- Full width for LICENSE squeezes README.md's window to a sliver.
    child.lua('require("foyer").toggle_full_size()')
    local squeezed = sections()
    child.lua('require("foyer").toggle_full_size()')
    H.eq('Buffers', squeezed['README.md'], 'as a buffer once squeezed: ' .. vim.inspect(squeezed))
end)

child.stop()
H.finish()
