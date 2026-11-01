local H = dofile('tests/helpers.lua')
local foyer = H.foyer({})

H.test('toggle_full_size() widens a split and puts it back', function()
    vim.cmd('silent! only | vsplit')
    local win = vim.api.nvim_get_current_win()
    local before = vim.api.nvim_win_get_width(win)
    foyer.toggle_full_size()
    H.ok(vim.api.nvim_win_get_width(win) > before, 'wider')
    foyer.toggle_full_size()
    H.eq(before, vim.api.nvim_win_get_width(win), 'restored')
end)

H.test('toggle_full_size() heightens a horizontal split and puts it back', function()
    vim.cmd('silent! only | split')
    local win = vim.api.nvim_get_current_win()
    local before = vim.api.nvim_win_get_height(win)
    foyer.toggle_full_size()
    H.ok(vim.api.nvim_win_get_height(win) > before, 'taller: ' .. vim.api.nvim_win_get_height(win))
    foyer.toggle_full_size()
    H.eq(before, vim.api.nvim_win_get_height(win), 'restored')
end)

H.test('in a layout split both ways, it fills the screen and puts every window back', function()
    -- Left a column of two, right one: the current window is top left.
    vim.cmd('silent! only | vsplit | split')
    local win = vim.api.nvim_get_current_win()
    local function sizes()
        return vim.tbl_map(function(w)
            return { vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w) }
        end, vim.api.nvim_tabpage_list_wins(0))
    end
    local before = sizes()
    local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    foyer.toggle_full_size()
    H.ok(vim.api.nvim_win_get_width(win) > w, 'wider')
    H.ok(vim.api.nvim_win_get_height(win) > h, 'taller')
    foyer.toggle_full_size()
    H.eq(before, sizes(), 'every window as it was')
end)

H.test('floats come and gone in between change nothing, and are not resized', function()
    vim.cmd('silent! only | vsplit | split')
    local win = vim.api.nvim_get_current_win()
    local function splits()
        local out = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(w).relative == '' then
                out[#out + 1] = { vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w) }
            end
        end
        return out
    end
    local function float(width, height)
        return vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
            { relative = 'editor', row = 1, col = 1, width = width, height = height })
    end
    local before = splits()
    local first = float(10, 3)
    vim.api.nvim_set_current_win(win)
    foyer.toggle_full_size()
    vim.api.nvim_win_close(first, true)
    local second = float(20, 5)
    foyer.toggle_full_size()
    H.eq(before, splits(), 'every split as it was')
    H.eq({ 20, 5 }, { vim.api.nvim_win_get_width(second), vim.api.nvim_win_get_height(second) },
        'the float that came since, untouched')
    vim.api.nvim_win_close(second, true)
end)

-- With windows come or gone since, the saved layout no longer fits: only the
-- window's own size goes back, and only along a side that still has a
-- neighbour to take it from.
local function size(win) return { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) } end

H.test('with the window below gone since, it puts back its width, and leaves the command line be', function()
    vim.cmd('silent! only | vsplit | split')
    local win = vim.api.nvim_get_current_win()
    local w = vim.api.nvim_win_get_width(win)
    foyer.toggle_full_size()
    vim.api.nvim_win_close(vim.fn.win_getid(vim.fn.winnr('j')), true)
    local full_height = vim.api.nvim_win_get_height(win)
    foyer.toggle_full_size()
    H.eq({ w, full_height }, size(win), 'its width back; alone in its column, its height as it is')
    H.eq(1, vim.o.cmdheight, 'the command line as it was')
end)

H.test('with the window beside it gone since, it puts back its height', function()
    vim.cmd('silent! only | vsplit | split')
    local win = vim.api.nvim_get_current_win()
    local h = vim.api.nvim_win_get_height(win)
    foyer.toggle_full_size()
    vim.api.nvim_win_close(vim.fn.win_getid(vim.fn.winnr('l')), true)
    foyer.toggle_full_size()
    H.eq({ vim.o.columns, h }, size(win), 'its height back, the whole width now its own')
    H.eq(1, vim.o.cmdheight, 'the command line as it was')
end)

H.test('a split with nothing above or below leaves the command line be', function()
    vim.o.cmdheight = 2
    vim.cmd('silent! only | vsplit')
    foyer.toggle_full_size()
    H.eq(2, vim.o.cmdheight, 'maximised')
    foyer.toggle_full_size()
    H.eq(2, vim.o.cmdheight, 'restored')
    vim.o.cmdheight = 1
end)

H.test('tab_switch() steps past a squeezed window to the alternate buffer', function()
    vim.cmd('silent! only | edit README.md | edit LICENSE | vsplit')
    local win = vim.api.nvim_get_current_win()
    foyer.tab_switch()
    H.ok(vim.api.nvim_get_current_win() ~= win, 'with room, into the other window')
    vim.api.nvim_set_current_win(win)
    foyer.toggle_full_size()
    foyer.tab_switch()
    H.eq(win, vim.api.nvim_get_current_win(), 'the squeezed one is skipped')
    H.ok(vim.api.nvim_buf_get_name(0):match('README%.md$'), 'switched to the alternate buffer')
end)

H.finish()
