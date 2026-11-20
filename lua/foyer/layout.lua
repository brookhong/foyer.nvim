-- Window utilities that know nothing of foyer's prompts or terminals: the
-- full-screen toggle, the window-or-buffer switch, and what counts as a window
-- worth going to, which foyer.jump asks too.
local M = {}

-- Whether {win_id} has a neighbour above or below it ('k'/'j'), or beside it
-- ('h'/'l'): only then does its height, or its width, have anywhere to come
-- from or go back to. Set anyway, a height takes from, or gives to, the
-- command line: a window alone in its column made shorter grows 'cmdheight'
-- by the difference.
local function has_neighbour(win_id, back, forth)
    local cur = vim.fn.win_id2win(win_id)
    return vim.fn.winnr(cur .. back) ~= cur or vim.fn.winnr(cur .. forth) ~= cur
end

-- Give {win_id} {width} and {height}, each only where a neighbour is there to
-- take it from or give it to, see has_neighbour().
local function set_size(win_id, width, height)
    if has_neighbour(win_id, 'h', 'l') then vim.api.nvim_win_set_width(win_id, width) end
    if has_neighbour(win_id, 'k', 'j') then vim.api.nvim_win_set_height(win_id, height) end
end

-- The tab page's windows that are not floats, with their sizes, by window ID:
-- the layout as a split takes and gives back room. Floats are left out, since
-- they come and go on their own -- notifications, hover, a picker -- and take
-- no room from anyone.
local function split_sizes()
    local sizes = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(win).relative == '' then
            sizes[win] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
        end
    end
    return sizes
end

-- Whether {a} and {b} name the same windows.
local function same_wins(a, b)
    for win in pairs(a) do if not b[win] then return false end end
    for win in pairs(b) do if not a[win] then return false end end
    return true
end

-- Toggle the current window between full screen and the size it had before.
-- A float grows in height. A split grows both ways, so it fills the screen
-- whether it sits beside its neighbours, above or below them, or in a layout
-- of both, as CTRL-W | and CTRL-W _ together would. Saved is the size of every
-- split in the tab page, so putting it back restores the neighbours as they
-- were too, not just this one: twice over, as winrestcmd() does, since
-- sizing one window can undo what was just given another. If splits have
-- come or gone since, that record no longer fits them, and only this
-- window's own width and height go back. What is saved is window-local, so
-- it dies with the window. Full is a request, not a promise: a neighbouring
-- split keeps its minimum size, so the window may stop short of the screen's.
function M.toggle_full_size()
    local win_id = vim.api.nvim_get_current_win()
    local saved = vim.w[win_id].foyer_saved_size

    if vim.api.nvim_win_get_config(win_id).relative ~= '' then
        if saved then
            vim.w[win_id].foyer_saved_size = nil
            vim.api.nvim_win_set_height(win_id, saved.height)
        else
            vim.w[win_id].foyer_saved_size = { height = vim.api.nvim_win_get_height(win_id) }
            -- A float starts one row down and wears a border, so it cannot
            -- take every line.
            vim.api.nvim_win_set_height(win_id, vim.o.lines - 4)
        end
        return
    end

    if saved then
        vim.w[win_id].foyer_saved_size = nil
        -- Window variables hold their tables with string keys.
        local sizes = {}
        for win, size in pairs(saved.sizes) do sizes[tonumber(win)] = size end
        if same_wins(sizes, split_sizes()) then
            for _ = 1, 2 do
                for win, size in pairs(sizes) do set_size(win, size[1], size[2]) end
            end
        else
            set_size(win_id, saved.width, saved.height)
        end
    else
        local sizes = {}
        for win, size in pairs(split_sizes()) do sizes[tostring(win)] = size end
        vim.w[win_id].foyer_saved_size = {
            sizes = sizes,
            width = vim.api.nvim_win_get_width(win_id),
            height = vim.api.nvim_win_get_height(win_id),
        }
        set_size(win_id, vim.o.columns, vim.o.lines)
    end
end

-- A window the layout squeezed down to 'winminwidth'/'winminheight' is not one
-- anybody chose to look at: that is exactly what a neighbour is left with when
-- another window takes the whole screen.
local function is_sliver(win_id)
    return vim.api.nvim_win_get_width(win_id) <= vim.o.winminwidth
        or vim.api.nvim_win_get_height(win_id) <= vim.o.winminheight
end

-- The tab page's other windows in CTRL-W w order, starting after the current
-- one and wrapping around. Floats are left out: one sitting over a window is
-- not a destination, and does not make that window any less full.
local function other_wins()
    local wins = {}
    local last = vim.fn.winnr('$')
    local cur = vim.fn.winnr()
    for i = 1, last - 1 do
        local win = vim.fn.win_getid((cur + i - 1) % last + 1)
        if vim.api.nvim_win_get_config(win).relative == '' then
            table.insert(wins, win)
        end
    end
    return wins
end

-- Move to the next window worth looking at, skipping the slivers, or switch to
-- the alternate buffer when the screen holds nothing else: no other window, or
-- only ones squeezed flat by a window filling the screen. Roominess is measured
-- on the spot rather than read back from toggle_full_size(), whose saved size
-- outlives the layout it was taken in — a window would otherwise go on claiming
-- to be full after the user closed or resized the neighbour it had squeezed.
function M.next_window()
    local others = other_wins()
    for _, win in ipairs(others) do
        if not is_sliver(win) then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    if #others > 0 and vim.wo.diff and vim.w.foyer_saved_size then
        -- A diff is only readable beside its other half, so give the squeezed
        -- pane its size back and step into it. Restoring drops the saved size,
        -- so the second pass cannot arrive back here.
        M.toggle_full_size()
        M.next_window()
        return
    end

    vim.cmd('b#')
end

M.is_sliver = is_sliver

return M
