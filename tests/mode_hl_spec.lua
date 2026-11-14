local H = dofile('tests/helpers.lua')

-- A foyer terminal shown in the current window, which also maps a Normal of
-- the user's own: that one is kept, whatever foyer does.
local child = H.child(([[
    local foyer = require('foyer')
    foyer.setup({ commands = { q = { %q, %q } } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE')
    _G.file = vim.api.nvim_get_current_buf()
    vim.wo.winhighlight = 'Search:IncSearch'
    foyer.terminal_command({ key = 'q', switch = true })
    vim.cmd('stopinsert')
    _G.win = vim.api.nvim_get_current_win()
]]):format(H.quiet[1], H.quiet[2]))
vim.wait(500)

-- Whether window {win} (the terminal's, by default) is marked, checking it
-- still maps the user's own entry. Neovim adds entries of its own to a
-- terminal's window, so only these two count.
local function marked(win)
    local value = child.lua('return vim.wo[... or _G.win].winhighlight', win)
    H.ok(value:find('Search:IncSearch', 1, true), 'the user\'s entry kept: ' .. value)
    return value:find('Normal:FoyerTerminal$') ~= nil
end
local function mode() return child.lua('return vim.api.nvim_get_mode().mode') end

H.test('by default, it marks the window only while in Terminal mode', function()
    H.eq(false, marked(), 'marked in Normal mode')
    child.type('i', 300)
    H.eq('t', mode(), 'in Terminal mode')
    H.eq(true, marked(), 'marked in Terminal mode')
    child.type([[<C-\><C-n>]], 300)
    H.eq('nt', mode(), 'back in Normal mode')
    H.eq(false, marked(), 'marked back in Normal mode')
end)

-- The default FoyerTerminal background after a :colorscheme that sets Normal
-- to {bg} under 'background' {background}.
local function default_bg(background, bg)
    return child.lua([[
        local background, bg = ...
        vim.cmd('hi clear')
        vim.o.background = background
        vim.api.nvim_set_hl(0, 'Normal', { fg = '#808080', bg = bg })
        vim.cmd('doautocmd ColorScheme')
        return vim.api.nvim_get_hl(0, { name = 'FoyerTerminal' }).bg
    ]], background, bg)
end

H.test('the default is the background, darker', function()
    H.eq(0x0e0f13, default_bg('dark', '#14161b'), 'on a dark one')
    H.eq(0xebebeb, default_bg('light', '#ffffff'), 'on a light one')
end)

H.test('on a background that cannot get darker, the default is lighter', function()
    H.eq(0x1a1a1a, default_bg('dark', '#000000'), 'on black')
end)

H.test('another window showing the same terminal is not marked', function()
    local other = child.lua('vim.cmd("split"); return vim.api.nvim_get_current_win()')
    child.type('i', 300)
    H.eq(true, marked(other), 'the window in Terminal mode, marked')
    H.eq(false, marked(), 'the other, marked')
    child.type([[<C-\><C-n>]], 300)
    H.eq(false, marked(other), 'the window back in Normal mode, marked')
    child.lua('vim.api.nvim_win_close(..., true)', other)
end)

H.test('a window that leaves the terminal for a file is not marked', function()
    child.type('i', 300)
    H.eq(true, marked(), 'marked in Terminal mode')
    child.lua('vim.cmd("stopinsert"); vim.api.nvim_win_set_buf(_G.win, _G.file)')
    vim.wait(300)
    H.eq(false, marked(), 'marked showing a file')
end)

-- The terminal back in its window, after a test that left the file there.
local function show_terminal()
    child.lua('require("foyer").terminal_command({ key = "q", switch = true }); vim.cmd("stopinsert")')
    vim.wait(300)
end

H.test('a float opened from the window in Terminal mode is not marked', function()
    show_terminal()
    child.type('i', 300)
    H.eq(true, marked(), 'marked in Terminal mode')
    local float = child.lua([[
        return vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
            { relative = 'editor', row = 1, col = 1, width = 20, height = 2 })
    ]])
    H.eq(false, marked(float), 'the float, marked')
    child.lua('vim.api.nvim_win_close(..., true)', float)
    child.type([[<C-\><C-n>]], 300)
end)

-- Last: the group stays linked, as a user's own setting does.
H.test('linked to Normal, it leaves the window alone, colorscheme or not', function()
    child.lua([[vim.api.nvim_set_hl(0, 'FoyerTerminal', { link = 'Normal' })]])
    child.lua('vim.cmd("doautocmd ColorScheme")')
    child.type('i', 300)
    H.eq('t', mode(), 'in Terminal mode')
    H.eq(false, marked(), 'marked in Terminal mode')
end)

child.stop()
H.finish()
