-- Window utilities that know nothing of foyer's prompts or terminals: the
-- full-screen toggle and the window-or-buffer switch.
local M = {}

-- Toggle the current window between full screen and the size it had before:
-- height for a float, width for a split. The remembered size is window-local,
-- so it dies with the window. Full is a request, not a promise: a neighbouring
-- split keeps its minimum width, so the window may stop short of 'columns'.
function M.toggle_full_size()
    local win_id = vim.api.nvim_get_current_win()
    local is_float = vim.api.nvim_win_get_config(win_id).relative ~= ''
    local get = is_float and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
    local set = is_float and vim.api.nvim_win_set_height or vim.api.nvim_win_set_width
    -- A float starts one row down and wears a border, so it cannot take every line.
    local full = is_float and (vim.o.lines - 4) or vim.o.columns

    local saved = vim.w[win_id].foyer_saved_size
    if saved then
        vim.w[win_id].foyer_saved_size = nil
        set(win_id, saved)
    else
        vim.w[win_id].foyer_saved_size = get(win_id)
        set(win_id, full)
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
function M.tab_switch()
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
        M.tab_switch()
        return
    end

    vim.cmd('b#')
end

return M
