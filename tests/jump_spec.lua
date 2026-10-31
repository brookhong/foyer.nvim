local H = dofile('tests/helpers.lua')

-- Set up in each Neovim driving the picker.
local LABELS = [==[
    -- The picker's entries, name -> label, read from its marks; and name ->
    -- the section it is listed in, from the title above it. A name is read
    -- from its highlight, which covers exactly it.
    function _G.labels()
        local ns = vim.api.nvim_get_namespaces()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local names_at = {}
        for _, h in ipairs(vim.api.nvim_buf_get_extmarks(0, ns.foyer_jump_hl, 0, -1, { details = true })) do
            names_at[h[2] .. ':' .. h[3]] = lines[h[2] + 1]:sub(h[3] + 1, h[4].end_col)
        end
        local out, sections = {}, {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns.foyer_jump, 0, -1, { details = true })) do
            local label = table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_text)):gsub('%s', '')
            -- the name starts after the two-cell label slot and a space
            local name = names_at[m[2] .. ':' .. (m[3] + 3)]
            out[name] = label
            for i = m[2] + 1, 1, -1 do
                local title = lines[i]:match('(%a[%a ]*)|%d+')
                if title then sections[name] = title; break end
            end
        end
        return out, sections
    end
]==]

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
]] .. LABELS)
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

-- Names, from paths alone: the Windows ones read as Windows paths.
local unique_names = dofile('lua/foyer/jump.lua')._unique_names
local function names(paths, win)
    local items = {}
    for i, p in ipairs(paths) do items[i] = { key = i, path = p, minDepth = 1 } end
    return unique_names(items, win)
end

H.test('copies on two drives are told apart by the drive, the middle elided', function()
    H.eq({ 'C:/…/module/init.lua', 'D:/…/module/init.lua' },
        names({ [[C:\work\project\src\module\init.lua]], [[d:\work\project\src\module\init.lua]] }, true), 'names')
end)

H.test('a short unique name is left whole', function()
    H.eq({ 'a/init.lua', 'b/init.lua', 'main.lua' }, names({ '/x/a/init.lua', '/x/b/init.lua', '/x/main.lua' }), 'names')
end)

H.test('rooted paths keep their root when elided', function()
    H.eq({ '/…/module/init.lua', 'z/…/module/init.lua' },
        names({ '/w/p/s/module/init.lua', '/z/w/p/s/module/init.lua' }), 'names')
end)

H.test('the middle stays when eliding it would make two names the same', function()
    -- Both elide to D:/…/m/init.lua, so neither is.
    local n = names({ 'C:/a/q/x/m/init.lua', 'D:/a/q/x/m/init.lua', 'C:/b/q/x/m/init.lua', 'D:/b/q/x/m/init.lua' }, true)
    H.eq(4, #vim.tbl_keys(vim.iter(n):fold({}, function(acc, v) acc[v] = true; return acc end)), 'all different: ' .. vim.inspect(n))
    for _, v in ipairs(n) do H.ok(v:find('init.lua$'), 'ends in the file name: ' .. v) end
end)

-- The layout, with twin trees -- like copies on C: and D: -- open in several
-- tabs, and a narrow screen: nothing may wrap.
local dir = vim.fn.stdpath('cache') .. '/twins'
for _, top in ipairs({ 'C', 'D' }) do
    vim.fn.mkdir(dir .. '/' .. top .. '/work/project/src/module', 'p')
    for _, f in ipairs({ 'init.lua', 'config.lua' }) do
        vim.fn.writefile({ top .. ' ' .. f }, ('%s/%s/work/project/src/module/%s'):format(dir, top, f))
    end
end
local long = dir .. '/' .. string.rep('long', 20) .. '.txt'
vim.fn.writefile({ 'long' }, long)

local twins = H.child(([[
    vim.o.columns, vim.o.lines = 60, 30
    local foyer = require('foyer')
    local m = '%s/%%s/work/project/src/module/%%s'
    vim.cmd.edit(m:format('C', 'init.lua')); vim.cmd.vsplit(m:format('D', 'init.lua'))
    vim.cmd.tabedit(m:format('C', 'config.lua')); vim.cmd.vsplit(m:format('D', 'config.lua'))
    vim.cmd.tabedit('README.md')
    vim.cmd.badd('%s')
    vim.keymap.set('n', '<F12>', foyer.jump)
]]):format(dir, long) .. LABELS)

local function picker()
    twins.type('<F12>', 400)
    return twins.lua([[
        local width = vim.api.nvim_win_get_width(0)
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local too_wide = vim.tbl_filter(function(l) return vim.fn.strdisplaywidth(l) > width end, lines)
        return { width = width, lines = lines, too_wide = too_wide }
    ]])
end

H.test('tabs too wide for one row carry on below a line of ─, nothing wraps', function()
    local p = picker()
    H.ok(p.width <= 58, 'inside the border: ' .. p.width)
    H.eq({}, p.too_wide, 'no line wider than the picker')
    local bands = vim.tbl_filter(function(l) return l ~= '' and l:gsub('─', '') == '' end, p.lines)
    H.ok(#bands >= 1, 'tabs in bands: ' .. vim.inspect(p.lines))
    local text = table.concat(p.lines, '\n')
    H.ok(text:find('D/…/module/config.lua', 1, true) and text:find('C/…/module/config.lua', 1, true), 'names elided: ' .. text)
    H.ok(text:find('…', 1, true) and text:find('longlong', 1, true), 'the long buffer cut to fit')
    twins.type('<Esc>')
end)

H.test('and every label still goes to its own window', function()
    twins.type('<F12>', 400)
    local labels = twins.lua('return _G.labels()')
    twins.type(labels['D/…/module/config.lua'])
    H.eq('D config.lua', twins.lua('return vim.api.nvim_get_current_line()'), 'in D/…/config.lua')
end)

H.test('with ambiwidth=double, where │ and ─ take two cells, nothing wraps either', function()
    twins.lua('vim.o.ambiwidth = "double"')
    local p = picker()
    twins.type('<Esc>')
    twins.lua('vim.o.ambiwidth = "single"')
    H.eq({}, p.too_wide, 'no line wider than the picker')
end)

twins.stop()

-- Little to list makes a narrow picker: its frame must still be read whole.
local small = H.child([[
    vim.o.columns, vim.o.lines = 100, 30
    vim.cmd('edit LICENSE | vsplit README.md')
    vim.keymap.set('n', '<F12>', require('foyer').jump)
]])

H.test('<BS> starts the label over, even with one entry to pick', function()
    small.type('<F12>', 400)
    small.type('<BS>')
    H.eq(true, small.lua('return vim.bo.filetype == "foyerjump"'), 'still in the picker')
    small.type('<Esc>')
    H.eq('README.md', small.lua('return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")'), 'and <Esc> leaves us where we were')
end)

H.test('a picker with little in it is still wide enough for its footer', function()
    small.type('<F12>', 400)
    local drawn = small.lua([[
        local win = vim.api.nvim_get_current_win()
        local pos = vim.api.nvim_win_get_position(win)
        local h, w = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
        vim.cmd('redraw')
        local row = {}
        -- The bottom border is the row below the last one; it starts a cell
        -- to the left of the window, at its corner.
        for c = pos[2], pos[2] + w + 1 do row[#row + 1] = vim.fn.screenstring(pos[1] + h + 2, c) end
        return table.concat(row)
    ]])
    small.type('<Esc>')
    H.ok(drawn:find('Type hint labels to pick, <Esc> to cancel', 1, true), 'footer whole: ' .. drawn)
end)

small.stop()

-- A terminal foyer started, and one opened by hand, both hidden behind a file.
local terms = H.child([[
    local foyer = require('foyer')
    foyer.setup({ commands = { o = { 'sh', '-c "echo started-by-foyer; cat"' } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE')
    foyer.terminal_command({ key = 'o', command = ':', auto_start = true })
    vim.cmd('terminal sh -c "echo opened-by-hand; cat"')
    vim.cmd('stopinsert | edit README.md | edit LICENSE')
    vim.keymap.set('n', '<F12>', foyer.jump)
]] .. LABELS)

H.test('foyer\'s own terminals are left out of the buffers; one opened by hand is not', function()
    vim.wait(500)
    terms.type('<F12>', 400)
    local labels = terms.lua('return _G.labels()')
    terms.type('<Esc>')
    local names = vim.tbl_keys(labels)
    local function listed(text)
        return vim.iter(names):any(function(n) return n:find(text, 1, true) ~= nil end)
    end
    H.ok(labels['README.md'], 'the file is there: ' .. vim.inspect(names))
    H.ok(listed('opened-by-hand'), 'the hand-opened terminal is there: ' .. vim.inspect(names))
    H.ok(not listed('started-by-foyer'), 'foyer\'s is not: ' .. vim.inspect(names))
end)

H.test('a terminal of foyer\'s shown in a window has a colour of its own', function()
    terms.lua([[
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.b[b].foyer_terminal then vim.cmd('vsplit | buffer ' .. b) end
        end
        vim.cmd('wincmd p')
    ]])
    terms.type('<F12>', 400)
    -- Each name's highlight group, by the name it covers.
    local groups = terms.lua([[
        local ns = vim.api.nvim_get_namespaces().foyer_jump_hl
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out = {}
        for _, h in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local text = lines[h[2] + 1]:sub(h[3] + 1, h[4].end_col)
            if text:find('by%-') then out[text:match('by%-%a+')] = h[4].hl_group end
        end
        return out
    ]])
    terms.type('<Esc>')
    H.eq('FoyerJumpTerminal', groups['by-foyer'], 'foyer\'s, among the tabs: ' .. vim.inspect(groups))
    H.eq('FoyerJumpName', groups['by-hand'], 'one opened by hand, among the buffers: ' .. vim.inspect(groups))
end)

terms.stop()

-- One file, hidden, and the picker opened from a terminal of foyer's: the file
-- is the only buffer left to list, and not the one in front.
local lone = H.child([[
    local foyer = require('foyer')
    foyer.setup({ commands = { o = { 'sh', '-c "cat"' } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE')
    foyer.terminal_command({ key = 'o', command = ':', auto_start = true })
    vim.cmd('stopinsert')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].foyer_terminal then vim.api.nvim_set_current_buf(b) end
    end
    vim.keymap.set('n', '<F12>', foyer.jump)
]] .. LABELS)

H.test('the one file left, hidden behind a terminal of foyer\'s, is still listed', function()
    vim.wait(500)
    H.eq(true, lone.lua('return vim.b.foyer_terminal == true'), 'opened from the terminal')
    lone.type('<F12>', 400)
    local labels = lone.lua('return _G.labels()')
    lone.type('<Esc>')
    H.ok(labels['LICENSE'], 'LICENSE: ' .. vim.inspect(labels))
end)

lone.stop()
H.finish()
